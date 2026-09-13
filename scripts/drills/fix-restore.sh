#!/bin/bash
# ============================================================
# fix-restore.sh —— 完成被中断的 etcd 恢复
#
# 背景：上一次恢复中 `systemctl stop kubelet` 没有停掉静态 Pod 容器，
#       导致恢复的数据目录未被 etcd 加载。
# 本脚本显式停止所有 kubelet 管理的容器，让 kubelet 重启时
# 从【已恢复的】/var/lib/etcd 重新创建静态 Pod。
# ============================================================
set -uo pipefail

RED='\033[1;31m'; GRN='\033[1;32m'; YEL='\033[1;33m'; CYN='\033[1;36m'; RST='\033[0m'
hr()  { echo; echo -e "${CYN}── $* ──${RST}"; }
ok()  { echo -e "  ${GRN}✅ $*${RST}"; }
bad() { echo -e "  ${RED}❌ $*${RST}"; }
warn(){ echo -e "  ${YEL}⚠️  $*${RST}"; }

export KUBECONFIG=/etc/kubernetes/admin.conf
T0=$(date +%s)

hr "0. 恢复前状态"
echo "  kubelet        : $(systemctl is-active kubelet)"
echo "  etcd 容器      : $(docker ps --filter name=k8s_etcd --format '{{.Names}} ({{.Status}})' | head -1)"
echo "  6443 监听      : $(ss -lntp 2>/dev/null | grep -c 6443) 条"
echo "  已恢复数据目录 : $(ls -la /var/lib/etcd/member/snap/db 2>/dev/null | awk '{print $5" bytes, "$6" "$7" "$8}')"

hr "1. 停止 kubelet"
systemctl stop kubelet
sleep 3
echo "  kubelet: $(systemctl is-active kubelet)"

hr "2. 显式停止所有 kubelet 管理的容器"
# 关键一步：kubelet 停止不会杀容器，必须手工停
COUNT=$(docker ps --filter "name=k8s_" -q | wc -l)
echo "  待停止容器数: $COUNT"
if [[ $COUNT -gt 0 ]]; then
  docker ps --filter "name=k8s_" -q | xargs -r docker stop -t 20 >/dev/null 2>&1
fi
sleep 3

REMAIN=$(docker ps --filter "name=k8s_" -q | wc -l)
echo "  剩余运行容器: $REMAIN"
if [[ "$REMAIN" -eq 0 ]]; then
  ok "所有 kubelet 容器已停止"
else
  warn "仍有 $REMAIN 个容器在跑，强制终止"
  docker ps --filter "name=k8s_" -q | xargs -r docker kill >/dev/null 2>&1
  sleep 2
  echo "  强制后剩余: $(docker ps --filter "name=k8s_" -q | wc -l)"
fi

hr "3. 确认关键端口已释放"
if ss -lntp 2>/dev/null | grep -q ':6443'; then
  bad "6443 仍被占用："
  ss -lntp | grep 6443 | sed 's/^/    /'
else
  ok "6443 已释放（apiserver 确实停了）"
fi
if ss -lntp 2>/dev/null | grep -q ':2379'; then
  bad "2379 仍被占用（etcd 没停）"
else
  ok "2379 已释放（etcd 确实停了）"
fi

hr "4. 启动 kubelet（将从已恢复的数据目录重建静态 Pod）"
systemctl start kubelet

echo "  等待控制平面就绪 ..."
READY=0
for i in $(seq 1 90); do
  if kubectl get --raw=/readyz >/dev/null 2>&1; then
    READY=1
    echo ""
    ok "API Server 就绪（本轮耗时 $(( $(date +%s) - T0 )) 秒）"
    break
  fi
  printf "\r    [%02d/90] 等待中 ..." "$i"
  sleep 2
done
echo ""

if [[ $READY -eq 0 ]]; then
  bad "控制平面未就绪，请检查："
  echo "    docker ps --filter name=k8s_"
  echo "    docker logs \$(docker ps --filter name=k8s_etcd -q) 2>&1 | tail -30"
  echo "    回滚: systemctl stop kubelet && rm -rf /var/lib/etcd && mv /var/lib/etcd.bak-* /var/lib/etcd && systemctl start kubelet"
  exit 1
fi

hr "5. 结果验证"
sleep 5
echo "  【节点】"
kubectl get nodes --no-headers | sed 's/^/    /'
echo "  【命名空间】"
kubectl get ns --no-headers | sed 's/^/    /'
echo
if kubectl get ns prod-app >/dev/null 2>&1; then
  ok "prod-app 已恢复！"
  echo "  【业务对象】"
  kubectl get all,cm,secret -n prod-app 2>&1 | sed 's/^/    /'
else
  bad "prod-app 仍未恢复"
fi

hr "6. 耗时统计"
T1=$(date +%s)
echo "  本次修复 RTO: $((T1 - T0)) 秒"
echo "  完整 RTO（从第一次恢复开始算）: 见演练文档"
echo "$((T1 - T0))" > /var/backups/etcd/.drill-state.rto2

echo
echo -e "${GRN}修复流程结束${RST}"
