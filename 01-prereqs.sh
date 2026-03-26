#!/usr/bin/env bash
set -euo pipefail

# Purpose: Install and verify host prerequisites for local cluster stages.
# Preconditions: Ubuntu-like host, sudo privileges, network access for package/image pulls.
# Invariants: Does not create/modify Kubernetes cluster control-plane state.
# Inputs: ARCH, CNI_VERSION, K0S_VERSION.
# Idempotency: Safe to rerun; already-present components are detected and reused.
# Postconditions: containerd running, CNI binaries present, k0s installed, base images pre-pulled.
# Safe rerun notes: Re-running may refresh package metadata and repull images.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/common.sh
source "${SCRIPT_DIR}/scripts/lib/common.sh"
init_script "${BASH_SOURCE[0]}"
register_error_trap

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
else
  log "containerd already running"
fi

# --- wait for containerd socket ---
log "Waiting for containerd socket"
for i in {1..20}; do
  if [ -S /run/containerd/containerd.sock ]; then
    log "containerd socket is ready"
    break
  fi
  sleep 1
done

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

# --- ensure executable ---
sudo chmod +x /opt/cni/bin/*

# --- k0s binary ---
if ! command -v k0s >/dev/null 2>&1; then
  log "Installing k0s"
  curl -sSLf https://get.k0s.sh | sudo sh
else
  log "k0s already installed"
fi

# --- pre-pull required images ---
log "Pre-pulling required images"

IMAGES=(
  "quay.io/calico/cni:v3.31.4"
  "quay.io/calico/node:v3.31.4"
  "quay.io/calico/kube-controllers:v3.31.4"
)

for IMAGE in "${IMAGES[@]}"; do
  log "Pulling $IMAGE"
  sudo ctr -n k8s.io images pull "$IMAGE"
done

summary "./02-cluster.sh"
