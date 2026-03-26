#!/usr/bin/env bash
set -euo pipefail

# Purpose: Apply Calico networking configuration to the running cluster.
# Preconditions: Control plane is running and API is reachable.
# Invariants: Networking stage is explicit and separate from cluster bootstrap.
# Inputs: config/calico.yaml, config/calico-ippool.yaml, config/calico-ipam.yaml.
# Idempotency: Safe to rerun; manifests are applied declaratively.
# Postconditions: Calico resources applied and base CRDs available.
# Safe rerun notes: Re-apply may update resources but should preserve intent.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/common.sh
source "${SCRIPT_DIR}/scripts/lib/common.sh"
init_script "${BASH_SOURCE[0]}"
register_error_trap

SUDO_BIN=""
if [[ "${EUID}" -eq 0 ]]; then
  log "Running as root"
elif command -v sudo >/dev/null 2>&1; then
  if sudo -n true >/dev/null 2>&1; then
    SUDO_BIN="sudo"
    log "Using non-interactive sudo"
  else
    fail "This script needs privileged operations. Run with root privileges or enable non-interactive sudo for this session."
  fi
else
  fail "sudo is required when not running as root"
fi

as_root() {
  if [[ -n "${SUDO_BIN}" ]]; then
    "${SUDO_BIN}" "$@"
  else
    "$@"
  fi
}

k0s_kubectl() {
  as_root k0s kubectl "$@"
}

# --- ensure API reachable ---
log "Checking API availability"
if ! k0s_kubectl get --raw=/healthz >/dev/null 2>&1; then
  fail "API server not reachable. Run 02-cluster.sh first."
fi

# --- apply Calico ---
log "Installing Calico"
k0s_kubectl apply -f ./config/calico.yaml

# --- wait for CRDs ---
log "Waiting for Calico CRDs"
for i in {1..60}; do
  if k0s_kubectl get crd ippools.crd.projectcalico.org >/dev/null 2>&1; then
    log "Calico CRDs available"
    break
  fi
  sleep 2
done

if ! k0s_kubectl get crd ippools.crd.projectcalico.org >/dev/null 2>&1; then
  fail "Timed out waiting for Calico CRDs"
fi

# --- apply IP pool ---
log "Applying Calico IP pool"
k0s_kubectl apply -f ./config/calico-ippool.yaml

# --- apply IPAM config ---
log "Applying Calico IPAM config"
k0s_kubectl apply -f ./config/calico-ipam.yaml

# --- sanity check (NO node requirement) ---
log "Checking Calico control-plane components"
k0s_kubectl get pods -n kube-system || true

summary "./04-controller-token.sh"
