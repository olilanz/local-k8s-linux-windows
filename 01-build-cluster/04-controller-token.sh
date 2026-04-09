#!/usr/bin/env bash
set -euo pipefail

# Purpose: Generate worker join token on controller and, by default, join local worker context.
# Preconditions: Run on controller node after 02-cluster and 03-network.
# Inputs: TOKEN_OUT, AUTO_JOIN_LOCAL_WORKER, WORKER_DATA_DIR, KUBELET_ROOT_DIR.
# Postconditions: Shared worker token generated for Linux and Windows join stages; optional local Linux worker join executed.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/common.sh
source "${SCRIPT_DIR}/scripts/lib/common.sh"
init_script "${BASH_SOURCE[0]}"
register_error_trap

TOKEN_OUT="${TOKEN_OUT:-./artifacts/k0s-worker-token}"
AUTO_JOIN_LOCAL_WORKER="${AUTO_JOIN_LOCAL_WORKER:-true}"
WORKER_DATA_DIR="${WORKER_DATA_DIR:-/var/lib/k0s-worker}"
KUBELET_ROOT_DIR="${KUBELET_ROOT_DIR:-/var/lib/kubelet-worker}"

require_privileged_access

log "Checking API availability"
k0s_kubectl get --raw=/healthz >/dev/null 2>&1 \
  || fail "API server not reachable. Run 02-cluster.sh first."

log "Creating worker token output directory"
mkdir -p "$(dirname -- "${TOKEN_OUT}")"

log "Generating worker token"
as_root rm -f "${TOKEN_OUT}"
as_root k0s token create --role=worker | as_root tee "${TOKEN_OUT}" >/dev/null
as_root chmod 600 "${TOKEN_OUT}"

log "Token written to: ${TOKEN_OUT}"
if [[ "${AUTO_JOIN_LOCAL_WORKER}" == "true" ]]; then
  log "AUTO_JOIN_LOCAL_WORKER=true (default); running local same-VM worker join"
  WORKER_TOKEN_FILE="${TOKEN_OUT}" \
  WORKER_DATA_DIR="${WORKER_DATA_DIR}" \
  KUBELET_ROOT_DIR="${KUBELET_ROOT_DIR}" \
  ALLOW_SAME_HOST_WORKER="true" \
  CLEAN_WORKER_STATE="true" \
  bash "${SCRIPT_DIR}/05-linux-node.sh"
  summary "./08-access-artifacts.sh"
  exit 0
fi

log "AUTO_JOIN_LOCAL_WORKER=false (opt-out); run ./05-linux-node.sh on a separate Linux worker node or ./06-windows-node.ps1 on a Windows worker node using token: ${TOKEN_OUT}"
summary "./05-linux-node.sh"
