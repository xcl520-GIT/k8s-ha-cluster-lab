#!/bin/bash
# ============================================================
# 01-etcd-drill.sh —— etcd 备份与灾难恢复演练
#
# 分阶段执行，每步可单独验证，便于观察和写文档
#
# 用法:
#   bash 01-etcd-drill.sh prepare    # 阶段1：造数据 + 备份
#   bash 01-etcd-drill.sh destroy    # 阶段2：模拟误删（灾难）
#   bash 01-etcd-drill.sh restore    # 阶段3：从快照恢复
#   bash 01-etcd-drill.sh verify     # 阶段4：验证与耗时统计
#   bash 01-etcd-drill.sh status     # 随时查看当前状态
#
# 演练原理:
#   etcd 快照恢复是【全量回滚】—— 集群状态会回到快照那一刻，
#   之后发生的所有变更都会丢失。这正是需要量化的 RPO。
# ============================================================
set -uo pipefail

NS="prod-app"
BACKUP_DIR="/var/backups/etcd"
STATE_FILE="/var/backups/etcd/.drill-state"
ETCD_DATA="/var/lib/etcd"

CACERT="/etc/kubernetes/pki/etcd/ca.crt"
CERT="/etc/kubernetes/pki/etcd/server.crt"
KEY="/etc/kubernetes/pki/etcd/server.key"
EP="https://127.0.0.1:2379"

RED='\033[1;31m'; GRN='\033[1;32m'; YEL='\033[1;33m'; CYN='\033[1;36m'; RST='\033[0m'
hr()  { echo; echo -e "${CYN}══════════════════════════════════════════════════════════${RST}"; echo -e "${CYN} $*${RST}"; echo -e "${CYN}══════════════════════════════════════════════════════════${RST}"; }
ok()  { echo -e "  ${GRN}✅ $*${RST}"; }
bad() { echo -e "  ${RED}❌ $*${RST}"; }
warn(){ echo -e "  ${YEL}⚠️  $*${RST}"; }

[[ $EUID -eq 0 ]] || { bad "必须以 root 运行"; exit 1; }
export KUBECONFIG=/etc/kubernetes/admin.conf

latest_snapshot() { ls -1t "${BACKUP_DIR}"/etcd-*.db 2>/dev/null | head -1; }

# ============================================================
case "${1:-status}" in

# ------------------------------------------------------------
prepare)
  hr "阶段 1/4 · 准备测试数据并备份"

  # ---- 1. 记录恢复前的基线 ----
  echo "  【恢复前基线】"
  echo "    集群 UID        : $(kubectl get ns kube-system -o jsonpath='{.metadata.uid}')"
  echo "    当前 etcd 版本   : $(etcdctl --endpoints=$EP --cacert=$CACERT --cert=$CERT --key=$KEY endpoint status -w json 2>/dev/null | grep -o '"revision":[0-9]*' | cut -d: -f2)"
  echo "    现有命名空间     : $(kubectl get ns --no-headers | awk '{print $1}' | tr '\n' ' ')"

  # ---- 2. 创建"业务数据"（模拟生产负载）----
  echo
  echo "  【创建测试业务】"
  kubectl create ns "$NS" --dry-run=client -o yaml | kubectl apply -f - >/dev/null 2>&1

  cat <<EOF | kubectl apply -f - >/dev/null 2>&1
apiVersion: v1
kind: ConfigMap
metadata:
  name: app-config
  namespace: $NS
data:
  ENV: "production"
  VERSION: "v1.2.3"
  DB_HOST: "mysql.internal"
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web
  namespace: $NS
  labels: {app: web}
spec:
  replicas: 3
  selector:
    matchLabels: {app: web}
  template:
    metadata:
      labels: {app: web}
    spec:
      containers:
      - name: web
        image: registry.aliyuncs.com/google_containers/pause:3.10.1
        resources:
          requests: {cpu: 10m, memory: 16Mi}
---
apiVersion: v1
kind: Service
metadata:
  name: web-svc
  namespace: $NS
spec:
  selector: {app: web}
  ports:
  - port: 80
    targetPort: 80
---
apiVersion: v1
kind: Secret
metadata:
  name: db-credential
  namespace: $NS
type: Opaque
stringData:
  password: "SuperSecret2026"
