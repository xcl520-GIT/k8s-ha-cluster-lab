#!/bin/bash
# ============================================================
# P5-02  Fix + rebuild + redeploy the exporter, then prove the
#        Prometheus/Grafana integration end to end.
#
# Two real defects found by RUNNING it:
#  (a) /var/backups/etcd was 0700 root:root, so a pod running as UID 65534 could
#      not list it -> lab_etcd_backup_* was empty. The DIRECTORY only needs to be
#      listable; the snapshot FILES stay 0600 so their content stays root-only.
#  (b) lab_cluster_healthy counted Released PVs as unhealthy. Under the Retain
#      policy a Released PV is the EXPECTED state (see the P1-06 demo), so it was
#      fixed in code: only stuck pods and replica mismatches count now.
#
# NOTE ON STYLE: never put python one-liners with nested quotes inside a bash
# single-quoted string - the shell closes the string at the first quote. Use a
# heredoc (<<'PY'). This cost us one debugging round.
# ============================================================
set -u
export KUBECONFIG=/etc/kubernetes/admin.conf

# Grafana admin password - never hard-code it in a tracked script.
#   GRAFANA_PW='***' ./02-fix-and-redeploy.sh
# When unset, it is read from the live grafana-admin Secret instead.
GRAFANA_PW="${GRAFANA_PW:-$(kubectl -n monitoring get secret grafana-admin \
  -o jsonpath='{.data.admin-password}' 2>/dev/null | base64 -d 2>/dev/null)}"
if [ -z "${GRAFANA_PW:-}" ]; then
  echo "ERROR: GRAFANA_PW is empty. Export it, or make sure the grafana-admin" >&2
  echo "       Secret exists in namespace 'monitoring'." >&2
  exit 1
fi

SRC_DIR="${1:-/tmp/exporter}"
R=/root/lab-reports/P5-exporter.txt
say() { echo "$@" | tee -a "$R"; }
step() { echo "" | tee -a "$R"; echo "==================== $* ====================" | tee -a "$R"; }

step "8. Defect (a): backup directory permissions"
say "before: $(ls -ld /var/backups/etcd)"
say "source main.go size: $(wc -c < "$SRC_DIR/main.go") bytes  (expect the fixed version)"
grep -c 'A Released PV is INFORMATIONAL' "$SRC_DIR/main.go" | xargs echo "  health-formula fix present:"
chmod 0755 /var/backups/etcd
say "after : $(ls -ld /var/backups/etcd)"
say "snapshot files are still root-only (content protected):"
ls -l /var/backups/etcd | head -3 | tee -a "$R"
su -s /bin/sh nobody -c 'ls /var/backups/etcd >/dev/null 2>&1 && echo "  uid 65534 can list: YES" || echo "  uid 65534 can list: NO"' 2>/dev/null || say "  (su test unavailable)"

step "9. Defect (b): rebuild with the corrected health formula"
kubectl -n monitoring create configmap lab-exporter-src \
  --from-file=main.go="$SRC_DIR/main.go" \
  --from-file=go.mod="$SRC_DIR/go.mod" \
  --dry-run=client -o yaml 2>/dev/null | kubectl apply -f - 2>&1 | tee -a "$R"
kubectl -n monitoring delete job lab-exporter-build --ignore-not-found >/dev/null 2>&1
kubectl apply -f /tmp/exporter-manifests/02-build-job.yaml 2>&1 | tee -a "$R"
kubectl -n monitoring wait --for=condition=Complete job/lab-exporter-build --timeout=600s 2>&1 | tee -a "$R" || true
kubectl -n monitoring logs job/lab-exporter-build 2>&1 | tail -10 | tee -a "$R"
kubectl -n monitoring rollout restart deploy/lab-exporter 2>&1 | tee -a "$R"
kubectl -n monitoring rollout status deploy/lab-exporter --timeout=300s 2>&1 | tee -a "$R"
sleep 15

step "10. [LANDMARK A] the exporter's corrected metrics, read straight off the pod"
kubectl -n monitoring port-forward svc/lab-exporter 19103:9101 >/tmp/pf-e3.log 2>&1 &
PF=$!
for i in $(seq 1 25); do curl -s -o /dev/null http://127.0.0.1:19103/healthz && break; sleep 1; done
curl -s http://127.0.0.1:19103/metrics > /tmp/exp-metrics.txt 2>/dev/null
grep -E '^lab_etcd_backup|^lab_cluster_healthy|^lab_certificate_expiring|^lab_pv_released|^lab_cluster_pods_not_running|^lab_deployments_replicas|^lab_pdb_blocked' /tmp/exp-metrics.txt | sort | tee -a "$R"
say ""
say "metric families exposed: $(grep -c '^# TYPE lab_' /tmp/exp-metrics.txt)"
kill $PF 2>/dev/null

