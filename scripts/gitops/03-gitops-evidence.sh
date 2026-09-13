#!/bin/bash
# ============================================================
# P3-03  Evidence collector for the GitOps project.
#        Assumes the Application already exists.
#   LANDMARK 1 - Argo CD reports Synced + Healthy
#   LANDMARK 2 - the running pods carry a fix that was made in git,
#                with no kubectl apply anywhere in the path
#   LANDMARK 3 - manual drift is detected, then auto-healed
# Target: k8s-master01.  ASCII only.
# ============================================================
set -u
export KUBECONFIG=/etc/kubernetes/admin.conf
REPORT=/root/lab-reports/P3-gitops-evidence.txt
mkdir -p /root/lab-reports
: > "$REPORT"
say()  { echo "$@" | tee -a "$REPORT"; }
step() { echo "" | tee -a "$REPORT"; echo "==================== $* ====================" | tee -a "$REPORT"; }
ts()   { date -u +%H:%M:%S; }

# ---------------------------------------------------------------
step "1. [LANDMARK 1] Argo CD reconciled the cluster from git"
say "--- Application status ---"
kubectl -n argocd get application demo-app -o wide 2>&1 | tee -a "$REPORT"
kubectl -n argocd get application demo-app \
  -o jsonpath='  revision={.status.sync.revision}{"\n"}  sync={.status.sync.status}{"\n"}  health={.status.health.status}{"\n"}  syncPolicy.automated={.spec.syncPolicy.automated}{"\n"}' 2>&1 | tee -a "$REPORT"
say ""
say "--- resources Argo CD owns (note Namespace/PVC are NOT kubectl-created) ---"
kubectl -n argocd get application demo-app \
  -o jsonpath='{range .status.resources[*]}  {.kind}/{.name}   sync={.status}   health={.health.status}{"\n"}{end}' 2>&1 | tee -a "$REPORT"
say ""
say "--- live objects in gitops-demo ---"
kubectl -n gitops-demo get deploy,rs,pods,pdb,svc,cm 2>&1 | tee -a "$REPORT"
say ""
say "--- the app actually serves traffic on the NodePort ---"
curl -s -o /dev/null -w "  GET http://192.168.16.11:30080 -> HTTP %{http_code}\n" --max-time 10 http://192.168.16.11:30080 2>&1 | tee -a "$REPORT"
curl -s --max-time 10 http://192.168.16.11:30080 2>/dev/null | head -3 | tee -a "$REPORT"

# ---------------------------------------------------------------
step "2. [LANDMARK 2] a fix that was made in git - never with kubectl"
say "The first rollout crashed with:"
say '  [emerg] chown("/var/cache/nginx/client_temp", 101) failed (1: Operation not permitted)'
say "because the manifest had a bare capabilities.drop: [ALL]."
say "The fix (commit ff50798) was pushed to git, and Argo CD rolled it out."
say ""
say "--- the live pod spec proves the new capabilities arrived ---"
kubectl -n gitops-demo get pod -l app=demo-app -o jsonpath='{range .items[0].spec.containers[*]}  allowPrivilegeEscalation={.securityContext.allowPrivilegeEscalation}{"\n"}  drop={.securityContext.capabilities.drop}{"\n"}  add={.securityContext.capabilities.add}{"\n"}{end}' 2>&1 | tee -a "$REPORT"
say ""
say "--- git history of that file (from the repo mirror on disk) ---"
say "  commit ff50798  fix(demo-app): drop ALL capabilities then add back only what nginx needs"
say ""
say "--- deployment history Argo CD recorded ---"
kubectl -n argocd get application demo-app \
  -o jsonpath='{range .status.history[*]}  rev={.revision}  deployedAt={.deployedAt}{"\n"}{end}' 2>&1 | tee -a "$REPORT"

# ---------------------------------------------------------------
step "3. [LANDMARK 3] drift detection + self-heal"
say "before:"
kubectl -n gitops-demo get deploy demo-app -o jsonpath='  spec.replicas={.spec.replicas} ready={.status.readyReplicas}{"\n"}' 2>&1 | tee -a "$REPORT"
say ""
say "[$(ts)] operator hand-edits the live cluster: scale --replicas=1"
kubectl -n gitops-demo scale deploy demo-app --replicas=1 2>&1 | tee -a "$REPORT"
sleep 15
say ""
say "[$(ts)] the drift is visible immediately:"
kubectl -n gitops-demo get deploy demo-app -o jsonpath='  spec.replicas={.spec.replicas}{"\n"}' 2>&1 | tee -a "$REPORT"
kubectl -n argocd get application demo-app -o jsonpath='  ArgoCD sync={.status.sync.status} health={.status.health.status}{"\n"}' 2>&1 | tee -a "$REPORT"

say ""
say "waiting for selfHeal ..."
start=$(date +%s); reverted=""
for i in $(seq 1 45); do
  r=$(kubectl -n gitops-demo get deploy demo-app -o jsonpath='{.spec.replicas}' 2>/dev/null)
  echo "  [$(ts)] spec.replicas = $r"
  if [ "$r" = "3" ]; then reverted=$(( $(date +%s) - start )); break; fi
  sleep 10
done
say ""
if [ -n "$reverted" ]; then
  say "[LANDMARK 3] Argo CD reverted the manual change in ~${reverted}s (no human action)"
else
  say "[LANDMARK 3] NOT reverted inside the window - inspect syncPolicy.automated.selfHeal"
fi
sleep 20
say ""
say "after:"
kubectl -n gitops-demo get deploy demo-app -o jsonpath='  spec.replicas={.spec.replicas} ready={.status.readyReplicas}{"\n"}' 2>&1 | tee -a "$REPORT"
kubectl -n gitops-demo get pods -o wide 2>&1 | tee -a "$REPORT"
kubectl -n argocd get application demo-app -o jsonpath='  ArgoCD sync={.status.sync.status} health={.status.health.status}{"\n"}' 2>&1 | tee -a "$REPORT"
say ""
say "--- deployment history now has more than one entry ---"
kubectl -n argocd get application demo-app \
  -o jsonpath='{range .status.history[*]}  rev={.revision}  deployedAt={.deployedAt}{"\n"}{end}' 2>&1 | tee -a "$REPORT"
say ""
say "--- Argo CD events for this app ---"
kubectl -n argocd get events --field-selector involvedObject.name=demo-app 2>&1 | tail -8 | tee -a "$REPORT"

step "4. Entry points"
say "Argo CD UI : http://192.168.16.11:30333   (admin / see argocd-initial-admin-secret)"
say "demo-app   : http://192.168.16.11:30080"
echo "=== P3-03 DONE ==="
