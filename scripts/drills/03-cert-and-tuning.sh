#!/bin/bash
# ============================================================
# 03-cert-and-tuning.sh —— 证书轮换 + 系统参数调优
#
# 用法（在 master 上执行）:
#   bash 03-cert-and-tuning.sh cert-check    # 查看证书有效期
#   bash 03-cert-and-tuning.sh cert-renew    # 轮换全部证书
#   bash 03-cert-and-tuning.sh tuning-check  # 检查系统参数
#   bash 03-cert-and-tuning.sh tuning-apply  # 应用调优
#   bash 03-cert-and-tuning.sh report
#
# 说明:
#   证书有效期由 kubeadm 的 certificateValidityPeriod 决定（默认 1 年）。
#   过期后 apiserver 无法启动、kubectl 全部报 x509 错误，集群直接不可用。
#   这是生产事故的经典原因之一，必须纳入日常巡检。
# ============================================================
set -uo pipefail

RED='\033[1;31m'; GRN='\033[1;32m'; YEL='\033[1;33m'; CYN='\033[1;36m'; RST='\033[0m'
hr()  { echo; echo -e "${CYN}══════════════════════════════════════════════════════════${RST}"; echo -e "${CYN} $*${RST}"; echo -e "${CYN}══════════════════════════════════════════════════════════${RST}"; }
ok()  { echo -e "  ${GRN}✅ $*${RST}"; }
bad() { echo -e "  ${RED}❌ $*${RST}"; }
warn(){ echo -e "  ${YEL}⚠️  $*${RST}"; }

export KUBECONFIG=/etc/kubernetes/admin.conf

case "${1:-report}" in

# ------------------------------------------------------------
cert-check)
  hr "证书有效期检查"
  BACKUP="/root/cert-expire-$(date +%Y%m%d-%H%M%S).txt"
  kubeadm certs check-expiration 2>&1 | tee "$BACKUP" | sed 's/^/  /'
  echo
  echo "  【剩余天数最少的 5 张证书】"
  kubeadm certs check-expiration 2>/dev/null | \
    awk '/^CERTIFICATE AUTHORITY/{exit} /^[a-z]/ && $3 ~ /^[0-9]+[dy]$/ {
           v=$3; u=substr(v,length(v),1); n=substr(v,1,length(v)-1);
           if (u=="y") n=n*365;
           print n, $1
         }' | sort -n | head -5 | while read d n; do
      if [ "$d" -lt 30 ] 2>/dev/null; then
        echo -e "    ${RED}⚠️  $n : 仅剩 ${d} 天${RST}"
      else
        echo "    $(printf '%-28s' "$n") ${d} 天"
      fi
    done
  echo
  echo "  完整报告已保存: $BACKUP"
  ;;

