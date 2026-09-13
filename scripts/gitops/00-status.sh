#!/bin/bash
# Quick status of the Argo CD installation and the GitOps app.
set -u
export KUBECONFIG=/etc/kubernetes/admin.conf
echo "=== argocd namespace ==="
kubectl -n argocd get pods -o wide 2>&1
echo ""
echo "=== applications ==="
kubectl -n argocd get applications 2>&1
echo ""
echo "=== demo-app detail ==="
kubectl -n argocd get application demo-app \
  -o jsonpath='  sync={.status.sync.status}{"\n"}  health={.status.health.status}{"\n"}  phase={.status.operationState.phase}{"\n"}  message={.status.operationState.message}{"\n"}' 2>&1
echo ""
echo "=== conditions ==="
kubectl -n argocd get application demo-app -o jsonpath='{range .status.conditions[*]}  {.type}: {.message}{"\n"}{end}' 2>&1
echo ""
echo "=== managed resources ==="
kubectl -n argocd get application demo-app \
  -o jsonpath='{range .status.resources[*]}  {.kind}/{.name}  sync={.status}  health={.health.status}{"\n"}{end}' 2>&1
echo ""
echo "=== gitops-demo namespace ==="
kubectl -n gitops-demo get all,pdb,cm 2>&1
echo ""
echo "=== recent repo-server log ==="
kubectl -n argocd logs deploy/argocd-repo-server --tail=12 2>&1
echo "=== DONE ==="
