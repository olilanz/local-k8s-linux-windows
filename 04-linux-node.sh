#!/usr/bin/env bash
set -euo pipefail

log() { echo -e "\n[$(date +%H:%M:%S)] $*"; }

# --- ensure API reachable ---
log "Checking API availability"
if ! sudo k0s kubectl get --raw=/healthz >/dev/null 2>&1; then
  echo "ERROR: API server not reachable. Run 02-cluster.sh first."
  exit 1
fi

# --- ensure Calico CRDs exist ---
log "Checking Calico CRDs"
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

log "Starting worker service"
sudo systemctl start k0sworker

log "Ensuring worker service is active"
sudo systemctl is-active --quiet k0sworker || {
  echo "ERROR: k0sworker failed to start"
  sudo journalctl -u k0sworker -n 50 --no-pager
  exit 1
}

# --- wait for node registration ---
log "Waiting for node registration"
for i in {1..60}; do
  if sudo k0s kubectl get nodes 2>/dev/null | grep -q "Ready"; then
    log "Node is Ready"
    sudo k0s kubectl get nodes -o wide
    break
  fi
  sleep 2
done

# --- wait for calico-node to be running ---
log "Waiting for calico-node to become ready"
for i in {1..60}; do
  if sudo k0s kubectl get pods -n kube-system -l k8s-app=calico-node \
      2>/dev/null | grep -q "Running"; then
    log "Calico node is running"
    sudo k0s kubectl get pods -n kube-system
    exit 0
  fi
  sleep 2
done

echo "ERROR: Node or Calico did not become ready"
sudo k0s kubectl get nodes || true
sudo k0s kubectl get pods -n kube-system || true
exit 1