# ------------------------------------------------------------
cert-renew)
  hr "证书轮换演练"

  echo "  【轮换前】"
  kubeadm certs check-expiration 2>&1 | grep -E '^(admin|apiserver|etcd-server|front-proxy)' | sed 's/^/    /'

  echo
  echo "  【备份现有证书】"
  BAK="/root/pki-backup-$(date +%Y%m%d-%H%M%S)"
  cp -a /etc/kubernetes/pki "$BAK"
  echo "    已备份到: $BAK ($(du -sh $BAK | cut -f1))"

  echo
  echo "  【执行轮换 kubeadm certs renew all】"
  kubeadm certs renew all 2>&1 | tail -20 | sed 's/^/    /'

  echo
  echo "  【注意】kubeadm 会提示：必须重启 apiserver/controller-manager/scheduler/etcd"
  echo "    但 systemctl restart kubelet 不会重建静态 Pod（kubelet 停止不杀容器）"
  echo "    正确做法：把静态 Pod 清单移出再移回，强制 kubelet 重建"

  echo
  echo "  【重启控制平面】"
  echo "    [1/3] 移出 manifest ..."
  mkdir -p /root/manifests-hold
  mv /etc/kubernetes/manifests/*.yaml /root/manifests-hold/ 2>/dev/null
  echo "          剩余 manifest: $(ls /etc/kubernetes/manifests/ 2>/dev/null | wc -l) 个"

  echo "    [2/3] 等待控制平面停止 ..."
  for i in $(seq 1 30); do
    if ! ss -lntp 2>/dev/null | grep -q ':6443'; then
      echo "          6443 已释放（耗时 $((i*2)) 秒）"
      break
    fi
    printf "\r          [%02d/30] 等待中 ..." "$i"
    sleep 2
  done
  echo

  echo "    [3/3] 移回 manifest，触发重建 ..."
  mv /root/manifests-hold/*.yaml /etc/kubernetes/manifests/ 2>/dev/null
  rmdir /root/manifests-hold 2>/dev/null

  for i in $(seq 1 60); do
    if kubectl get --raw=/readyz >/dev/null 2>&1; then
      echo "          ✅ API Server 就绪（耗时 $((i*2)) 秒）"
      break
    fi
    printf "\r          [%02d/60] 等待中 ..." "$i"
    sleep 2
  done
  echo

  echo "  【轮换后】"
  kubeadm certs check-expiration 2>&1 | grep -E '^(admin|apiserver|etcd-server|front-proxy)' | sed 's/^/    /'
  echo
  echo "  【集群健康验证】"
  kubectl get nodes | sed 's/^/    /'
  ;;

# ------------------------------------------------------------
tuning-check)
  hr "系统参数检查"

  echo "  【内核参数】"
  for p in net.ipv4.ip_forward \
           net.bridge.bridge-nf-call-iptables \
           net.bridge.bridge-nf-call-ip6tables \
           vm.swappiness \
           vm.overcommit_memory \
           net.ipv4.tcp_max_syn_backlog \
           net.core.somaxconn \
           fs.file-max \
           fs.inotify.max_user_instances \
           fs.inotify.max_user_watches; do
    v=$(sysctl -n "$p" 2>/dev/null || echo "N/A")
    printf "    %-45s = %s\n" "$p" "$v"
  done

  echo
  echo "  【swap 状态】"
  if swapon --show 2>/dev/null | grep -q .; then
    bad "swap 已启用！K8s 要求关闭"
    swapon --show | sed 's/^/      /'
  else
    ok "swap 未启用"
  fi

  echo
  echo "  【内核模块】"
  for m in overlay br_netfilter ipip ip_tunnel nf_conntrack; do
    if lsmod | grep -q "^$m"; then
      echo "    ✅ $m"
    else
      echo "    ⚠️  $m (未加载)"
    fi
  done

  echo
  echo "  【ulimit / 文件描述符】"
  echo "    当前 shell  : $(ulimit -n)"
  echo "    systemd 默认: $(grep -h DefaultLimitNOFILE /etc/systemd/system.conf 2>/dev/null || echo '未设置')"
  echo "    kubelet     : $(systemctl show kubelet -p LimitNOFILE --value 2>/dev/null)"
  echo "    containerd  : $(systemctl show containerd -p LimitNOFILE --value 2>/dev/null)"
  echo "    cri-docker  : $(systemctl show cri-docker -p LimitNOFILE --value 2>/dev/null)"

  echo
  echo "  【conntrack 表】"
  echo "    nf_conntrack_max     : $(sysctl -n net.netfilter.nf_conntrack_max 2>/dev/null || echo N/A)"
  echo "    nf_conntrack_count   : $(sysctl -n net.netfilter.nf_conntrack_count 2>/dev/null || cat /proc/sys/net/netfilter/nf_conntrack_count 2>/dev/null || echo N/A)"

  echo
  echo "  【时间同步】"
  if systemctl is-active chronyd >/dev/null 2>&1; then
    ok "chronyd 运行中"
    chronyc tracking 2>/dev/null | grep -E 'System time|Last offset' | sed 's/^/      /' || true
  else
    bad "chronyd 未运行（etcd Raft 依赖准确时钟）"
  fi
  ;;

# ------------------------------------------------------------
tuning-apply)
  hr "应用系统参数调优"

  echo "  【1/5 修正 vm.swappiness】"
  OLD=$(sysctl -n vm.swappiness)
  echo "    当前值: $OLD"
  echo "    目标值: 1"
  echo "    为什么：即使 swapoff 了，swappiness 仍是内核换页倾向的指标。"
  echo "           如果将来有人重新开启 swap 或用 zram，60 会导致内核积极换出内存页，"
  echo "           使 kubelet 的内存回收判断失准。设为 1 保留紧急换页能力但不主动换出。"

  cat > /etc/sysctl.d/99-k8s-tuning.conf <<'EOF'
# ============================================================
# Kubernetes 节点调优参数
# 由 scripts/drills/03-cert-and-tuning.sh 生成
# ============================================================

# ---------- swap / 内存 ----------
# 尽量不使用 swap（K8s 要求关闭 swap，这里双保险）
vm.swappiness = 1
# 允许内存过量分配，避免 fork 时因内存预留失败（K8s 场景常用）
vm.overcommit_memory = 1
# 降低脏页比例，减少大规模写时的 IO 抖动
vm.dirty_ratio = 10
vm.dirty_background_ratio = 5

# ---------- 网络 ----------
# 允许转发（Pod 出集群必需）
net.ipv4.ip_forward = 1
# 桥接流量走 iptables（Service 生效必需）
net.bridge.bridge-nf-call-iptables = 1
net.bridge.bridge-nf-call-ip6tables = 1
# 提高连接队列，应对高并发建连
net.core.somaxconn = 32768
net.ipv4.tcp_max_syn_backlog = 32768
# 增加可用本地端口范围（大量 NodePort / 出向连接场景）
net.ipv4.ip_local_port_range = 10240 65000
# 快速回收 TIME_WAIT（高连接周转场景）
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 30
# conntrack 容量（kube-proxy 依赖，Pod 数量多时容易打满）
net.netfilter.nf_conntrack_max = 1048576
net.netfilter.nf_conntrack_tcp_timeout_established = 86400
# 网卡 backlog
net.core.netdev_max_backlog = 16384

# ---------- 文件与 inotify ----------
# 大量容器时的 inotify 上限（很多"too many open files"是这个引起的）
fs.inotify.max_user_instances = 8192
fs.inotify.max_user_watches = 524288
fs.file-max = 2097152
EOF

  sysctl --system >/dev/null 2>&1
  NEW=$(sysctl -n vm.swappiness)
  if [ "$NEW" = "1" ]; then
    ok "vm.swappiness: $OLD → $NEW"
  else
    bad "修改失败，当前值 $NEW"
  fi

  echo
  echo "  【2/5 配置内核模块自动加载】"
  cat > /etc/modules-load.d/k8s.conf <<'EOF'
overlay
br_netfilter
ipip
ip_tunnel
nf_conntrack
EOF
  for m in overlay br_netfilter ipip ip_tunnel nf_conntrack; do
    modprobe "$m" 2>/dev/null && echo "    ✅ $m" || echo "    ⚠️  $m"
  done

  echo
  echo "  【3/5 提高 systemd 服务文件描述符上限】"
  mkdir -p /etc/systemd/system/kubelet.service.d
  cat > /etc/systemd/system/kubelet.service.d/30-limits.conf <<'EOF'
[Service]
LimitNOFILE=1048576
LimitNPROC=infinity
LimitCORE=infinity
TasksMax=infinity
EOF
  systemctl daemon-reload
  echo "    kubelet LimitNOFILE 现在为: $(systemctl show kubelet -p LimitNOFILE --value)"
  ok "已配置（下次重启 kubelet 生效）"

  echo
  echo "  【4/5 配置时间同步】"
  if systemctl is-active chronyd >/dev/null 2>&1; then
    ok "chronyd 已在运行"
  else
    systemctl enable --now chronyd 2>/dev/null && ok "chronyd 已启动" || warn "启动失败"
  fi

  echo
  echo "  【5/5 验证】"
  echo "    vm.swappiness            = $(sysctl -n vm.swappiness)"
  echo "    vm.overcommit_memory     = $(sysctl -n vm.overcommit_memory)"
  echo "    net.core.somaxconn       = $(sysctl -n net.core.somaxconn)"
  echo "    nf_conntrack_max         = $(sysctl -n net.netfilter.nf_conntrack_max 2>/dev/null || echo N/A)"
  echo "    fs.inotify.max_user_watches = $(sysctl -n fs.inotify.max_user_watches)"
  echo
  echo "    持久化文件: /etc/sysctl.d/99-k8s-tuning.conf"
  echo "    内核模块:   /etc/modules-load.d/k8s.conf"
  echo "    kubelet 限制: /etc/systemd/system/kubelet.service.d/30-limits.conf"
  ;;

# ------------------------------------------------------------
report)
  hr "演练总结"

  echo "  【证书状态】"
  kubeadm certs check-expiration 2>&1 | sed -n '1,20p' | sed 's/^/    /'

  echo
  echo "  【系统调优关键项】"
  printf "    %-32s %s\n" "vm.swappiness"            "$(sysctl -n vm.swappiness)"
  printf "    %-32s %s\n" "vm.overcommit_memory"     "$(sysctl -n vm.overcommit_memory)"
  printf "    %-32s %s\n" "net.core.somaxconn"       "$(sysctl -n net.core.somaxconn)"
  printf "    %-32s %s\n" "net.ipv4.ip_forward"      "$(sysctl -n net.ipv4.ip_forward)"
  printf "    %-32s %s\n" "nf_conntrack_max"         "$(sysctl -n net.netfilter.nf_conntrack_max 2>/dev/null || echo N/A)"
  printf "    %-32s %s\n" "fs.inotify.max_user_watches" "$(sysctl -n fs.inotify.max_user_watches)"

  echo
  echo "  【集群健康】"
  kubectl get nodes 2>&1 | sed 's/^/    /'
  echo
  echo "  【调优文件清单】"
  ls -la /etc/sysctl.d/99-k8s-tuning.conf /etc/modules-load.d/k8s.conf /etc/systemd/system/kubelet.service.d/30-limits.conf 2>&1 | sed 's/^/    /'
  ;;

*)
  echo "用法: bash $0 {cert-check|cert-renew|tuning-check|tuning-apply|report}"
  exit 1
  ;;
esac
