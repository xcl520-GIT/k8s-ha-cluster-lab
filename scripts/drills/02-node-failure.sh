#!/bin/bash
# ============================================================
# 02-node-failure.sh —— 节点故障与优雅驱逐演练
#
# 用法（在 master 上执行）:
#   bash 02-node-failure.sh prepare     # 部署测试负载（反亲和性分散）
#   bash 02-node-failure.sh drain       # 场景A：优雅驱逐（计划内维护）
#   bash 02-node-failure.sh uncordon    # 恢复调度
#   bash 02-node-failure.sh baseline    # 记录基线（供硬故障对比）
#   bash 02-node-failure.sh observe     # 场景B：观察硬故障反应（配合在节点上停服务）
#   bash 02-node-failure.sh report      # 汇总报告
#   bash 02-node-failure.sh pdb-demo    # PodDisruptionBudget 演示
#   bash 02-node-failure.sh cleanup
#
# 场景B 需要在目标节点上手工执行（脚本会提示）：
#   systemctl stop kubelet cri-docker docker
# ============================================================
set -uo pipefail

NS="drill-ns"
TARGET_NODE="${TARGET_NODE:-k8s-node01}"
STATE_DIR="/var/backups/etcd"
export KUBECONFIG=/etc/kubernetes/admin.conf

RED='\033[1;31m'; GRN='\033[1;32m'; YEL='\033[1;33m'; CYN='\033[1;36m'; RST='\033[0m'
hr()  { echo; echo -e "${CYN}══════════════════════════════════════════════════════════${RST}"; echo -e "${CYN} $*${RST}"; echo -e "${CYN}══════════════════════════════════════════════════════════${RST}"; }
ok()  { echo -e "  ${GRN}✅ $*${RST}"; }
bad() { echo -e "  ${RED}❌ $*${RST}"; }
warn(){ echo -e "  ${YEL}⚠️  $*${RST}"; }

pods_on()   { kubectl -n "$NS" get pods -o wide --no-headers 2>/dev/null | awk -v n="$1" '$7==n {print $1}'; }
count_on()  { pods_on "$1" | wc -l; }

case "${1:-report}" in

# ------------------------------------------------------------
prepare)
  hr "准备：部署带反亲和性的测试负载"
  kubectl create ns "$NS" --dry-run=client -o yaml | kubectl apply -f - >/dev/null

  cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web
  namespace: $NS
spec:
  replicas: 4
  selector:
    matchLabels: {app: web}
  template:
    metadata:
      labels: {app: web}
    spec:
      # 软反亲和：尽量分散到不同节点，但不强制（避免副本卡 Pending）
      affinity:
        podAntiAffinity:
          preferredDuringSchedulingIgnoredDuringExecution:
          - weight: 100
            podAffinityTerm:
              labelSelector:
                matchLabels: {app: web}
              topologyKey: kubernetes.io/hostname
      containers:
      - name: web
        image: registry.aliyuncs.com/google_containers/pause:3.10.1
        resources:
          requests: {cpu: 20m, memory: 16Mi}
EOF

  sleep 8
  echo "  各节点 Pod 分布："
  for n in $(kubectl get nodes -o jsonpath='{.items[*].metadata.name}'); do
    echo "    $n : $(count_on $n) 个"
  done
  echo
  kubectl -n "$NS" get pods -o wide
  warn "注意：4 副本 + 硬反亲和，但只有 3 个节点（master 有污点不可调度）"
  warn "→ 第 4 个副本会 Pending。这是刻意的，用于演示反亲和性的约束"
  ;;

# ------------------------------------------------------------
drain)
  hr "场景 A · 计划内维护（优雅驱逐 $TARGET_NODE）"

  echo "  【驱逐前】"
  kubectl get nodes
  echo "  $TARGET_NODE 上的业务 Pod: $(count_on $TARGET_NODE) 个"

  echo
  echo "  【执行 cordon（禁止新 Pod 调度）】"
  kubectl cordon "$TARGET_NODE"
  kubectl get node "$TARGET_NODE" -o jsonpath='    调度状态: {.spec.unschedulable}{"\n"}'

  echo
  echo "  【执行 drain（驱逐现有 Pod）】"
  echo "    ⚠️  --ignore-daemonsets: DaemonSet 的 Pod 不能被驱逐（每节点必须有）"
  echo "    ⚠️  --delete-emptydir-data: emptyDir 数据会丢失"
  T0=$(date +%s)
  kubectl drain "$TARGET_NODE" --ignore-daemonsets --delete-emptydir-data --timeout=120s 2>&1 | sed 's/^/    /'
  T1=$(date +%s)

  echo
  echo "  【驱逐后】"
  kubectl -n "$NS" get pods -o wide
  echo
  echo "  $TARGET_NODE 上剩余业务 Pod: $(count_on $TARGET_NODE) 个（应为 0）"
  echo "  驱逐耗时: $((T1 - T0)) 秒"

  echo
  echo "  【观察 DaemonSet 的 Pod 是否保留】"
  kubectl -n kube-system get pods -o wide --no-headers | awk -v n="$TARGET_NODE" '$7==n {print "    "$1"  (DaemonSet，仍在)"}'

  echo
  echo -e "${GRN}下一步：${RST} bash $0 uncordon"
  ;;

