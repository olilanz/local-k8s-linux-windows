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
require_privileged_access

# ------------------------------------------------------------------------------
# Pre-flight
# ------------------------------------------------------------------------------

log "Ensuring clean state (controller only)"

as_root systemctl stop k0sworker 2>/dev/null || true
as_root systemctl stop k0scontroller 2>/dev/null || true

# Clean stale runtime artifacts (non-destructive)
as_root rm -f /run/k0s/status.sock 2>/dev/null || true

# ------------------------------------------------------------------------------
# Install controller (NO worker)
# ------------------------------------------------------------------------------

log "Installing k0s controller (control-plane only)"
if as_root systemctl cat k0scontroller >/dev/null 2>&1; then
  log "k0scontroller service already installed; skipping install"
else
  as_root k0s install controller \
    --config "${K0S_CONFIG_PATH}" \
    --enable-worker=false
fi

# ------------------------------------------------------------------------------
# Start controller
# ------------------------------------------------------------------------------

log "Starting k0s controller"

as_root systemctl daemon-reexec
as_root systemctl daemon-reload
as_root systemctl enable k0scontroller
as_root systemctl start k0scontroller

# ------------------------------------------------------------------------------
# Wait for API to come up
# ------------------------------------------------------------------------------

log "Waiting for Kubernetes API"

# Wait for port first
port_deadline=$((SECONDS + 180))
until as_root ss -tulnp | grep -q ":6443"; do
  if (( SECONDS >= port_deadline )); then
    fail "Timed out waiting for API server port 6443"
  fi
  sleep 2
done

# Wait for API health
health_deadline=$((SECONDS + 180))
until curl -k https://127.0.0.1:6443/healthz >/dev/null 2>&1; do
  if (( SECONDS >= health_deadline )); then
    fail "Timed out waiting for API health endpoint"
  fi
  sleep 2
done

log "API is responding"

# ------------------------------------------------------------------------------
# Setup kubeconfig (optional, but useful for debugging)
# ------------------------------------------------------------------------------

log "Setting up kubeconfig"

TARGET_USER="${SUDO_USER:-$(id -un)}"
TARGET_HOME="${HOME}"
if [[ -n "${SUDO_USER:-}" ]]; then
  TARGET_HOME="$(getent passwd "${SUDO_USER}" | cut -d: -f6)"
fi

mkdir -p "${TARGET_HOME}/.kube"
as_root cp /var/lib/k0s/pki/admin.conf "${TARGET_HOME}/.kube/config"
as_root chown "$(id -u "${TARGET_USER}")":"$(id -g "${TARGET_USER}")" "${TARGET_HOME}/.kube/config"

export KUBECONFIG="${TARGET_HOME}/.kube/config"

# ------------------------------------------------------------------------------
# Verify control-plane-only state
# ------------------------------------------------------------------------------

log "Verifying control plane only (no worker expected)"

k0s_kubectl get nodes || true

# ------------------------------------------------------------------------------
# Inspect system pods (some may be Pending until worker joins)
# ------------------------------------------------------------------------------

log "Inspecting kube-system pods"

k0s_kubectl get pods -n kube-system -o wide

# ------------------------------------------------------------------------------
# Done
# ------------------------------------------------------------------------------

log "Control plane is ready (no worker running on this node)"
summary "./03-network.sh"