EOF

  sleep 5
  echo "    Namespace  : $(kubectl get ns $NS -o jsonpath='{.metadata.uid}')"
  echo "    Deployment : $(kubectl -n $NS get deploy web -o jsonpath='{.metadata.uid}')"
  echo "    Service    : $(kubectl -n $NS get svc web-svc -o jsonpath='{.metadata.uid}')"
  echo "    ConfigMap  : $(kubectl -n $NS get cm app-config -o jsonpath='{.metadata.uid}')"
  echo "    Secret     : $(kubectl -n $NS get secret db-credential -o jsonpath='{.metadata.uid}')"
  ok "测试业务已创建"

  # ---- 3. 记录关键 UID，恢复后比对是否一致 ----
  {
    echo "NS_UID=$(kubectl get ns $NS -o jsonpath='{.metadata.uid}')"
    echo "DEPLOY_UID=$(kubectl -n $NS get deploy web -o jsonpath='{.metadata.uid}')"
    echo "SVC_UID=$(kubectl -n $NS get svc web-svc -o jsonpath='{.metadata.uid}')"
    echo "CM_UID=$(kubectl -n $NS get cm app-config -o jsonpath='{.metadata.uid}')"
    echo "SECRET_UID=$(kubectl -n $NS get secret db-credential -o jsonpath='{.metadata.uid}')"
    echo "POD_COUNT=$(kubectl -n $NS get pods --no-headers 2>/dev/null | wc -l)"
  } > "$STATE_FILE"
  echo
  echo "  【业务对象 UID 已存档】$STATE_FILE"
  cat "$STATE_FILE" | sed 's/^/    /'

  # ---- 4. 立刻备份（快照必须包含刚创建的数据）----
  echo
  echo "  【执行备份】"
  BACKUP_SCRIPT=""
  for p in "$(dirname "$0")/../backup/etcd-backup.sh" \
           "/tmp/etcd-backup.sh" \
           "/root/k8s-ha-cluster-lab/scripts/backup/etcd-backup.sh"; do
    [[ -f "$p" ]] && { BACKUP_SCRIPT="$p"; break; }
  done

  if [[ -n "$BACKUP_SCRIPT" ]]; then
    echo "    调用: $BACKUP_SCRIPT"
    if ! bash "$BACKUP_SCRIPT" 2>&1 | tail -22 | sed 's/^/    /'; then
      bad "备份失败"; exit 1
    fi
  else
    warn "未找到 etcd-backup.sh，改用内联备份逻辑"
    mkdir -p "$BACKUP_DIR"; chmod 700 "$BACKUP_DIR"
    TS=$(date '+%Y%m%d-%H%M%S')
    SNAP_TMP="${BACKUP_DIR}/etcd-${TS}.db"
    etcdctl --endpoints="$EP" --cacert="$CACERT" --cert="$CERT" --key="$KEY" \
      snapshot save "$SNAP_TMP" >/dev/null 2>&1 || { bad "备份失败"; exit 1; }
    etcdutl snapshot status "$SNAP_TMP" -w table 2>&1 | sed 's/^/    /'
    sha256sum "$SNAP_TMP" > "${SNAP_TMP}.sha256"
    ok "内联备份完成"
  fi

  SNAP=$(latest_snapshot)
  echo "$SNAP" > "${STATE_FILE}.snapshot"
  ok "快照已就绪: $SNAP"

  # ---- 5. 记录快照内包含的 key 数 ----
  echo
  echo "  【快照内容校验】"
  etcdutl snapshot status "$SNAP" -w table 2>&1 | sed 's/^/    /'

  echo
  echo -e "${GRN}阶段 1 完成。执行下一步：${RST}"
  echo "  bash $0 destroy"
  ;;

# ------------------------------------------------------------
destroy)
  hr "阶段 2/4 · 模拟灾难（误删整个业务命名空间）"

  if ! kubectl get ns "$NS" >/dev/null 2>&1; then
    bad "命名空间 $NS 不存在，请先执行 prepare"
    exit 1
  fi

  echo "  【删除前】"
  kubectl get all -n "$NS" 2>&1 | sed 's/^/    /'

  echo
  echo "  【执行误删】kubectl delete ns $NS"
  START=$(date +%s)
  kubectl delete ns "$NS" --wait=true --timeout=120s 2>&1 | sed 's/^/    /'
  END=$(date +%s)

  echo
  echo "  【删除后】"
  if kubectl get ns "$NS" >/dev/null 2>&1; then
    warn "命名空间仍然存在"
  else
    bad "命名空间 $NS 已消失 —— 数据全丢！"
  fi
  echo "    删除耗时: $((END - START)) 秒"
  echo "$END" > "${STATE_FILE}.destroy_ts"

  echo
  echo -e "${RED}灾难已造成。恢复前请注意：${RST}"
  echo "  · etcd 快照恢复是【全量回滚】，集群会回到快照那一刻"
  echo "  · 快照之后的所有变更都会丢失（这就是 RPO）"
  echo
  echo -e "${GRN}执行下一步：${RST}"
  echo "  bash $0 restore"
  ;;