# ------------------------------------------------------------
uncordon)
  hr "恢复调度（uncordon $TARGET_NODE）"
  kubectl uncordon "$TARGET_NODE"
  sleep 3
  kubectl get nodes
  echo
  echo "  注意：被驱逐的 Pod 不会自动回到原节点，"
  echo "    它们已在新节点重建。uncordon 只是允许新 Pod 再调度上去。"
  ;;

# ------------------------------------------------------------
pdb-demo)
  hr "PodDisruptionBudget 演示（生产必备）"

  echo "  【创建 PDB：保证至少 2 个副本可用】"
  cat <<EOF | kubectl apply -f -
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: web-pdb
  namespace: $NS
spec:
  minAvailable: 2
  selector:
    matchLabels: {app: web}
EOF
  kubectl -n "$NS" get pdb
  echo
  echo "  【PDB 如何影响驱逐】"
  echo "    当前可用副本: $(kubectl -n $NS get pods -l app=web --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l)"
  echo "    PDB 要求最少: 2"
  echo
  echo "  【尝试驱逐会怎样】"
  kubectl drain "$TARGET_NODE" --ignore-daemonsets --delete-emptydir-data --dry-run=client 2>&1 | sed 's/^/    /'
  echo
  echo -e "${YEL}PDB 的作用：如果驱逐会导致可用副本数低于 minAvailable，"
  echo -e "drain 会被阻塞（而不是强行中断服务）。${RST}"
  kubectl uncordon "$TARGET_NODE" 2>/dev/null
  ;;

# ------------------------------------------------------------
baseline)
  hr "场景 B · 记录硬故障前的基线"
  date '+  记录时间: %F %T'
  echo "  $TARGET_NODE 状态: $(kubectl get node $TARGET_NODE -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')"
  echo "  $TARGET_NODE 上业务 Pod 数: $(count_on $TARGET_NODE)"
  echo
  echo "  【当前 Pod 分布】"
  kubectl -n "$NS" get pods -o wide
  echo
  echo "  【目标节点上的 Pod 列表（用于事后对比）】"
  pods_on "$TARGET_NODE" | sed 's/^/    /'
  {
    echo "TS=$(date +%s)"
    echo "READY_BEFORE=$(kubectl get node $TARGET_NODE -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')"
    pods_on "$TARGET_NODE" | sed 's/^/POD_BEFORE=/'
  } > "${STATE_DIR}/.drill2-baseline"
  echo
  echo -e "${YEL}下一步（在 $TARGET_NODE 上执行，模拟硬故障）：${RST}"
  echo "    systemctl stop kubelet cri-docker docker"
  echo -e "${YEL}然后回到 master 执行：${RST}"
  echo "    bash $0 observe"
  ;;

