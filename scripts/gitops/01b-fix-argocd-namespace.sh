#!/bin/bash
# ============================================================
# P3-01b  Fix: the upstream install.yaml carries no metadata.namespace,
#         so it MUST be applied with `-n argocd`. Our first run applied it
#         without -n and everything landed in the `default` namespace.
#         This script: (1) proves the root cause, (2) removes the strays,
#         (3) re-applies correctly.
# ============================================================
set -u
export KUBECONFIG=/etc/kubernetes/admin.conf
MANIFEST="${1:-/tmp/argocd/install.yaml}"
REPORT=/root/lab-reports/P3-argocd-install.txt
say()  { echo "$@" | tee -a "$REPORT"; }
step() { echo "" | tee -a "$REPORT"; echo "==================== $* ====================" | tee -a "$REPORT"; }

step "1b-1. Root cause proof"
say "does the upstream manifest set metadata.namespace at all?"
say "  occurrences of 'namespace: argocd' in the manifest: $(grep -c 'namespace: argocd' "$MANIFEST" || true)"
say "  (they only appear inside ClusterRoleBinding subjects and webhook configs -"
say "   the workload objects themselves have NO namespace field, hence -n is mandatory)"
say ""
say "objects that wrongly landed in the default namespace:"
kubectl -n default get deploy,sts,svc,sa,cm,secret,networkpolicy,role,rolebinding -o name 2>/dev/null | grep argocd | tee -a "$REPORT" || true

step "1b-2. Remove the strays from default"
strays=$(kubectl -n default get deploy,sts,svc,sa,cm,secret,networkpolicy,role,rolebinding -o name 2>/dev/null | grep argocd || true)
if [ -n "$strays" ]; then
  kubectl -n default delete $strays --wait=true 2>&1 | tee -a "$REPORT"
else
  say "nothing to clean"
fi
say ""
say "default namespace now (should be argocd-free except the pre-existing lab workloads):"
kubectl -n default get deploy,svc,sa,cm,secret -o name 2>/dev/null | grep -i argocd || say "  no argocd objects left in default"

step "1b-3. Apply correctly with -n argocd"
kubectl apply -n argocd -f "$MANIFEST" 2>&1 | tail -30 | tee -a "$REPORT"

step "1b-4. Wait for the control plane"
for d in argocd-redis argocd-repo-server argocd-server argocd-applicationset-controller argocd-notifications-controller argocd-dex-server; do
  if kubectl -n argocd get deploy "$d" >/dev/null 2>&1; then
    kubectl -n argocd rollout status "deploy/$d" --timeout=420s 2>&1 | tee -a "$REPORT" || say "  !! $d not ready yet"
  fi
done
if kubectl -n argocd get statefulset argocd-application-controller >/dev/null 2>&1; then
  kubectl -n argocd rollout status statefulset/argocd-application-controller --timeout=420s 2>&1 | tee -a "$REPORT" || say "  !! controller not ready yet"
fi
say ""
kubectl -n argocd get pods -o wide 2>&1 | tee -a "$REPORT"

step "1b-5. NodePort 30333"
kubectl -n argocd patch svc argocd-server --type merge \
  -p '{"spec":{"type":"NodePort","ports":[{"name":"http","port":80,"targetPort":8080,"protocol":"TCP","nodePort":30333},{"name":"https","port":443,"targetPort":8080,"protocol":"TCP","nodePort":30443}]}}' 2>&1 | tee -a "$REPORT"
kubectl -n argocd get svc argocd-server 2>&1 | tee -a "$REPORT"

step "1b-6. Admin credential"
PW=$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' 2>/dev/null | base64 -d 2>/dev/null)
if [ -n "${PW:-}" ]; then
  say "admin user     : admin"
  say "admin password : $PW"
else
  say "argocd-initial-admin-secret not found"
fi
say ""
say "UI: http://192.168.16.11:30333"
echo "=== P3-01b DONE ==="
