#!/bin/bash
# ============================================================
# P1-05  NetworkPolicy east-west isolation on Calico (IPIP)
# Target: k8s-master01.  ASCII only.  Idempotent.
# ============================================================
set -u
export KUBECONFIG=/etc/kubernetes/admin.conf
REPORT=/root/lab-reports/P1-05-networkpolicy.txt
mkdir -p /root/lab-reports
: > "$REPORT"
NS=netpol-lab
say()  { echo "$@" | tee -a "$REPORT"; }
step() { echo "" | tee -a "$REPORT"; echo "==================== $* ====================" | tee -a "$REPORT"; }

step "0. Preflight: CNI in use"
kubectl get pods -n kube-system -l k8s-app=calico-node -o wide 2>&1 | tee -a "$REPORT"
kubectl get ippools.crd.projectcalico.org -o custom-columns='NAME:.metadata.name,CIDR:.spec.cidr,IPIP:.spec.ipipMode,VXLAN:.spec.vxlanMode,NATOUT:.spec.natOutgoing' 2>&1 | tee -a "$REPORT"

# ------------------------------------------------------------
step "1. Build the lab namespace"
kubectl create ns $NS 2>/dev/null || true
kubectl -n $NS delete deploy,pod --all >/dev/null 2>&1 || true
kubectl -n $NS delete networkpolicy --all >/dev/null 2>&1 || true
cat <<'YAML' | kubectl apply -f - 2>&1 | tee -a "$REPORT"
apiVersion: apps/v1
kind: Deployment
metadata: {name: web, namespace: netpol-lab}
spec:
  replicas: 2
  selector: {matchLabels: {app: web}}
  template:
    metadata: {labels: {app: web, tier: frontend}}
    spec:
      containers:
      - name: c
        image: nginx:1.27-alpine
        ports: [{containerPort: 80}]
        resources:
          requests: {cpu: 50m, memory: 32Mi}
          limits: {cpu: 200m, memory: 64Mi}
---
apiVersion: v1
kind: Service
metadata: {name: web-svc, namespace: netpol-lab}
spec:
  selector: {app: web}
  ports: [{port: 80, targetPort: 80}]
---
apiVersion: apps/v1
kind: Deployment
metadata: {name: api, namespace: netpol-lab}
spec:
  replicas: 2
  selector: {matchLabels: {app: api}}
  template:
    metadata: {labels: {app: api, tier: backend}}
    spec:
      containers:
      - name: c
        image: nginx:1.27-alpine
        ports: [{containerPort: 80}]
        resources:
          requests: {cpu: 50m, memory: 32Mi}
          limits: {cpu: 200m, memory: 64Mi}
---
apiVersion: v1
kind: Service
metadata: {name: api-svc, namespace: netpol-lab}
spec:
  selector: {app: api}
  ports: [{port: 80, targetPort: 80}]
---
apiVersion: apps/v1
kind: Deployment
metadata: {name: client-ok, namespace: netpol-lab}
spec:
  replicas: 1
  selector: {matchLabels: {app: client-ok}}
  template:
    metadata: {labels: {app: client-ok, access: allowed}}
    spec:
      containers:
      - name: c
        image: busybox:1.36
        command: ["sh", "-c", "sleep 3600"]
        resources:
          requests: {cpu: 20m, memory: 16Mi}
          limits: {cpu: 100m, memory: 32Mi}
---
apiVersion: apps/v1
kind: Deployment
metadata: {name: client-bad, namespace: netpol-lab}
spec:
  replicas: 1
  selector: {matchLabels: {app: client-bad}}
  template:
    metadata: {labels: {app: client-bad, access: denied}}
    spec:
      containers:
      - name: c
        image: busybox:1.36
        command: ["sh", "-c", "sleep 3600"]
        resources:
          requests: {cpu: 20m, memory: 16Mi}
          limits: {cpu: 100m, memory: 32Mi}