# ------------------------------------------------------------
observe)
  hr "场景 B · 观察硬故障反应时序"

  START=$(date +%s)
  echo "  开始计时: $(date '+%F %T')"
  echo "  目标节点: $TARGET_NODE"
  echo

  NOTREADY_AT=""
  TAINT_AT=""

  echo "  ── 阶段 1：等待节点变 NotReady（默认 node-monitor-grace-period = 40s）──"
  for i in $(seq 1 40); do
    ST=$(kubectl get node "$TARGET_NODE" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)
    EL=$(( $(date +%s) - START ))
    if [[ "$ST" != "True" ]]; then
      NOTREADY_AT=$EL
      echo "    ✅ ${EL}s 后节点变为 NotReady（status=$ST）"
      break
    fi
    printf "\r    [%02ds] 仍是 Ready ..." "$EL"
    sleep 2
  done
  echo

  if [[ -z "$NOTREADY_AT" ]]; then
    bad "80 秒内节点仍是 Ready —— 请确认已在节点上停掉 kubelet"
  else
    echo
    echo "  ── 阶段 2：观察污点与 Pod 状态 ──"
    kubectl describe node "$TARGET_NODE" | sed -n '/Taints:/,/Unschedulable/p' | head -6 | sed 's/^/    /'
    echo
    echo "    节点 Conditions:"
    kubectl get node "$TARGET_NODE" -o jsonpath='{range .status.conditions[*]}    {.type}={.status} ({.lastTransitionTime}){"\n"}{end}'
    echo
    echo "    业务 Pod 状态（此时应仍为 Running，但节点已失联）:"
    kubectl -n "$NS" get pods -o wide | sed 's/^/    /'
    echo
    echo -e "    ${YEL}关键认知：节点 NotReady 后，Pod 不会立刻被驱逐。${RST}"
    echo "      默认有 300 秒（5 分钟）的容忍期（tolerationSeconds），"
    echo "      期间 Pod 仍被标记为 Running —— 目的是防止网络抖动导致误驱逐。"
  fi

  END=$(date +%s)
  echo
  echo "  ── 阶段 3：时间统计 ──"
  echo "    开始: $(date -d @$START '+%F %T')"
  echo "    现在: $(date '+%F %T')"
  echo "    已耗时: $((END - START)) 秒"
  [[ -n "$NOTREADY_AT" ]] && echo "    检测到 NotReady 用时: ${NOTREADY_AT} 秒"

  echo
  echo -e "${GRN}恢复节点（在 $TARGET_NODE 上执行）:${RST}"
  echo "    systemctl start docker cri-docker kubelet"
  echo -e "${GRN}然后回到 master 执行:${RST}"
  echo "    bash $0 report"
  ;;

# ------------------------------------------------------------
report)
  hr "演练总结报告"

  echo "  【当前集群状态】"
  kubectl get nodes -o wide
  echo

  echo "  【业务 Pod 分布】"
  kubectl -n "$NS" get pods -o wide
  echo

  echo "  【Taints】"
  for n in $(kubectl get nodes -o jsonpath='{.items[*].metadata.name}'); do
    echo "    $n : $(kubectl get node $n -o jsonpath='{.spec.taints[*].key}' | tr ' ' ',')"
    echo "      unschedulable: $(kubectl get node $n -o jsonpath='{.spec.unschedulable}' | sed 's/^$/false/')"
  done
  echo

  echo "  【DaemonSet 分布（对比：它们不会被 drain 驱逐）】"
  kubectl -n kube-system get pods -o wide --no-headers | grep -E 'calico-node|kube-proxy' | awk '{printf "    %-45s %s\n", $1, $7}'
  echo

  echo "  【核心知识点】"
  cat <<'EOF'
    1. cordon  = 标记不可调度（不驱逐已有 Pod）
       drain   = cordon + 驱逐现有 Pod
       uncordon= 恢复可调度

    2. node-monitor-grace-period (默认 40s)
       kubelet 心跳超时多久后，controller-manager 把节点标记为 NotReady

    3. Pod 驱逐容忍期 (默认 300s)
       节点 NotReady 后，Pod 不会立即被驱逐。系统给 5 分钟容忍期，
       防止网络抖动导致大规模误驱逐。超时后 Pod 被标记删除并在其他节点重建。

    4. DaemonSet 的 Pod 不可驱逐
       因为它们的语义就是"每个节点都要有一个"，drain 必须加
       --ignore-daemonsets 才能通过。

    5. PDB (PodDisruptionBudget)
       约束"自愿中断"（如 drain）时的最小可用副本数。
       注意：PDB 只对自愿中断生效，对节点宕机这种非自愿中断无效。

    6. 优雅终止
       Pod 删除时会先执行 preStop hook，然后收到 SIGTERM，
       等待 terminationGracePeriodSeconds（默认 30s）后 SIGKILL。
EOF
  ;;

# ------------------------------------------------------------
cleanup)
  hr "清理演练资源"
  kubectl delete ns "$NS" --ignore-not-found --wait=false
  kubectl uncordon k8s-node01 2>/dev/null
  kubectl uncordon k8s-node02 2>/dev/null
  ok "已清理（命名空间删除可能需几秒完成）"
  ;;

*)
  echo "用法: bash $0 {prepare|drain|uncordon|pdb-demo|baseline|observe|report|cleanup}"
  exit 1
  ;;
esac
