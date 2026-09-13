#!/bin/bash
# ============================================================
# P1-07  CRI migration: cri-dockerd (docker 29.6.2) -> containerd 2.2.6
# Usage:  07-cri-migrate.sh <worker|control-plane>
# Runs ON the node itself.  ASCII only.
#
# Strategy
#   1. back up current configs
#   2. write a containerd 2.x config with SystemdCgroup=true,
#      sandbox_image = aliyun pause (registry.k8s.io is blocked here),
#      and certs.d mirrors for docker.io / registry.k8s.io
#   3. pre-seed the containerd image store FROM the docker image store
#      (mandatory: the old private registry 192.168.16.60 is dead)
#   4. stop cri-dockerd + docker, remove the old docker containers
#   5. repoint kubelet at unix:///run/containerd/containerd.sock
# ============================================================
set -u
ROLE="${1:-worker}"
NODE=$(hostname)
TS=$(date +%Y%m%d-%H%M%S)
BK="/root/cri-migrate-$TS"
REPORT="/root/lab-reports/P1-07-cri-migrate-$NODE.txt"
PAUSE_IMG="registry.aliyuncs.com/google_containers/pause:3.10.1"
mkdir -p "$BK" /root/lab-reports
say()  { echo "$@" | tee -a "$REPORT"; }
step() { echo "" | tee -a "$REPORT"; echo "==================== $* ====================" | tee -a "$REPORT"; }
say "node=$NODE role=$ROLE backup=$BK"

step "0. BEFORE"
say "runtime seen by kubelet config:"
grep -E "containerRuntimeEndpoint|cgroupDriver" /var/lib/kubelet/config.yaml | tee -a "$REPORT"
say "services: cri-docker=$(systemctl is-active cri-docker 2>/dev/null) docker=$(systemctl is-active docker)" 
say "containerd=$(systemctl is-active containerd) $(containerd --version)"
say "docker images: $(docker images -q | wc -l)"
say "containerd images: $(ctr -n k8s.io images ls -q 2>/dev/null | wc -l)"

step "1. Backup"
cp -a /etc/containerd/config.toml "$BK/config.toml.orig" 2>/dev/null || true
cp -a /var/lib/kubelet/config.yaml "$BK/kubelet-config.yaml.orig" 2>/dev/null || true
cp -a /etc/crictl.yaml "$BK/crictl.yaml.orig" 2>/dev/null || true
cp -a /etc/docker/daemon.json "$BK/docker-daemon.json.orig" 2>/dev/null || true
docker images --format '{{.Repository}}:{{.Tag}}' > "$BK/docker-images.txt" 2>/dev/null || true
systemctl status cri-docker --no-pager > "$BK/cri-docker.status" 2>&1 || true
say "saved: $(ls "$BK" | tr '\n' ' ')"
say "docker image inventory:"
cat "$BK/docker-images.txt" | tee -a "$REPORT"

step "2. Registry mirrors (containerd 2.x certs.d)"
mkdir -p /etc/containerd/certs.d/docker.io /etc/containerd/certs.d/registry.k8s.io
cat > /etc/containerd/certs.d/docker.io/hosts.toml <<'EOF'
server = "https://registry-1.docker.io"

[host."https://docker.m.daocloud.io"]
  capabilities = ["pull", "resolve"]

[host."https://docker.1ms.run"]
  capabilities = ["pull", "resolve"]
EOF
cat > /etc/containerd/certs.d/registry.k8s.io/hosts.toml <<'EOF'
server = "https://registry.k8s.io"

[host."https://m.daocloud.io/registry.k8s.io"]
  capabilities = ["pull", "resolve"]
EOF
say "docker.io/hosts.toml + registry.k8s.io/hosts.toml written"

step "3. Write containerd 2.x config"
containerd config default > /etc/containerd/config.toml
sed -i "s|sandbox = 'registry.k8s.io/pause:3.10.1'|sandbox = '$PAUSE_IMG'|" /etc/containerd/config.toml
sed -i "s|SystemdCgroup = false|SystemdCgroup = true|" /etc/containerd/config.toml
sed -i "0,/config_path = ''/{s|config_path = ''|config_path = '/etc/containerd/certs.d'|}" /etc/containerd/config.toml
say "key settings:"
grep -nE "sandbox = |SystemdCgroup|config_path = " /etc/containerd/config.toml | tee -a "$REPORT"
if containerd config dump >/dev/null 2>&1; then
  say "config syntax OK"
else
  say "FATAL: containerd config invalid -> restoring and aborting"
  cp -a "$BK/config.toml.orig" /etc/containerd/config.toml
  exit 1
fi

step "4. Restart containerd"
systemctl restart containerd
sleep 5
say "containerd=$(systemctl is-active containerd)"
systemctl status containerd --no-pager | head -12 | tee -a "$REPORT"

step "5. Migrate images: docker store -> containerd store"
ok=0; bad=0
while read -r img; do
  [ -z "$img" ] && continue
  case "$img" in *'<none>'*) continue;; esac
  if docker save "$img" 2>/dev/null | ctr -n k8s.io images import - >/dev/null 2>&1; then
    ok=$((ok+1)); say "  imported  $img"
  else
    bad=$((bad+1)); say "  FAILED    $img"
  fi
