#!/bin/bash
# ============================================================
# P2  Install the monitoring stack: Prometheus + Alertmanager + Grafana
#     + node-exporter + kube-state-metrics.  Manual manifests, no Helm.
# Target: k8s-master01.  ASCII only.  Idempotent.
# ============================================================
set -u
export KUBECONFIG=/etc/kubernetes/admin.conf
DIR="${1:-/tmp/monitoring}"
REPORT=/root/lab-reports/P2-monitoring-install.txt
mkdir -p /root/lab-reports
: > "$REPORT"
say()  { echo "$@" | tee -a "$REPORT"; }
step() { echo "" | tee -a "$REPORT"; echo "==================== $* ====================" | tee -a "$REPORT"; }

step "0. Manifests"
ls -1 "$DIR" | tee -a "$REPORT"

step "1. Apply"
# --- Grafana admin credential: create-if-absent, NEVER clobber an existing one.
#     The tracked manifest carries a PLACEHOLDER only (see 08a-grafana-secret.yaml).
#     Real password, in order of preference:
#       1) GRAFANA_ADMIN_PASSWORD='***' ./install-monitoring.sh
#       2) pre-create the secret yourself (Sealed Secrets / External Secrets)
#       3) fall through to the placeholder - fine for a NAT-only lab
if kubectl -n monitoring get secret grafana-admin >/dev/null 2>&1; then
  say "--- secret/grafana-admin already exists -> LEFT UNTOUCHED (no password churn)"
  say "    rotate deliberately, e.g.:"
  say "      kubectl -n monitoring create secret generic grafana-admin \\"
  say "        --from-literal=admin-user=admin --from-literal=admin-password='***' \\"
  say "        --dry-run=client -o yaml | kubectl apply -f -"
elif [ -n "${GRAFANA_ADMIN_PASSWORD:-}" ]; then
  kubectl -n monitoring create secret generic grafana-admin \
    --from-literal=admin-user=admin \
    --from-literal=admin-password="$GRAFANA_ADMIN_PASSWORD" \
    --dry-run=client -o yaml | kubectl apply -f - 2>&1 | tee -a "$REPORT"
  say "--- secret/grafana-admin created from \$GRAFANA_ADMIN_PASSWORD (not from git)"
else
  say "--- no existing secret, no \$GRAFANA_ADMIN_PASSWORD -> applying the PLACEHOLDER manifest"
  kubectl apply -f "$DIR/08a-grafana-secret.yaml" 2>&1 | tee -a "$REPORT"
  say "!!! Grafana will start with the PLACEHOLDER password."
  say "!!! Rotate it before this cluster is reachable by anyone but you."
fi

for f in 00-namespace.yaml 01-prometheus-rbac.yaml 02-node-exporter.yaml 03-kube-state-metrics.yaml \
         04-prometheus-config.yaml 05-prometheus.yaml 06-alertmanager.yaml \
         07-grafana-provisioning.yaml 08-grafana.yaml ; do
  say "--- apply $f"
  kubectl apply -f "$DIR/$f" 2>&1 | tee -a "$REPORT"
done

step "2. Wait for workloads"
kubectl -n monitoring rollout status ds/node-exporter --timeout=300s 2>&1 | tee -a "$REPORT"
kubectl -n monitoring rollout status deploy/kube-state-metrics --timeout=300s 2>&1 | tee -a "$REPORT"
kubectl -n monitoring rollout status statefulset/prometheus --timeout=300s 2>&1 | tee -a "$REPORT" || true
kubectl -n monitoring rollout status deploy/alertmanager --timeout=300s 2>&1 | tee -a "$REPORT" || true
kubectl -n monitoring rollout status deploy/grafana --timeout=300s 2>&1 | tee -a "$REPORT" || true
say ""
kubectl -n monitoring get pods -o wide 2>&1 | tee -a "$REPORT"
kubectl -n monitoring get pvc,svc 2>&1 | tee -a "$REPORT"

step "3. Wait for Prometheus to load its config and see targets"
for i in $(seq 1 30); do
  ready=$(kubectl -n monitoring get pod -l app.kubernetes.io/name=prometheus -o jsonpath='{.items[0].status.containerStatuses[0].ready}' 2>/dev/null)
  [ "$ready" = "true" ] && break
  sleep 5
done
kubectl -n monitoring port-forward svc/prometheus 19090:9090 >/tmp/pf.log 2>&1 &
PF=$!
sleep 6
say ""
say "--- [LANDMARK 1] Prometheus target health ---"
curl -s http://127.0.0.1:19090/api/v1/targets 2>/dev/null \
  | tr ',' '\n' | grep -E '"health"|"job"|"scrapeUrl"' | paste - - - 2>/dev/null | head -40 | tee -a "$REPORT"
say ""
say "--- target up/down summary ---"
curl -s http://127.0.0.1:19090/api/v1/targets 2>/dev/null \
  | tr '{' '\n' | grep -o '"health":"[a-z]*"' | sort | uniq -c | tee -a "$REPORT"
say ""
say "--- loaded rule groups (must be 3) ---"
curl -s http://127.0.0.1:19090/api/v1/rules 2>/dev/null \
  | tr '{' '\n' | grep -o '"name":"lab\.[a-z]*"' | sort -u | tee -a "$REPORT"
say ""
say "--- Prometheus config reload check (build info) ---"
curl -s http://127.0.0.1:19090/api/v1/status/buildinfo 2>/dev/null | head -c 300 | tee -a "$REPORT"
echo "" | tee -a "$REPORT"
kill $PF 2>/dev/null

step "4. Quick query sanity checks"
kubectl -n monitoring exec statefulset/prometheus -- \
  wget -qO- 'http://localhost:9090/api/v1/query?query=count(up)' 2>/dev/null | head -c 300 | tee -a "$REPORT"
echo "" | tee -a "$REPORT"
say "P2 install complete."
echo "=== P2 INSTALL DONE ==="
