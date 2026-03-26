#!/usr/bin/env bash
set -euo pipefail

log() { echo -e "\n[$(date +%H:%M:%S)] $*"; }

ARCH=amd64
CNI_VERSION="v1.5.1"
K0S_VERSION="v1.35.2+k0s.0"

# --- containerd ---
log "Ensuring containerd"
if ! systemctl is-active --quiet containerd; then
  sudo apt-get update -y
  sudo apt-get install -y containerd
  sudo systemctl enable containerd
  sudo systemctl start containerd
fi

# --- CNI dirs ---
log "Ensuring CNI directories"
sudo mkdir -p /opt/cni/bin
sudo mkdir -p /etc/cni/net.d

# --- CNI plugins ---
if [ ! -f /opt/cni/bin/bridge ]; then
  log "Installing CNI plugins"
  TMP_DIR=$(mktemp -d)
  curl -L -o "$TMP_DIR/cni.tgz" \
    "https://github.com/containernetworking/plugins/releases/download/${CNI_VERSION}/cni-plugins-linux-${ARCH}-${CNI_VERSION}.tgz"
  sudo tar -C /opt/cni/bin -xzf "$TMP_DIR/cni.tgz"
  rm -rf "$TMP_DIR"
else
  log "CNI plugins already present"
fi

# --- k0s binary ---
if ! command -v k0s >/dev/null 2>&1; then
  log "Installing k0s"
  curl -sSLf https://get.k0s.sh | sudo sh
else
  log "k0s already installed"
fi

log "Prerequisites ready"
