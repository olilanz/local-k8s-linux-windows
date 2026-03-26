#!/usr/bin/env bash
set -euo pipefail

log() { echo -e "\n[$(date +%H:%M:%S)] $*"; }

# --- ensure API reachable ---
log "Checking API availability"
if ! sudo k0s kubectl get --raw=/healthz >/dev/null 2>&1; then
  echo "ERROR: API server not reachable. Run 02-cluster.sh first."
  exit 1
fi

# --- ensure networking exists ---
log "Checking Calico installation"
if ! sudo k0s kubectl get crd ippools.crd.projectcalico.org >/dev/null 2>&1; then
  echo "ERROR: Calico not installed. Run 03-network.sh first."
  exit 1
fi

# --- remove existing worker service (re-entrant) ---
log "Removing existing worker service (if any)"
sudo systemctl disable k0sworker 2>/dev/null || true
sudo rm -f /etc/systemd/system/k0sworker.service
sudo systemctl daemon-reexec
sudo systemctl daemon-reload

# --- create worker token ---
log "Creating worker token"
sudo k0s token create --role=worker > /tmp/k0s-worker-token

# --- install worker ---
log "Installing worker"
sudo k0s install worker --token-file /tmp/k0s-worker-token

# --- wait for node registration ---
log "Waiting for node registration"
for i in {1..60}; do
  if sudo k0s kubectl get nodes 2>/dev/null | grep -q "Ready"; then
    log "Node is Ready"
    sudo k0s kubectl get nodes -o wide
    exit 0
  fi
  sleep 2
done

echo "ERROR: Node did not register"
sudo k0s kubectl get nodes || true
exit 1
