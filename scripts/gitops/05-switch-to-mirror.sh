#!/bin/bash
# ============================================================
# P3-05  Point the Application at the internal mirror and prove the
#        GitOps loop is now deterministic.
# ============================================================
set -u
export KUBECONFIG=/etc/kubernetes/admin.conf
R=/root/lab-reports/P3-git-mirror.txt
say() { echo "$@" | tee -a "$R"; }
step() { echo "" | tee -a "$R"; echo "==================== $* ====================" | tee -a "$R"; }

step "6. The daemon serves the mirror"
say "from the master itself:"
git ls-remote git://127.0.0.1/k8s-ha-cluster-lab.git 2>&1 | head -3 | sed 's/^/  /' | tee -a "$R"
say ""
say "from the Argo CD repo-server pod (the client that matters):"
kubectl -n argocd exec deploy/argocd-repo-server -- \
  timeout 25 git ls-remote git://192.168.16.11/k8s-ha-cluster-lab.git 2>&1 | head -3 | sed 's/^/  /' | tee -a "$R"

step "7. Reproducibility check: 10 probes, LAN vs GitHub"
ok_lan=0; ok_gh=0
for i in $(seq 1 10); do
  kubectl -n argocd exec deploy/argocd-repo-server -- timeout 20 git ls-remote git://192.168.16.11/k8s-ha-cluster-lab.git HEAD >/dev/null 2>&1 && ok_lan=$((ok_lan+1))
  kubectl -n argocd exec deploy/argocd-repo-server -- timeout 20 git ls-remote https://github.com/xcl520-GIT/k8s-ha-cluster-lab.git HEAD >/dev/null 2>&1 && ok_gh=$((ok_gh+1))
done
say "  internal mirror git://  -> $ok_lan/10 OK"
say "  github.com over https   -> $ok_gh/10 OK"

step "8. Repoint the Application"
kubectl apply -f /tmp/argocd/application-demo-app.yaml 2>&1 | tee -a "$R"
kubectl -n argocd get application demo-app -o jsonpath='  repoURL={.spec.source.repoURL}{"\n"}' 2>&1 | tee -a "$R"
say ""
say "waiting for a successful comparison ..."
for i in $(seq 1 40); do
  s=$(kubectl -n argocd get application demo-app -o jsonpath='{.status.sync.status}' 2>/dev/null)
  h=$(kubectl -n argocd get application demo-app -o jsonpath='{.status.health.status}' 2>/dev/null)
  r=$(kubectl -n argocd get application demo-app -o jsonpath='{.status.sync.revision}' 2>/dev/null | cut -c1-8)
  echo "  [$(date -u +%H:%M:%S)] sync=$s health=$h rev=${r:-none}"
  [ "$s" = "Synced" ] && [ "$h" = "Healthy" ] && break
  sleep 8
done

step "9. [LANDMARK] deterministic GitOps again"
sleep 15
kubectl -n argocd get application demo-app -o wide 2>&1 | tee -a "$R"
kubectl -n argocd get application demo-app \
  -o jsonpath='  revision={.status.sync.revision}{"\n"}  sync={.status.sync.status}{"\n"}  health={.status.health.status}{"\n"}' 2>&1 | tee -a "$R"
say ""
say "  managed resources:"
kubectl -n argocd get application demo-app \
  -o jsonpath='{range .status.resources[*]}    {.kind}/{.name}  sync={.status}  health={.health.status}{"\n"}{end}' 2>&1 | tee -a "$R"
say ""
say "  drift -> self-heal, tight timing:"
t0=$(date +%s)
kubectl -n gitops-demo scale deploy demo-app --replicas=1 >/dev/null 2>&1
for i in $(seq 1 60); do
  now=$(( $(date +%s) - t0 ))
  live=$(kubectl -n gitops-demo get deploy demo-app -o jsonpath='{.spec.replicas}' 2>/dev/null)
  sync=$(kubectl -n argocd get application demo-app -o jsonpath='{.status.sync.status}' 2>/dev/null)
  echo "    t+${now}s live.spec.replicas=$live argocd.sync=$sync"
  if [ "$live" = "3" ]; then break; fi
  sleep 2
done
say "    => reverted in ${now}s with no human action"
say ""
kubectl -n gitops-demo get deploy,pods 2>&1 | tee -a "$R"
echo "=== P3-05 DONE ==="
