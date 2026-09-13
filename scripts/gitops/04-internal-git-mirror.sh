#!/bin/bash
# ============================================================
# P3-04  Internal Git mirror on the control-plane node.
#
# WHY
#   github.com is reachable from this lab only ~80% of the time (measured:
#   8/10 `git ls-remote` succeed). Argo CD's repo-server then parks the
#   Application at sync status "Unknown" and the GitOps demo looks broken at
#   random - a hard refresh did not recover it within 4 minutes. Enterprises
#   solve exactly this with an internal Git mirror: the public GitHub repo stays
#   the source of truth, and the cluster syncs from a LAN-local copy.
#
# RESULT
#   Argo CD syncs from  git://192.168.16.11/k8s-ha-cluster-lab.git
#   Mirror on disk     /srv/git/k8s-ha-cluster-lab.git  (bare)
#   daemon             systemd unit git-daemon.service, port 9418
#   Push from the workstation to BOTH remotes (tools/push-all.ps1).
#
# TRAPS ALREADY PAID FOR (do not repeat)
#   1. On Rocky/RHEL `git daemon` lives in its OWN subpackage: `git-daemon`.
#      Installing only `git` gives:
#        git: 'daemon' is not a git command
#      and a systemd unit stuck in an auto-restart loop.
#   2. The Rocky mirrorlist (mirrors.rockylinux.org) is slow enough that dnf
#      appears to hang. Repointing rocky*.repo at mirrors.aliyun.com fixed it.
#   3. Never seed the bare repo by `mv`-ing the contents of a failed
#      `git clone --mirror` - it leaves refs pointing at nothing and every later
#      push dies with "remote unpack failed: unpack-objects abnormal exit".
#      Recreate with `git init --bare` and seed by PUSHING.
#
# USAGE
#   bash 04-internal-git-mirror.sh          # set up / repair the mirror
# Target: k8s-master01 (control-plane).
# ============================================================
set -u
export KUBECONFIG=/etc/kubernetes/admin.conf
MIRROR=/srv/git/k8s-ha-cluster-lab.git
R=/root/lab-reports/P3-git-mirror.txt
mkdir -p /root/lab-reports
: > "$R"
say() { echo "$@" | tee -a "$R"; }
step() { echo "" | tee -a "$R"; echo "==================== $* ====================" | tee -a "$R"; }

step "1. Packages: git AND the git-daemon subpackage"
if ! command -v git >/dev/null 2>&1 || ! git daemon --version >/dev/null 2>&1; then
  say "checking the Rocky mirror first (the default mirrorlist is very slow):"
  curl -s -o /dev/null -w "  mirrors.aliyun.com/rockylinux -> %{http_code}\n" --max-time 12 https://mirrors.aliyun.com/rockylinux/ || true
  for f in /etc/yum.repos.d/rocky*.repo; do
    [ -f "${f}.orig" ] || cp -n "$f" "${f}.orig" 2>/dev/null || true
    sed -i -e 's|^mirrorlist=|#mirrorlist=|' \
           -e 's|^#baseurl=http://dl.rockylinux.org/\$contentdir|baseurl=https://mirrors.aliyun.com/rockylinux|' \
           -e 's|^baseurl=http://dl.rockylinux.org/\$contentdir|baseurl=https://mirrors.aliyun.com/rockylinux|' "$f"
  done
  timeout 420 dnf -y makecache 2>&1 | tail -3 | tee -a "$R" || say "  makecache timed out"
  timeout 420 dnf -y install git git-daemon 2>&1 | tail -6 | tee -a "$R" || say "  install timed out"
fi
say "git      : $(git --version 2>/dev/null || echo MISSING)"
say "git daemon: $(git daemon --version 2>&1 | head -1 || echo MISSING)"
git daemon --version >/dev/null 2>&1 || { say "ABORT: git daemon unavailable"; exit 1; }

step "2. Bare mirror repository (recreate cleanly if it is broken)"
if [ -d "$MIRROR" ] && ! git -C "$MIRROR" rev-parse --verify HEAD >/dev/null 2>&1; then
  say "existing mirror has no valid HEAD (broken seed) -> recreating"
  rm -rf "$MIRROR"
fi
if [ ! -d "$MIRROR" ]; then
  mkdir -p /srv/git
  git init --bare --initial-branch=main "$MIRROR" 2>&1 | tee -a "$R"
fi
touch "$MIRROR/git-daemon-export-ok"
chown -R root:root /srv/git
say "state: $(git -C "$MIRROR" rev-parse --is-bare-repository), HEAD -> $(git -C "$MIRROR" symbolic-ref HEAD 2>/dev/null)"

step "3. git daemon as a systemd service (port 9418)"
cat > /etc/systemd/system/git-daemon.service <<'EOF'
[Unit]
Description=Git daemon - internal mirror for the k8s-ha-cluster-lab repository
Documentation=man:git-daemon(1)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
# --base-path maps git://host/<repo>.git to /srv/git/<repo>.git
# --export-all serves every repo under base-path (fine on a lab LAN)
# --enable=receive-pack also permits pushes over git://
ExecStart=/usr/bin/git daemon \
  --reuseaddr \
  --base-path=/srv/git \
  --export-all \
  --enable=receive-pack \
  --informative-errors \
  --verbose \
  /srv/git
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl reset-failed git-daemon 2>/dev/null || true
systemctl enable --now git-daemon 2>&1 | tail -2 | tee -a "$R"
sleep 2
say "git-daemon: $(systemctl is-active git-daemon)"
ss -lntp 2>/dev/null | grep 9418 | sed 's/^/  /' | tee -a "$R" || say "  9418 NOT listening"

step "4. Seed / refresh the mirror"
if git -C "$MIRROR" rev-parse --verify HEAD >/dev/null 2>&1; then
  say "mirror already has commits:"
  git -C "$MIRROR" log --oneline -3 | sed 's/^/  /' | tee -a "$R"
  say ""
  say "to refresh it, push from the workstation (push-all.ps1 does both remotes):"
  say "  git push lab main --force"
else
  say "mirror is EMPTY - seed it by pushing from the workstation:"
  say "  cd <repo>; git remote add lab ssh://root@192.168.16.11/srv/git/k8s-ha-cluster-lab.git"
  say "  git push lab main --force"
fi

step "5. Serve check"
say "from this node:"
timeout 20 git ls-remote git://127.0.0.1/k8s-ha-cluster-lab.git 2>&1 | head -3 | sed 's/^/  /' | tee -a "$R" || say "  failed (mirror probably still empty - that is expected before the first push)"
say ""
say "from the Argo CD repo-server pod:"
kubectl -n argocd exec deploy/argocd-repo-server -- \
  timeout 25 git ls-remote git://192.168.16.11/k8s-ha-cluster-lab.git 2>&1 | head -3 | sed 's/^/  /' | tee -a "$R" || true

say ""
say "NEXT: run 05-switch-to-mirror.sh to repoint the Application and re-verify."
echo "=== P3-04 DONE ==="
