#!/bin/bash
# ============================================================
# P1-07 rollback: put a node back onto cri-dockerd + docker
# Usage:  07-cri-rollback.sh <backup-dir>
# ============================================================
set -u
BK="${1:-}"
NODE=$(hostname)
if [ -z "$BK" ] || [ ! -d "$BK" ]; then
  echo "usage: $0 /root/cri-migrate-YYYYmmdd-HHMMSS"
  echo "available backups:"; ls -d /root/cri-migrate-* 2>/dev/null
  exit 1
fi
echo "rolling back $NODE using $BK"
systemctl stop kubelet
[ -f "$BK/config.toml.orig" ]  && cp -a "$BK/config.toml.orig"  /etc/containerd/config.toml
[ -f "$BK/kubelet-config.yaml.orig" ] && cp -a "$BK/kubelet-config.yaml.orig" /var/lib/kubelet/config.yaml
[ -f "$BK/crictl.yaml.orig" ] && cp -a "$BK/crictl.yaml.orig" /etc/crictl.yaml
systemctl restart containerd
systemctl enable --now docker docker.socket cri-docker
sleep 5
echo "docker=$(systemctl is-active docker) cri-docker=$(systemctl is-active cri-docker)"
systemctl daemon-reload
systemctl start kubelet
sleep 10
echo "kubelet=$(systemctl is-active kubelet)"
grep containerRuntimeEndpoint /var/lib/kubelet/config.yaml
journalctl -u kubelet --no-pager -n 15
echo "=== ROLLBACK DONE ==="
