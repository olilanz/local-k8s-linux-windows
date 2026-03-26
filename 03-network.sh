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

# --- ensure API reachable ---
log "Checking API availability"
if ! sudo k0s kubectl get --raw=/healthz >/dev/null 2>&1; then
  echo "ERROR: API server not reachable. Run 02-cluster.sh first."
  exit 1
fi

# --- apply Calico ---
log "Installing Calico"
sudo k0s kubectl apply -f ./config/calico.yaml

# --- wait for CRDs ---
log "Waiting for Calico CRDs"
for i in {1..60}; do
  if sudo k0s kubectl get crd ippools.crd.projectcalico.org >/dev/null 2>&1; then
    log "Calico CRDs available"
    break
  fi
  sleep 2
done

# --- apply IP pool ---
log "Applying Calico IP pool"
sudo k0s kubectl apply -f ./config/calico-ippool.yaml

# --- apply IPAM config ---
log "Applying Calico IPAM config"
sudo k0s kubectl apply -f ./config/calico-ipam.yaml

# --- sanity check (NO node requirement) ---
log "Checking Calico control-plane components"
sudo k0s kubectl get pods -n kube-system || true

summary "./04-linux-node.sh"
