#!/bin/bash
# ============================================================
# audit-cluster.sh —— K8s 集群现状全面审计
# 用法：通过 ops-ssh.ps1 上传执行，或直接在 master 上跑
# ============================================================
export KUBECONFIG=/etc/kubernetes/admin.conf

hr() { echo; echo "══════════════════════════════════════════════════════════"; echo " $*"; echo "══════════════════════════════════════════════════════════"; }

hr "1. 节点总览"
kubectl get nodes -o wide

hr "2. 节点标签与污点"
for n in $(kubectl get nodes -o jsonpath='{.items[*].metadata.name}'); do
  echo "--- $n ---"
  echo "  角色标签 : $(kubectl get node $n -o jsonpath='{.metadata.labels.node-role\.kubernetes\.io/control-plane}{.metadata.labels.node-role\.kubernetes\.io/worker}')"
  echo "  污点     : $(kubectl get node $n -o jsonpath='{.spec.taints}' | head -c 200)"
  echo "  可调度   : $(kubectl get node $n -o jsonpath='{.spec.unschedulable}' | sed 's/^$/false/')"
done

hr "3. 命名空间"
kubectl get ns

hr "4. Service 清单"
kubectl get svc -A -o wide

hr "5. 存储（StorageClass / PV / PVC）"
kubectl get sc 2>&1
echo "--- PV ---"
kubectl get pv 2>&1
echo "--- PVC ---"
kubectl get pvc -A 2>&1

hr "6. 网络策略"
kubectl get networkpolicy -A 2>&1

hr "7. 各类资源数量"
printf "  %-22s %s\n" "RESOURCE" "COUNT"
for r in namespaces nodes pods services deployments statefulsets daemonsets replicasets replicationcontrollers jobs cronjobs configmaps secrets persistentvolumes persistentvolumeclaims serviceaccounts roles rolebindings clusterroles clusterrolebindings ingresses endpoints endpointslices events; do
  c=$(kubectl get "$r" -A --no-headers 2>/dev/null | wc -l)
  printf "  %-22s %s\n" "$r" "$c"
done

hr "8. 节点资源分配（requests/limits 汇总）"
for n in $(kubectl get nodes -o jsonpath='{.items[*].metadata.name}'); do
  echo "--- $n ---"
  kubectl describe node "$n" | sed -n '/Allocated resources/,/Events/p' | head -12
done

hr "9. 实时资源使用"
kubectl top nodes 2>&1
echo "--- Pod Top 10 ---"
kubectl top pods -A 2>&1 | head -12

hr "10. 现有业务负载详情"
echo "--- Deployments ---"
kubectl get deploy -A -o wide 2>&1
echo "--- 容器镜像 ---"
kubectl get pods -A -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}{"\t"}{range .spec.containers[*]}{.image}{" "}{end}{"\n"}{end}' 2>&1 | grep -v kube-system | head -20

hr "11. 容器运行时现状"
echo "kubelet CRI endpoint : $(grep -o 'containerRuntimeEndpoint:.*' /var/lib/kubelet/config.yaml)"
echo "cri-dockerd 版本     : $(cri-dockerd --version 2>/dev/null || rpm -q cri-dockerd)"
echo "containerd 版本      : $(containerd --version)"
echo "docker 版本          : $(docker --version)"
echo "kubelet 版本         : $(kubelet --version)"
echo "swappiness           : $(sysctl -n vm.swappiness)"
echo "cgroupDriver         : $(grep cgroupDriver /var/lib/kubelet/config.yaml)"
echo "系统 cgroup 版本     : $(stat -fc %T /sys/fs/cgroup)"

hr "12. Calico 现状"
kubectl -n kube-system get ds calico-node -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null; echo
kubectl get ippools.crd.projectcalico.org -o custom-columns='NAME:.metadata.name,CIDR:.spec.cidr,IPIP:.spec.ipipMode,VXLAN:.spec.vxlanMode,NAT:.spec.natOutgoing' 2>&1
echo "IP 池使用情况:"
kubectl get ipamblocks.crd.projectcalico.org -o custom-columns='NAME:.metadata.name,CIDR:.spec.cidr,AFFINITY:.spec.affinity' 2>&1 | head -10

hr "13. etcd 状态与备份现状"
ls -lh /var/lib/etcd/member/snap/ 2>/dev/null | head -5
echo "--- 是否有定时备份 ---"
crontab -l 2>/dev/null | grep -i etcd || echo "  无 crontab"
ls -la /var/backups/ 2>/dev/null || echo "  /var/backups 不存在"

hr "14. 系统关键参数"
echo "  ip_forward       : $(sysctl -n net.ipv4.ip_forward)"
echo "  bridge-nf-iptables: $(sysctl -n net.bridge.bridge-nf-call-iptables 2>/dev/null)"
echo "  内核模块         : $(lsmod | grep -cE '^(overlay|br_netfilter|ipip|ip_tunnel)') 个相关模块"
echo "  磁盘 /           : $(df -h / | awk 'NR==2{print $4" 可用 / "$2}')"
echo "  镜像占用         : $(docker system df 2>/dev/null | grep -E 'Images|Containers' | tr -s ' ' | tr '\n' ' ')"