# ------------------------------------------------------------
restore)
  hr "阶段 3/4 · 从快照恢复集群"

  SNAP=$(cat "${STATE_FILE}.snapshot" 2>/dev/null)
  [[ -z "$SNAP" ]] && SNAP=$(latest_snapshot)
  [[ -f "$SNAP" ]] || { bad "找不到快照文件"; exit 1; }
  echo "  使用快照: $SNAP"

  # 恢复前先校验快照可用
  echo
  echo "  【恢复前校验快照】"
  if ! etcdutl snapshot status "$SNAP" -w table 2>&1 | sed 's/^/    /'; then
    bad "快照不可用，中止"
    exit 1
  fi

  T0=$(date +%s); echo "  恢复开始时间: $(date '+%F %T')"

  # ---- 1. 停止 kubelet + 显式停止静态 Pod 容器 ----
  echo
  echo "  [1/5] 停止控制平面"
  echo "        注意：systemctl stop kubelet 【不会】杀掉它管理的容器！"
  echo "        （这是 kubelet 的正确设计，但对 etcd 恢复是致命的："
  echo "          容器继续运行会持有旧数据目录的文件句柄，导致恢复的数据不被加载）"
  systemctl stop kubelet
  sleep 3
  echo "        kubelet 状态: $(systemctl is-active kubelet)"

  CNT=$(docker ps --filter "name=k8s_" -q | wc -l)
  echo "        显式停止 $CNT 个 kubelet 管理的容器 ..."
  [[ $CNT -gt 0 ]] && docker ps --filter "name=k8s_" -q | xargs -r docker stop -t 20 >/dev/null 2>&1
  sleep 3

  REMAIN=$(docker ps --filter "name=k8s_" -q | wc -l)
  if [[ "$REMAIN" -eq 0 ]]; then
    ok "所有容器已停止"
  else
    warn "仍有 $REMAIN 个容器，强制终止"
    docker ps --filter "name=k8s_" -q | xargs -r docker kill >/dev/null 2>&1
    sleep 2
  fi

  # 必须确认端口释放，否则恢复无效
  for port in 6443 2379; do
    if ss -lntp 2>/dev/null | grep -q ":$port"; then
      bad "端口 $port 仍被占用 —— 恢复会失效，中止"
      exit 1
    fi
  done
  ok "6443 / 2379 已释放，控制平面确实已停止"

  # ---- 2. 备份当前（已损坏）的 etcd 数据目录 ----
  echo
  echo "  [2/5] 保全现场：把现有 etcd 数据目录改名"
  BAK="${ETCD_DATA}.bak-$(date +%Y%m%d-%H%M%S)"
  mv "$ETCD_DATA" "$BAK"
  echo "    $ETCD_DATA -> $BAK"

  # ---- 3. 从快照恢复 ----
  echo
  echo "  [3/5] etcdutl snapshot restore"
  if ! etcdutl snapshot restore "$SNAP" \
        --name k8s-master01 \
        --initial-cluster "k8s-master01=https://192.168.16.11:2380" \
        --initial-advertise-peer-urls "https://192.168.16.11:2380" \
        --data-dir "$ETCD_DATA" 2>&1 | sed 's/^/    /'; then
    bad "恢复失败！现场已保全在 $BAK"
    echo "    回滚命令: mv $BAK $ETCD_DATA && systemctl start kubelet"
    exit 1
  fi
  ok "数据目录已重建"

  # ---- 4. 启动 kubelet ----
  echo
  echo "  [4/5] 启动 kubelet"
  systemctl start kubelet
  echo "    等待控制平面就绪 ..."
  for i in $(seq 1 60); do
    if kubectl get --raw=/readyz >/dev/null 2>&1; then
      echo "    ✅ API Server 就绪（耗时 $(( $(date +%s) - T0 )) 秒）"
      break
    fi
    printf "\r    [%02d/60] 等待中 ..." "$i"
    sleep 2
  done
  echo

  # ---- 5. 统计 ----
  T1=$(date +%s)
  echo
  echo "  [5/5] 恢复耗时统计"
  echo "    开始: $(date -d @$T0 '+%F %T')"
  echo "    结束: $(date -d @$T1 '+%F %T')"
  echo "    RTO: $((T1 - T0)) 秒（$(( (T1 - T0) / 60 )) 分 $(( (T1 - T0) % 60 )) 秒）"
  echo "$((T1 - T0))" > "${STATE_FILE}.rto"

  echo
  echo -e "${GRN}执行下一步：${RST}"
  echo "  bash $0 verify"
  ;;

