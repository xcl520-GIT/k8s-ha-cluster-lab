#!/bin/bash
# ============================================================
# 00-health-check.sh - run this FIRST after the VMs come back up.
# Prints a one-screen answer to "is the lab still OK?".
# Read-only: it changes nothing.
# ============================================================
set -u
export KUBECONFIG=/etc/kubernetes/admin.conf

hr() { printf '%s\n' "--------------------------------------------------------------"; }
bold() { printf '\n\033[1m%s\033[0m\n' "$*"; }

bold "1. Nodes and container runtime"
kubectl get nodes -o wide

bold "2. Anything not Running/Completed?"
bad=$(kubectl get pods -A --field-selector=status.phase!=Running,status.phase!=Succeeded --no-headers 2>/dev/null)
if [ -z "$bad" ]; then echo "  NONE - cluster is clean"; else echo "$bad"; fi

bold "3. Pods in the lab namespaces"
kubectl get pods -n monitoring -o wide 2>/dev/null
kubectl get pods -n gitops-demo -o wide 2>/dev/null || echo "  (gitops-demo not created yet - P3 pending)"

bold "4. monitoring stack summary"
kubectl -n monitoring get deploy,sts,ds,svc 2>/dev/null

bold "5. Storage"
kubectl get sc 2>/dev/null
kubectl get pvc -A 2>/dev/null | grep -vE "^kube-system" || true

bold "6. metrics-server still functional?"
kubectl top nodes 2>/dev/null || echo "  NOT WORKING"

bold "7. NetworkPolicy still enforcing?"
kubectl get networkpolicy -A 2>/dev/null

bold "8. Alert state right now"
kubectl -n monitoring port-forward svc/prometheus 19099:9090 >/tmp/hc-pf.log 2>&1 &
PF=$!
for i in $(seq 1 15); do curl -s -o /dev/null http://127.0.0.1:19099/-/ready && break; sleep 1; done
curl -s 'http://127.0.0.1:19099/api/v1/alertmanagers' >/dev/null 2>&1 \
  && curl -s 'http://127.0.0.1:19099/api/v1/rules' | tr '{' '\n' | grep -c '"name":"lab\.' | xargs echo "  rule groups loaded:"
curl -s 'http://127.0.0.1:19099/api/v1/targets' | tr ',' '\n' | grep -c '"health":"up"' | xargs echo "  targets UP:"
kill $PF 2>/dev/null

bold "9. Host tuning that P1-03 applied"
sysctl vm.swappiness net.core.somaxconn net.netfilter.nf_conntrack_max fs.inotify.max_user_watches 2>/dev/null

bold "10. Certificates"
kubeadm certs check-expiration 2>/dev/null | grep -E "CERTIFICATE|admin.conf|apiserver " | head -5

bold "11. etcd backup freshness"
ls -lt /var/backups/etcd/*.db 2>/dev/null | head -3 || echo "  NO BACKUPS FOUND"

bold "12. Lab entry points"
echo "  Grafana      http://192.168.16.11:30300   (admin / see local credentials file, NOT in repo)"
echo "  Prometheus   http://192.168.16.11:30090"
echo "  Alertmanager http://192.168.16.11:30093"
echo "  demo-app     http://192.168.16.11:30080"

hr