done < "$BK/docker-images.txt"
say "imported=$ok failed=$bad"
say "containerd images now: $(ctr -n k8s.io images ls -q 2>/dev/null | wc -l)"
say "sandbox present? $(ctr -n k8s.io images ls -q 2>/dev/null | grep -c "$PAUSE_IMG")"

step "6. Verify containerd can fetch from docker.io through the mirror"
say "NOTE: the ctr CLI does NOT read config.toml's registry.config_path, so --hosts-dir must be explicit."
say "      kubelet goes through the CRI plugin, which DOES use config_path -> no flag needed there."
if timeout 180 ctr -n k8s.io images pull --hosts-dir /etc/containerd/certs.d docker.io/library/busybox:1.36 >/tmp/ctrpull.log 2>&1; then
  say "MIRROR OK: pulled docker.io/library/busybox:1.36 via certs.d mirror"
else
  say "MIRROR WARN: $(tail -2 /tmp/ctrpull.log)"
  say "continuing, the image store is pre-seeded anyway"
fi

step "7. Retire cri-dockerd + docker"
systemctl disable --now cri-docker 2>&1 | tail -2 | tee -a "$REPORT"
say "cri-docker now: $(systemctl is-active cri-docker 2>/dev/null)"
say "removing old docker containers ..."
docker ps -aq 2>/dev/null | xargs -r docker rm -f >/dev/null 2>&1 || true
say "remaining docker containers: $(docker ps -aq 2>/dev/null | wc -l)"
systemctl disable --now docker docker.socket 2>&1 | tail -2 | tee -a "$REPORT"
say "docker now: $(systemctl is-active docker 2>/dev/null)"
say "leftover cri-dockerd socket: $(ls -l /var/run/cri-dockerd.sock 2>/dev/null || echo gone)"

if [ "$ROLE" = "control-plane" ]; then
  say "port check (must all be free before kubelet restart):"
  ss -lntp 2>/dev/null | grep -E ':(6443|2379|2380|10259|10257)\b' | tee -a "$REPORT" || say "  all control-plane ports free"
fi

step "8. Point kubelet at containerd"
cp -a /var/lib/kubelet/config.yaml "$BK/kubelet-config.yaml.pre-switch"
sed -i 's|containerRuntimeEndpoint: unix:///var/run/cri-dockerd.sock|containerRuntimeEndpoint: unix:///run/containerd/containerd.sock|' /var/lib/kubelet/config.yaml
sed -i 's|containerRuntimeEndpoint: unix:///var/run/cri-docker.sock|containerRuntimeEndpoint: unix:///run/containerd/containerd.sock|' /var/lib/kubelet/config.yaml
for f in /var/lib/kubelet/kubeadm-flags.env /etc/sysconfig/kubelet; do
  if [ -f "$f" ] && grep -q cri-dockerd "$f" 2>/dev/null; then
    sed -i 's|unix:///var/run/cri-dockerd.sock|unix:///run/containerd/containerd.sock|g' "$f"
    say "patched $f"
  fi
done
say "kubelet config now:"
grep -E "containerRuntimeEndpoint|cgroupDriver" /var/lib/kubelet/config.yaml | tee -a "$REPORT"

printf 'runtime-endpoint: unix:///run/containerd/containerd.sock\nimage-endpoint: unix:///run/containerd/containerd.sock\ntimeout: 10\ndebug: false\n' > /etc/crictl.yaml
say "wrote /etc/crictl.yaml"

step "9. Restart kubelet"
systemctl daemon-reload
systemctl restart kubelet
sleep 12
say "kubelet=$(systemctl is-active kubelet)"
if ! command -v crictl >/dev/null 2>&1; then
  say "installing crictl v1.34.0 (github.com reachable from here) ..."
  if curl -sSL --max-time 180 -o /tmp/crictl.tgz \
      https://github.com/kubernetes-sigs/cri-tools/releases/download/v1.34.0/crictl-v1.34.0-linux-amd64.tar.gz; then
    tar -C /usr/local/bin -xzf /tmp/crictl.tgz && chmod +x /usr/local/bin/crictl
    say "crictl: $(crictl --version)"
  else
    say "crictl download FAILED (not fatal)"
  fi
fi
say "--- kubelet log tail ---"
journalctl -u kubelet --no-pager -n 20 2>&1 | tee -a "$REPORT"
say ""
say "--- crictl info ---"
crictl info 2>&1 | head -22 | tee -a "$REPORT"
if [ "$ROLE" = "control-plane" ]; then
  say ""
  say "--- static pods under containerd ---"
  crictl pods 2>&1 | head -12 | tee -a "$REPORT"
fi

step "10. AFTER"
say "kubelet runtime endpoint: $(grep containerRuntimeEndpoint /var/lib/kubelet/config.yaml)"
say "containerd running: $(systemctl is-active containerd)  version: $(containerd --version)"
say "cri-docker: $(systemctl is-active cri-docker 2>/dev/null)  docker: $(systemctl is-active docker 2>/dev/null)"
say "REPORT_FILE=$REPORT"
echo "=== P1-07 MIGRATE DONE on $NODE ==="
