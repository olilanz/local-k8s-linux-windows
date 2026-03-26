#!/usr/bin/env bash
set -euo pipefail

# Purpose: Install and start a clean k0s control plane on the Linux VM.
# Preconditions: Prerequisites stage completed, valid /etc/k0s/k0s.yaml present.
# Invariants: Controller-only installation; worker disabled on this node.
# Inputs: K0S_CONFIG_PATH.
# Idempotency: Safe to rerun for controller reconciliation.
# Postconditions: k0scontroller service active and Kubernetes API reachable.
# Safe rerun notes: Existing controller service may be reinstalled/re-enabled.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/common.sh
source "${SCRIPT_DIR}/scripts/lib/common.sh"
init_script "${BASH_SOURCE[0]}"
register_error_trap

K0S_CONFIG_PATH="/etc/k0s/k0s.yaml"
KUBECTL="sudo k0s kubectl"

# ------------------------------------------------------------------------------
# Pre-flight
# ------------------------------------------------------------------------------

log "Ensuring clean state (controller only)"

sudo systemctl stop k0sworker 2>/dev/null || true
sudo systemctl stop k0scontroller 2>/dev/null || true

# Clean stale runtime artifacts (non-destructive)
sudo rm -f /run/k0s/status.sock 2>/dev/null || true

# ------------------------------------------------------------------------------
# Install controller (NO worker)
# ------------------------------------------------------------------------------

log "Installing k0s controller (control-plane only)"

sudo k0s install controller \
  --config "${K0S_CONFIG_PATH}" \
  --enable-worker=false

# ------------------------------------------------------------------------------
# Start controller
# ------------------------------------------------------------------------------

log "Starting k0s controller"

sudo systemctl daemon-reexec
sudo systemctl daemon-reload
sudo systemctl enable k0scontroller
sudo systemctl start k0scontroller

# ------------------------------------------------------------------------------
# Wait for API to come up
# ------------------------------------------------------------------------------

log "Waiting for Kubernetes API"

# Wait for port first
until sudo ss -tulnp | grep -q ":6443"; do
  sleep 2
done

# Wait for API health
until curl -k https://127.0.0.1:6443/healthz >/dev/null 2>&1; do
  sleep 2
done

log "API is responding"

# ------------------------------------------------------------------------------
# Setup kubeconfig (optional, but useful for debugging)
# ------------------------------------------------------------------------------

log "Setting up kubeconfig"

mkdir -p "$HOME/.kube"
sudo cp /var/lib/k0s/pki/admin.conf "$HOME/.kube/config"
sudo chown "$(id -u)":"$(id -g)" "$HOME/.kube/config"

export KUBECONFIG="$HOME/.kube/config"

# ------------------------------------------------------------------------------
# Verify control-plane-only state
# ------------------------------------------------------------------------------

log "Verifying control plane only (no worker expected)"

$KUBECTL get nodes || true

# ------------------------------------------------------------------------------
# Inspect system pods (some may be Pending until worker joins)
# ------------------------------------------------------------------------------

log "Inspecting kube-system pods"

$KUBECTL get pods -n kube-system -o wide

# ------------------------------------------------------------------------------
# Done
# ------------------------------------------------------------------------------

log "Control plane is ready (no worker running on this node)"
summary "./03-network.sh"
