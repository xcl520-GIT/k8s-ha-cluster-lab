#!/bin/bash
# install crictl from GitHub releases (github.com is reachable)
set -u
VER=v1.34.0
URL="https://github.com/kubernetes-sigs/cri-tools/releases/download/$VER/crictl-$VER-linux-amd64.tar.gz"
if command -v crictl >/dev/null 2>&1; then echo "crictl already installed: $(crictl --version)"; exit 0; fi
echo "downloading $URL"
if curl -sSL --max-time 180 -o /tmp/crictl.tgz "$URL"; then
  ls -l /tmp/crictl.tgz
  tar -C /usr/local/bin -xzf /tmp/crictl.tgz && chmod +x /usr/local/bin/crictl
  printf 'runtime-endpoint: unix:///run/containerd/containerd.sock\nimage-endpoint: unix:///run/containerd/containerd.sock\ntimeout: 10\ndebug: false\n' > /etc/crictl.yaml
  echo "installed: $(crictl --version)"
  crictl info 2>&1 | head -20
else
  echo "DOWNLOAD FAILED"
fi
