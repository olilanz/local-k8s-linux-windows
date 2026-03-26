#!/usr/bin/env bash
set -euo pipefail

# Purpose: Join Linux worker service context to an existing controller.
# Preconditions: Worker token available; may run on same host as controller if using isolated worker data dirs.
# Invariants: Keeps worker state in dedicated paths to avoid controller/worker collisions.
# Inputs: WORKER_TOKEN_FILE, WORKER_DATA_DIR, KUBELET_ROOT_DIR, CLEAN_WORKER_STATE, CONTROLLER_KUBECONFIG (optional), ALLOW_SAME_HOST_WORKER.
# Idempotency: Safe to rerun; worker service/state reconciled in worker-specific context.
# Postconditions: k0sworker active; optional Ready verification if kubeconfig available.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/common.sh
source "${SCRIPT_DIR}/scripts/lib/common.sh"
init_script "${BASH_SOURCE[0]}"
register_error_trap

NODE_NAME="$(hostname -s)"
WORKER_TOKEN_FILE="${WORKER_TOKEN_FILE:-./artifacts/k0s-worker-token}"
WORKER_DATA_DIR="${WORKER_DATA_DIR:-/var/lib/k0s-worker}"
KUBELET_ROOT_DIR="${KUBELET_ROOT_DIR:-/var/lib/kubelet-worker}"
CLEAN_WORKER_STATE="${CLEAN_WORKER_STATE:-false}"
CONTROLLER_KUBECONFIG="${CONTROLLER_KUBECONFIG:-/home/ocl/.kube/config}"
ALLOW_SAME_HOST_WORKER="${ALLOW_SAME_HOST_WORKER:-false}"

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

if as_root systemctl is-active --quiet k0scontroller; then
  if [[ "${ALLOW_SAME_HOST_WORKER}" != "true" ]]; then
    fail "k0scontroller is active on this host. Same-VM worker join requires explicit opt-in. Re-run with ALLOW_SAME_HOST_WORKER=true (recommended with CLEAN_WORKER_STATE=true), or run 05-linux-node.sh on a separate Linux worker node."
  fi
  warn "ALLOW_SAME_HOST_WORKER=true with local k0scontroller detected; proceeding in same-VM dual-service mode with isolated worker dirs"
fi

if [[ ! -f "${WORKER_TOKEN_FILE}" ]]; then
  fail "Worker token file not found: ${WORKER_TOKEN_FILE}. Run ./04-controller-token.sh on the controller and copy token to this worker node."
fi

log "Reconciling worker service"
as_root systemctl stop k0sworker 2>/dev/null || true
as_root systemctl disable k0sworker 2>/dev/null || true
as_root rm -f /etc/systemd/system/k0sworker.service
as_root systemctl daemon-reload

if [[ "${CLEAN_WORKER_STATE}" == "true" ]]; then
  log "Cleaning worker local state"
  as_root rm -rf "${WORKER_DATA_DIR}" || true
  as_root rm -rf "${KUBELET_ROOT_DIR}" || true
  as_root rm -rf /etc/k0s/kubelet.conf || true
  as_root rm -rf /var/lib/k0s/kubelet/pki || true
  as_root rm -rf /var/lib/k0s/kubelet/kubeconfig || true
  as_root mkdir -p "${KUBELET_ROOT_DIR}"
else
  log "Skipping destructive worker-state cleanup (CLEAN_WORKER_STATE=${CLEAN_WORKER_STATE})"
fi

log "Installing worker service"
as_root k0s install worker \
  --token-file "${WORKER_TOKEN_FILE}" \
  --data-dir "${WORKER_DATA_DIR}" \
  --kubelet-root-dir "${KUBELET_ROOT_DIR}"

log "Starting worker service"
as_root systemctl enable --now k0sworker

log "Validating k0sworker active state"
for _ in {1..30}; do
  if as_root systemctl is-active --quiet k0sworker; then
    break
  fi
  sleep 2
done
as_root systemctl is-active --quiet k0sworker || fail "k0sworker did not become active"

if [[ -f "${CONTROLLER_KUBECONFIG}" ]]; then
  log "Controller kubeconfig detected; verifying node registration from worker"
  for _ in {1..120}; do
    if KUBECONFIG="${CONTROLLER_KUBECONFIG}" k0s kubectl get node "${NODE_NAME}" >/dev/null 2>&1; then
      break
    fi
    sleep 2
  done

  KUBECONFIG="${CONTROLLER_KUBECONFIG}" k0s kubectl get node "${NODE_NAME}" >/dev/null 2>&1 \
    || fail "Node object was not registered: ${NODE_NAME}"

  KUBECONFIG="${CONTROLLER_KUBECONFIG}" k0s kubectl get node "${NODE_NAME}" -o wide
else
  warn "Skipping cluster-side node verification; CONTROLLER_KUBECONFIG not found at ${CONTROLLER_KUBECONFIG}"
fi

summary "./10-nginx.sh"