# ------------------------------------------------------------
verify)
  hr "阶段 4/4 · 恢复结果验证"

  SNAP=$(cat "${STATE_FILE}.snapshot" 2>/dev/null)
  RTO=$(cat "${STATE_FILE}.rto" 2>/dev/null || echo "?")
  DESTROY_TS=$(cat "${STATE_FILE}.destroy_ts" 2>/dev/null || echo 0)

  # ---- 1. 集群可用性 ----
  echo "  【集群健康】"
  kubectl get --raw='/readyz?verbose' 2>/dev/null | grep -c '^ok' | sed 's/^/    readyz ok 项: /'
  echo "    节点: $(kubectl get nodes --no-headers | awk '{print $1"="$2}' | tr '\n' ' ')"
  echo "    etcd 版本: $(etcdctl --endpoints=$EP --cacert=$CACERT --cert=$CERT --key=$KEY endpoint status -w json 2>/dev/null | grep -o '"revision":[0-9]*' | cut -d: -f2)"

  # ---- 2. 业务数据是否回来 ----
  echo
  echo "  【业务数据恢复情况】"
  if kubectl get ns "$NS" >/dev/null 2>&1; then
    ok "命名空间 $NS 已恢复"
  else
    bad "命名空间 $NS 未恢复"
    exit 1
  fi

  kubectl get all,cm,secret -n "$NS" 2>&1 | sed 's/^/    /'

  # ---- 3. UID 比对（验证是"原对象"而非重建）----
  echo
  echo "  【对象 UID 比对（一致 = 原对象被完整恢复）】"
  if [[ ! -f "$STATE_FILE" ]]; then
    warn "找不到存档文件 $STATE_FILE，跳过比对"
  else
    while IFS='=' read -r k v; do
      case "$k" in
        NS_UID)     cur=$(kubectl get ns "$NS" -o jsonpath='{.metadata.uid}' 2>/dev/null) ;;
        DEPLOY_UID) cur=$(kubectl -n "$NS" get deploy web -o jsonpath='{.metadata.uid}' 2>/dev/null) ;;
        SVC_UID)    cur=$(kubectl -n "$NS" get svc web-svc -o jsonpath='{.metadata.uid}' 2>/dev/null) ;;
        CM_UID)     cur=$(kubectl -n "$NS" get cm app-config -o jsonpath='{.metadata.uid}' 2>/dev/null) ;;
        SECRET_UID) cur=$(kubectl -n "$NS" get secret db-credential -o jsonpath='{.metadata.uid}' 2>/dev/null) ;;
        *)          continue ;;
      esac
      if [[ "$v" == "$cur" ]]; then
        echo -e "    ${GRN}✅ $k 一致${RST}  $cur"
      else
        echo -e "    ${RED}❌ $k 不一致${RST}"
        echo "       恢复前: $v"
        echo "       恢复后: $cur"
      fi
    done < "$STATE_FILE"
  fi

  # ---- 4. Secret 内容验证 ----
  echo
  echo "  【Secret 内容验证】"
  PW=$(kubectl -n "$NS" get secret db-credential -o jsonpath='{.data.password}' 2>/dev/null | base64 -d 2>/dev/null)
  if [[ "$PW" == "SuperSecret2026" ]]; then
    ok "密码正确还原: $PW"
  else
    bad "密码不匹配: '$PW'"
  fi

  # ---- 5. 汇总 ----
  echo
  echo "  【演练结果汇总】"
  echo "    快照文件     : $SNAP"
  echo "    快照 Revision: $(etcdutl snapshot status "$SNAP" -w json 2>/dev/null | grep -o '"revision":[0-9]*' | cut -d: -f2)"
  echo -e "    ${YEL}RTO（恢复时间目标）: ${RTO} 秒${RST}"
  if [[ "$DESTROY_TS" != "0" && -n "$RTO" && "$RTO" != "?" ]]; then
    echo "    RPO（数据丢失窗口）: 由备份频率决定 —— 若每 6 小时备份，最坏丢失 360 分钟数据"
  fi

  echo
  echo -e "${GRN}演练完成 ✅${RST}"
  echo
  echo "  后续可复现步骤:"
  echo "    bash $0 prepare && bash $0 destroy && bash $0 restore && bash $0 verify"
  ;;

# ------------------------------------------------------------
status)
  hr "当前状态"
  echo "  命名空间 $NS: $(kubectl get ns "$NS" >/dev/null 2>&1 && echo 存在 || echo '不存在')"
  echo "  快照文件:"
  ls -lh "${BACKUP_DIR}"/etcd-*.db 2>/dev/null | sed 's/^/    /' || echo "    (无)"
  echo "  存档状态文件:"
  [[ -f "$STATE_FILE" ]] && cat "$STATE_FILE" | sed 's/^/    /' || echo "    (无)"
  echo "  kubelet: $(systemctl is-active kubelet)"
  echo "  节点: $(kubectl get nodes --no-headers 2>/dev/null | awk '{print $1"="$2}' | tr '\n' ' ')"
  ;;

*)
  echo "用法: bash $0 {prepare|destroy|restore|verify|status}"
  exit 1
  ;;
esac
