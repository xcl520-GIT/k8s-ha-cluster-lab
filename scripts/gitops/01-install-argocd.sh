#!/bin/bash
# ============================================================
# P3-01  Install Argo CD v2.13.1 from the vendored upstream manifest.
#        Exposes the API/UI server on NodePort 30333.
# Target: k8s-master01.  ASCII only.  Idempotent.
# ============================================================
set -u
export KUBECONFIG=/etc/kubernetes/admin.conf
MANIFEST="${1:-/tmp/argocd/install.yaml}"
REPORT=/root/lab-reports/P3-argocd-install.txt
mkdir -p /root/lab-reports
: > "$REPORT"
say()  { echo "$@" | tee -a "$REPORT"; }
step() { echo "" | tee -a "$REPORT"; echo "==================== $* ====================" | tee -a "$REPORT"; }

step "0. Manifest"
ls -lh "$MANIFEST" | tee -a "$REPORT"
say "images referenced by the manifest:"
grep -h "image:" "$MANIFEST" | sed 's/^ *//' | sort -u | tee -a "$REPORT"

step "1. Namespace + apply"
kubectl create ns argocd 2>/dev/null || true
# WARNING: the upstream install.yaml does NOT set metadata.namespace on the
# workload objects, so `-n argocd` is MANDATORY. Without it every Deployment
# and Service silently lands in `default` and the argocd namespace looks empty.
kubectl apply -n argocd -f "$MANIFEST" 2>&1 | tail -25 | tee -a "$REPORT"

step "2. Wait for the Argo CD control plane"
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

step "3. Expose the UI on a NodePort"
kubectl -n argocd patch svc argocd-server --type merge \
  -p '{"spec":{"type":"NodePort","ports":[{"name":"http","port":80,"targetPort":8080,"protocol":"TCP","nodePort":30333},{"name":"https","port":443,"targetPort":8080,"protocol":"TCP","nodePort":30443}]}}' 2>&1 | tee -a "$REPORT"
kubectl -n argocd get svc argocd-server 2>&1 | tee -a "$REPORT"

step "4. Admin credential"
PW=$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' 2>/dev/null | base64 -d 2>/dev/null)
if [ -n "${PW:-}" ]; then
  say "initial admin user : admin"
  say "initial admin password : $PW"
  say "(rotate it: kubectl -n argocd exec deploy/argocd-server -- argocd account update-password)"
else
  say "argocd-initial-admin-secret not found (already deleted?)"
fi

step "5. Version + CRDs"
kubectl -n argocd get crd | grep argoproj 2>&1 | tee -a "$REPORT"
kubectl -n argocd exec deploy/argocd-server -- argocd version --client 2>/dev/null | tee -a "$REPORT" || true

say ""
say "UI: http://192.168.16.11:30333   (admin / <password above>)"
echo "=== P3-01 DONE ==="