YAML
kubectl -n $NS rollout status deploy/web --timeout=180s 2>&1 | tee -a "$REPORT"
kubectl -n $NS rollout status deploy/api --timeout=180s 2>&1 | tee -a "$REPORT"
kubectl -n $NS rollout status deploy/client-ok --timeout=180s 2>&1 | tee -a "$REPORT"
kubectl -n $NS rollout status deploy/client-bad --timeout=180s 2>&1 | tee -a "$REPORT"
kubectl -n $NS get pods -o wide 2>&1 | tee -a "$REPORT"

# ------------------------------------------------------------
run_matrix() {
  local phase="$1"
  say ""
  say "----- connectivity matrix : $phase -----"
  printf '%-14s %-12s %-12s\n' "FROM" "-> web-svc" "-> api-svc" | tee -a "$REPORT"
  local srcs="client-ok client-bad web"
  for s in $srcs; do
    pod=$(kubectl -n $NS get pod -l app=$s -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
    row=$(printf '%-14s' "$s")
    for tgt in web-svc api-svc; do
      if [ -z "$pod" ]; then r="NOPOD"; else
        if kubectl -n $NS exec "$pod" -- timeout 5 wget -T 3 -q -O /dev/null "http://$tgt.$NS.svc.cluster.local" >/dev/null 2>&1; then
          r="ALLOW"
        else
          r="DENY"
        fi
      fi
      row="$row $(printf '%-12s' "$r")"
    done
    echo "$row" | tee -a "$REPORT"
  done
}

step "2. Baseline - no policy at all"
say "networkpolicies in ns: $(kubectl -n $NS get networkpolicy --no-headers 2>/dev/null | wc -l)"
run_matrix "PHASE A - baseline (expected: everything ALLOW)"

# ------------------------------------------------------------
step "3. Apply default-deny ingress"
cat <<'YAML' | kubectl apply -f - 2>&1 | tee -a "$REPORT"
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: {name: default-deny-ingress, namespace: netpol-lab}
spec:
  podSelector: {}
  policyTypes: [Ingress]
YAML
sleep 8
run_matrix "PHASE B - default deny ingress (expected: every cross-pod flow DENY)"

# ------------------------------------------------------------
step "4. Apply least-privilege allow policies"
cat <<'YAML' | kubectl apply -f - 2>&1 | tee -a "$REPORT"
# frontend accepts traffic only from pods carrying access=allowed
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: {name: web-allow-trusted, namespace: netpol-lab}
spec:
  podSelector:
    matchLabels: {app: web}
  policyTypes: [Ingress]
  ingress:
  - from:
    - podSelector:
        matchLabels: {access: allowed}
    ports:
    - {protocol: TCP, port: 80}
---
# backend accepts traffic only from the frontend tier
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: {name: api-allow-frontend, namespace: netpol-lab}
spec:
  podSelector:
    matchLabels: {app: api}
  policyTypes: [Ingress]
  ingress:
  - from:
    - podSelector:
        matchLabels: {tier: frontend}
    ports:
    - {protocol: TCP, port: 80}
YAML
sleep 8
run_matrix "PHASE C - least privilege (expected: client-ok->web ALLOW, client-bad->web DENY, web->api ALLOW, client-ok->api DENY)"

# ------------------------------------------------------------
step "5. Evidence"
say "--- policies in $NS ---"
kubectl -n $NS get networkpolicy 2>&1 | tee -a "$REPORT"
say ""
say "--- NetworkPolicy count cluster wide ---"
kubectl get networkpolicy -A 2>&1 | tee -a "$REPORT"
say ""
say "NOTE: enforcement happens in the CNI data plane (Calico Felix)."
say "Calico fails CLOSED: a pod selected by a policy with no matching allow rule is denied."
say "P1-05 complete."
echo "REPORT_FILE=$REPORT"
echo "=== P1-05 DONE ==="
