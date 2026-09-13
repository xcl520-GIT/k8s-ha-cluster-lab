#!/bin/bash
# ============================================================
# P2-02  Alert fault-injection demo
#
#   ./02-alert-fault-demo.sh inject   # break two things on purpose
#   ./02-alert-fault-demo.sh status   # show what Prometheus + Alertmanager see
#   ./02-alert-fault-demo.sh clean    # remove the fault, alerts auto-resolve
#
# WHY: "the dashboard has graphs" is not the same as "the monitoring works".
# This injects REAL breakage so the whole chain is exercised:
#   real fault -> Prometheus rule fires -> Alertmanager receives & groups it.
# Nothing is pushed to a pushgateway; the alerts describe a thing we actually broke.
#
# Target: k8s-master01.  ASCII only.  Idempotent.
# ============================================================
set -u
export KUBECONFIG=/etc/kubernetes/admin.conf
NS=alert-lab

inject() {
  echo "== creating namespace $NS"
  kubectl create ns "$NS" --dry-run=client -o yaml | kubectl apply -f -

  echo "== fault (1/2): a Deployment that can never become Ready (CrashLoop)"
  cat <<'EOF' | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata: {name: crashloop-demo, namespace: alert-lab}
spec:
  replicas: 1
  selector: {matchLabels: {app: crashloop-demo}}
  template:
    metadata: {labels: {app: crashloop-demo}}
    spec:
      containers:
      - name: c
        image: busybox:1.36
        command: ["sh","-c","echo 'simulated startup failure'; exit 1"]
EOF

  echo "== fault (2/2): a Deployment pinned to a node label that does not exist"
  cat <<'EOF' | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata: {name: scale-gap-demo, namespace: alert-lab}
spec:
  replicas: 3
  selector: {matchLabels: {app: scale-gap-demo}}
  template:
    metadata: {labels: {app: scale-gap-demo}}
    spec:
      nodeSelector: {nonexistent-label: "true"}
      containers:
      - name: c
        image: busybox:1.36
        command: ["sh","-c","sleep 3600"]
EOF

  echo ""
  echo "Faults injected. Rules carry a 'for:' window, so wait 2-3 minutes."
  echo "Then:  $0 status"
}

show_state() {
  local url="$1" filter="$2" label="$3"
  echo "--- $label"
  curl -s "$url" | python3 -c "
import json,sys
d=json.load(sys.stdin)
items=$filter
for a in items:
    print('  [%s] %s ns=%s' % (a['state'].upper() if 'state' in a else a['status']['state'],
                               a['labels']['alertname'], a['labels'].get('namespace','-')))
print('  total: %d' % len(items))
" 2>/dev/null || echo "  (could not parse)"
}

status() {
  kubectl -n monitoring port-forward svc/prometheus 19090:9090 >/tmp/pf-prom.log 2>&1 &
  local p1=$!
  kubectl -n monitoring port-forward svc/alertmanager 19093:9093 >/tmp/pf-am.log 2>&1 &
  local p2=$!
  sleep 6
  show_state 'http://127.0.0.1:19090/api/v1/alerts' \
             'd["data"]["alerts"]' 'Prometheus /api/v1/alerts'
  echo ""
  show_state 'http://127.0.0.1:19093/api/v2/alerts' \
             'd' 'Alertmanager /api/v2/alerts'
  kill $p1 $p2 2>/dev/null
  echo ""
  echo "UI:  http://192.168.16.11:30093  (Alertmanager)"
  echo "     http://192.168.16.11:30090/alerts  (Prometheus)"
}

clean() {
  echo "== removing the injected faults"
  kubectl -n "$NS" delete deploy crashloop-demo scale-gap-demo --ignore-not-found
  echo "== waiting for the alerts to resolve"
  kubectl -n monitoring port-forward svc/alertmanager 19093:9093 >/tmp/pf-am.log 2>&1 &
  local p=$!
  sleep 6
  for i in $(seq 1 20); do
    n=$(curl -s http://127.0.0.1:19093/api/v2/alerts | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))' 2>/dev/null)
    echo "  [$(date -u +%H:%M:%S)] alerts still firing: ${n:-?}"
    [ "${n:-1}" = "0" ] && break
    sleep 15
  done
  kill $p 2>/dev/null
  kubectl delete ns "$NS" --ignore-not-found
  echo "cleanup done."
}

case "${1:-}" in
  inject) inject ;;
  status) status ;;
  clean)  clean  ;;
  *) echo "usage: $0 {inject|status|clean}"; exit 2 ;;
esac