step "11. [LANDMARK B] Prometheus is scraping it and stores the series"
sleep 30
kubectl -n monitoring port-forward svc/prometheus 19304:9090 >/tmp/pf-p4.log 2>&1 &
PF2=$!
for i in $(seq 1 25); do curl -s -o /dev/null http://127.0.0.1:19304/-/ready && break; sleep 1; done

curl -s http://127.0.0.1:19304/api/v1/targets > /tmp/t3.json 2>/dev/null
python3 - <<'PY' | tee -a "$R"
import json
d = json.load(open('/tmp/t3.json'))
up = down = 0
for t in d['data']['activeTargets']:
    if t['labels'].get('job') == 'lab-exporter':
        print(f"  [target] health={t['health']} url={t['scrapeUrl']} lastError={t.get('lastError','')!r}")
    if t['health'] == 'up':
        up += 1
    else:
        down += 1
print(f"  [targets] up={up} not-up={down} total={len(d['data']['activeTargets'])}")
PY

say ""
say "  selected series as Prometheus returns them:"
for q in 'up{job="lab-exporter"}' 'lab_etcd_backup_age_seconds' 'lab_etcd_backup_count' 'lab_cluster_healthy' 'lab_certificate_expiring_within_30d' 'lab_pdb_allowed_disruptions' 'lab_pv_released_total'; do
  printf '    %-40s ' "$q" >> "$R"; echo "" >> "$R"
  curl -s --get --data-urlencode "query=$q" http://127.0.0.1:19304/api/v1/query > /tmp/q.json 2>/dev/null
  python3 - <<'PY' | tee -a "$R"
import json
d = json.load(open('/tmp/q.json'))
res = d['data']['result']
if not res:
    print('      (no data)')
else:
    for x in res[:4]:
        lbl = ",".join(f"{k}={v}" for k, v in x['metric'].items() if k != '__name__')
        print(f"      {lbl or '<no labels>'} = {x['value'][1]}")
PY
done

say ""
say "  rule groups loaded (expect 4 including lab.customexporter):"
curl -s http://127.0.0.1:19304/api/v1/rules 2>/dev/null | tr '{' '\n' | grep -o '"name":"lab\.[a-zA-Z-]*"' | sort -u | tee -a "$R"
kill $PF2 2>/dev/null

step "12. [LANDMARK C] Grafana dashboard for the custom exporter"
kubectl apply -f /tmp/monitoring/07-grafana-provisioning.yaml 2>&1 | tee -a "$R"
say "waiting for the ConfigMap volume to reach the Grafana pod and for the"
say "provisioning provider to re-read it (updateIntervalSeconds: 30) ..."
for i in $(seq 1 30); do
  n=$(kubectl -n monitoring exec deploy/grafana -c grafana -- sh -c 'ls /var/lib/grafana/dashboards/ 2>/dev/null | wc -l' 2>/dev/null | tr -d '\r')
  echo "  [$(date -u +%H:%M:%S)] dashboards visible to Grafana: ${n:-?}"
  [ "${n:-0}" -ge 3 ] && break
  sleep 10
done
say ""
say "dashboards on disk inside the Grafana pod:"
kubectl -n monitoring exec deploy/grafana -c grafana -- ls -l /var/lib/grafana/dashboards/ 2>&1 | tee -a "$R"
say ""
say "dashboards Grafana has actually loaded (via its API):"
kubectl -n monitoring port-forward svc/grafana 13300:3000 >/tmp/pf-g.log 2>&1 &
PF3=$!
for i in $(seq 1 25); do curl -s -o /dev/null http://127.0.0.1:13300/api/health && break; sleep 1; done
curl -s -u "admin:$GRAFANA_PW" http://127.0.0.1:13300/api/search?type=dash-db 2>/dev/null > /tmp/dash.json
python3 - <<'PY' | tee -a "$R"
import json
try:
    d = json.load(open('/tmp/dash.json'))
except Exception as e:
    print("  could not read the Grafana API:", e); raise SystemExit
for x in d:
    print(f"  {x.get('title')!r}  uid={x.get('uid')}  folder={x.get('folderTitle')}")
print(f"  total dashboards: {len(d)}")
PY
say ""
say "--- data check: does the exporter panel have data? ---"
curl -s -u "admin:$GRAFANA_PW" \
  --get --data-urlencode 'query=lab_etcd_backup_age_seconds / 3600' \
  http://127.0.0.1:13300/api/datasources/proxy/uid/prometheus/api/v1/query 2>/dev/null \
  | head -c 300 | tee -a "$R"
echo "" >> "$R"
kill $PF3 2>/dev/null
say ""
say "P5 complete."
echo "=== P5-02 DONE ==="
