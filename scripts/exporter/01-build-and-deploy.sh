#!/bin/bash
# ============================================================
# P5-01  Build and deploy the custom Go exporter, then wire it
#        into Prometheus.
# Target: k8s-master01.  ASCII only.  Idempotent.
#   args: $1 = directory holding main.go + go.mod (default /tmp/exporter)
# ============================================================
set -u
export KUBECONFIG=/etc/kubernetes/admin.conf
SRC_DIR="${1:-/tmp/exporter}"
REPORT=/root/lab-reports/P5-exporter.txt
mkdir -p /root/lab-reports
: > "$REPORT"
say()  { echo "$@" | tee -a "$REPORT"; }
step() { echo "" | tee -a "$REPORT"; echo "==================== $* ====================" | tee -a "$REPORT"; }

step "0. Source"
ls -l "$SRC_DIR" | tee -a "$REPORT"
say "lines of Go: $(wc -l < "$SRC_DIR/main.go")"
say "external (non-stdlib) imports:"
awk '/^import \(/,/^\)/' "$SRC_DIR/main.go" | grep -E '^\s+"' | grep -vE '^\s+"(crypto|encoding|fmt|log|math|net|os|path|sort|strconv|strings|time|io)' | tee -a "$REPORT" || true
say "  (empty above == zero external dependencies, builds offline)"

step "1. Publish the source as a ConfigMap"
kubectl -n monitoring create configmap lab-exporter-src \
  --from-file=main.go="$SRC_DIR/main.go" \
  --from-file=go.mod="$SRC_DIR/go.mod" \
  --dry-run=client -o yaml 2>/dev/null | kubectl apply -f - 2>&1 | tee -a "$REPORT"

step "2. RBAC + build volume"
kubectl apply -f /tmp/exporter-manifests/00-rbac.yaml 2>&1 | tee -a "$REPORT"
kubectl apply -f /tmp/exporter-manifests/01-build-pvc.yaml 2>&1 | tee -a "$REPORT"

step "3. In-cluster build (golang image -> static binary on the PVC)"
say "the Job spec is immutable, so delete any previous run and recreate it"
kubectl -n monitoring delete job lab-exporter-build --ignore-not-found >/dev/null 2>&1
kubectl apply -f /tmp/exporter-manifests/02-build-job.yaml 2>&1 | tee -a "$REPORT"
say ""
say "waiting for the build ..."
kubectl -n monitoring wait --for=condition=Complete job/lab-exporter-build --timeout=600s 2>&1 | tee -a "$REPORT" || true
say ""
say "--- [EVIDENCE] build log ---"
kubectl -n monitoring logs job/lab-exporter-build 2>&1 | tee -a "$REPORT"

step "4. Deploy the exporter"
kubectl apply -f /tmp/exporter-manifests/03-deployment.yaml 2>&1 | tee -a "$REPORT"
kubectl -n monitoring rollout status deploy/lab-exporter --timeout=300s 2>&1 | tee -a "$REPORT" || true
kubectl -n monitoring get pods -l app=lab-exporter -o wide 2>&1 | tee -a "$REPORT"

step "5. [LANDMARK] the exporter's own metrics"
kubectl -n monitoring port-forward svc/lab-exporter 19101:9101 >/tmp/pf-exp.log 2>&1 &
PF=$!
for i in $(seq 1 20); do curl -s -o /dev/null http://127.0.0.1:19101/healthz && break; sleep 1; done
say "--- /healthz ---"
curl -s http://127.0.0.1:19101/healthz 2>&1 | tee -a "$REPORT"
say ""
say "--- cert expiry (parsed straight out of the mounted PKI directory) ---"
curl -s http://127.0.0.1:19101/metrics 2>/dev/null | grep '^lab_certificate' | sort | tee -a "$REPORT"
say ""
say "--- etcd backup freshness (the metric that should wake you up) ---"
curl -s http://127.0.0.1:19101/metrics 2>/dev/null | grep '^lab_etcd_backup' | sort | tee -a "$REPORT"
say ""
say "--- cluster health through the Kubernetes API ---"
curl -s http://127.0.0.1:19101/metrics 2>/dev/null | grep -E '^lab_(cluster|node|deployment|pdb|pv|namespace)_' | sort | tee -a "$REPORT"
say ""
say "--- exporter self-health ---"
curl -s http://127.0.0.1:19101/metrics 2>/dev/null | grep -E '^lab_exporter' | sort | tee -a "$REPORT"
say ""
say "total lab_* metric families exposed:"
curl -s http://127.0.0.1:19101/metrics 2>/dev/null | grep '^# TYPE lab_' | wc -l | tee -a "$REPORT"
kill $PF 2>/dev/null

step "6. Wire it into Prometheus"
say "re-applying the Prometheus config ConfigMap (now includes a lab-exporter scrape job)"
kubectl apply -f /tmp/monitoring/04-prometheus-config.yaml 2>&1 | tee -a "$REPORT"
say ""
say "--- validate the config with promtool BEFORE reloading (fail fast, not at 3am) ---"
kubectl -n monitoring exec statefulset/prometheus -- promtool check config /etc/prometheus/prometheus.yml 2>&1 | tee -a "$REPORT"
say ""
say "--- reload Prometheus via its lifecycle endpoint ---"
kubectl -n monitoring exec statefulset/prometheus -- \
  wget -qO- --post-data='' http://localhost:9090/-/reload 2>&1 | tee -a "$REPORT"
say "  (empty output == HTTP 200)"

step "7. Verify the new target"
sleep 25
kubectl -n monitoring port-forward svc/prometheus 19092:9090 >/tmp/pf-p2.log 2>&1 &
PF2=$!
for i in $(seq 1 20); do curl -s -o /dev/null http://127.0.0.1:19092/-/ready && break; sleep 1; done
say "--- is the lab-exporter target UP? ---"
curl -s http://127.0.0.1:19092/api/v1/targets 2>/dev/null | tr '{' '\n' | grep -A1 'lab-exporter' | head -6 | tee -a "$REPORT"
say ""
say "--- rule groups now loaded ---"
curl -s http://127.0.0.1:19092/api/v1/rules 2>/dev/null | tr '{' '\n' | grep -o '"name":"lab\.[a-z-]*"' | sort -u | tee -a "$REPORT"
say ""
say "--- live query of a metric produced by our own exporter ---"
for q in 'lab_etcd_backup_age_seconds' 'lab_certificate_expiry_days' 'lab_cluster_healthy' 'lab_pdb_allowed_disruptions'; do
  printf '  %-40s ' "$q"
  curl -s --get --data-urlencode "query=$q" http://127.0.0.1:19092/api/v1/query 2>/dev/null \
    | tr ',' '\n' | grep -m1 '"value"' || echo "(no data)"
done
kill $PF2 2>/dev/null

say ""
say "P5 complete."
echo "=== P5-01 DONE ==="
