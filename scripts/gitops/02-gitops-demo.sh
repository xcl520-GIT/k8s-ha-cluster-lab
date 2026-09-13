#!/bin/bash
# ============================================================
# P3-02  GitOps in action:
#   LANDMARK 1 - Argo CD reports the app Synced + Healthy
#   LANDMARK 2 - manual drift is detected and auto-healed (selfHeal)
# Target: k8s-master01.  ASCII only.
# ============================================================
set -u
export KUBECONFIG=/etc/kubernetes/admin.conf
APP_MANIFEST="${1:-/tmp/argocd/application-demo-app.yaml}"
REPORT=/root/lab-reports/P3-gitops-demo.txt
mkdir -p /root/lab-reports
: > "$REPORT"
say()  { echo "$@" | tee -a "$REPORT"; }
step() { echo "" | tee -a "$REPORT"; echo "==================== $* ====================" | tee -a "$REPORT"; }
ts()   { date -u +%H:%M:%S; }

step "0. Prerequisite: can Argo CD reach the git repository?"
say "repo = https://github.com/xcl520-GIT/k8s-ha-cluster-lab.git"
curl -s -o /dev/null -w "  github.com reachable from the node: HTTP %{http_code} (t=%{time_total}s)\n" \
  --max-time 20 https://github.com/xcl520-GIT/k8s-ha-cluster-lab 2>&1 | tee -a "$REPORT"

step "1. Create the Application"
kubectl apply -f "$APP_MANIFEST" 2>&1 | tee -a "$REPORT"

say ""
say "waiting for the first sync (Argo CD has to clone the repo first) ..."
for i in $(seq 1 60); do
  sync=$(kubectl -n argocd get application demo-app -o jsonpath='{.status.sync.status}' 2>/dev/null)
  health=$(kubectl -n argocd get application demo-app -o jsonpath='{.status.health.status}' 2>/dev/null)
  echo "  [$(ts)] sync=${sync:-<none>} health=${health:-<none>}"
  [ "$sync" = "Synced" ] && [ "$health" = "Healthy" ] && break
  sleep 10
done

say ""
say "--- [LANDMARK 1] Argo CD Application state ---"
kubectl -n argocd get application demo-app -o wide 2>&1 | tee -a "$REPORT"
say ""
kubectl -n argocd get applications 2>&1 | tee -a "$REPORT"
say ""
say "--- sync operation detail ---"
kubectl -n argocd get application demo-app -o jsonpath='{.status.operationState.phase}{" | "}{.status.operationState.message}{"\n"}' 2>&1 | tee -a "$REPORT"
kubectl -n argocd get application demo-app -o jsonpath='{.status.summary}{"\n"}' 2>&1 | tee -a "$REPORT"
say ""
say "--- what Argo CD actually created in the cluster ---"
kubectl -n gitops-demo get all,pdb,cm 2>&1 | tee -a "$REPORT"
say ""
say "--- the resources Argo CD says it manages ---"
kubectl -n argocd get application demo-app -o jsonpath='{range .status.resources[*]}{"  "}{.kind}{"/"}{.name}{"  "}{.status}{"  "}{.health.status}{"\n"}{end}' 2>&1 | tee -a "$REPORT"

step "2. If the repo server could not clone, show the reason"
if [ "${sync:-}" != "Synced" ]; then
  say "sync is NOT Synced - diagnostics:"
  kubectl -n argocd logs deploy/argocd-repo-server --tail=30 2>&1 | tee -a "$REPORT"
  kubectl -n argocd get application demo-app -o jsonpath='{.status.conditions[*].message}{"\n"}' 2>&1 | tee -a "$REPORT"
  kubectl -n argocd logs statefulset/argocd-application-controller --tail=30 2>&1 | tee -a "$REPORT"
fi

step "3. LANDMARK 2 - drift detection + self-heal"
say "before:"
kubectl -n gitops-demo get deploy demo-app 2>&1 | tee -a "$REPORT"
say ""
say "[$(ts)] operator breaks the declared state by hand: scale --replicas=1"
kubectl -n gitops-demo scale deploy demo-app --replicas=1 2>&1 | tee -a "$REPORT"
sleep 12
say ""
say "[$(ts)] what the cluster looks like now:"
kubectl -n gitops-demo get deploy demo-app 2>&1 | tee -a "$REPORT"
say "Argo CD sync status now:"
kubectl -n argocd get application demo-app -o jsonpath='  sync={.status.sync.status} health={.status.health.status}{"\n"}' 2>&1 | tee -a "$REPORT"

say ""
say "waiting for selfHeal to revert it ..."
reverted_at=""
start=$(date +%s)
for i in $(seq 1 40); do
  r=$(kubectl -n gitops-demo get deploy demo-app -o jsonpath='{.spec.replicas}' 2>/dev/null)
  echo "  [$(ts)] spec.replicas = $r"
  if [ "$r" = "3" ]; then reverted_at=$(( $(date +%s) - start )); break; fi
  sleep 10
done
say ""
if [ -n "$reverted_at" ]; then
  say "[LANDMARK 2] Argo CD reverted the manual change in ~${reverted_at}s"
else
  say "[LANDMARK 2] selfHeal did not revert within the window - check syncPolicy.automated.selfHeal"
fi
sleep 15
say ""
say "after:"
kubectl -n gitops-demo get deploy demo-app,pods 2>&1 | tee -a "$REPORT"
kubectl -n argocd get application demo-app -o jsonpath='  sync={.status.sync.status} health={.status.health.status}{"\n"}' 2>&1 | tee -a "$REPORT"
say ""
say "the reverted revision is recorded in the app history:"
kubectl -n argocd get application demo-app -o jsonpath='{range .status.history[*]}{"  rev="}{.revision}{" deployedAt="}{.deployedAt}{"\n"}{end}' 2>&1 | tee -a "$REPORT"

step "4. Entry point"
say "demo-app: http://192.168.16.11:30080"
curl -s -o /dev/null -w "  direct HTTP check: %{http_code}\n" --max-time 10 http://192.168.16.11:30080 2>&1 | tee -a "$REPORT"
echo "=== P3-02 DONE ==="
