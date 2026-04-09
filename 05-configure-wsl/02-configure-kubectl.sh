#!/usr/bin/env bash
set -euo pipefail

# Purpose: Install kubectl (if absent) and configure it in WSL by fetching
#          kubeconfig artifacts from the controller VM over SSH.
# Preconditions: Ubuntu-like WSL distro with apt; VM reachable via SSH and
#                01-build-cluster/08-access-artifacts.sh already executed on VM.
# Invariants: Artifact-driven only. Does not patch/rebuild kubeconfig from VM runtime assumptions.
# Idempotency: Safe to rerun; context is reconciled each run.
# Postconditions: kubectl installed and context "kubernetes" activated from fetched artifacts.

CONTEXT_NAME="kubernetes"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
LOCAL_USER="${SUDO_USER:-${USER}}"
VM_HOST="${VM_HOST:-kubernetes}"
VM_USER="${VM_USER:-${LOCAL_USER}}"
VM_SUDO_PASSWORD="${VM_SUDO_PASSWORD:-}"
REMOTE_ARTIFACT_DIR="${REMOTE_ARTIFACT_DIR:-/home/${VM_USER}/repos/local-k8s-linux-windows/01-build-cluster/artifacts}"
REMOTE_KUBECONFIG_ARTIFACT="${REMOTE_KUBECONFIG_ARTIFACT:-${REMOTE_ARTIFACT_DIR}/kubeconfig-controller-ip.yaml}"
REMOTE_WSL_ENV_ARTIFACT="${REMOTE_WSL_ENV_ARTIFACT:-${REMOTE_ARTIFACT_DIR}/wsl.env}"
SSH_OPTS=(-o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new -l "${VM_USER}")

LOCAL_KUBECONFIG="${HOME}/.kube/config"
TMP_KUBECONFIG="$(mktemp)"
TMP_WSL_ENV="$(mktemp)"

# When invoked via sudo, run commands as the original user so their ~/.ssh, agent,
# and KUBECONFIG/home directory are used rather than root's.
as_user() {
  if [[ -n "${SUDO_USER:-}" ]]; then
    sudo -u "${LOCAL_USER}" "$@"
  else
    "$@"
  fi
}

log()  { printf '\n[%s] [INFO]  %s\n' "$(date +%H:%M:%S)" "$*"; }
fail() { printf '\n[%s] [ERROR] %s\n' "$(date +%H:%M:%S)" "$*" >&2; exit 1; }

run_root() {
  if [[ "$(id -u)" -eq 0 ]]; then
    "$@"
  else
    sudo "$@"
  fi
}

fetch_remote_file() {
  local remote_path="$1"
  local local_path="$2"

  if as_user ssh "${SSH_OPTS[@]}" "${VM_HOST}" "cat '${remote_path}'" > "${local_path}" 2>/dev/null; then
    return 0
  fi

  if as_user ssh "${SSH_OPTS[@]}" "${VM_HOST}" "sudo -n cat '${remote_path}'" > "${local_path}" 2>/dev/null; then
    return 0
  fi

  if [[ -n "${VM_SUDO_PASSWORD}" ]]; then
    if as_user ssh "${SSH_OPTS[@]}" "${VM_HOST}" "sudo -S -p '' cat '${remote_path}'" \
      <<<"${VM_SUDO_PASSWORD}" > "${local_path}" 2>/dev/null; then
      return 0
    fi
  fi

  return 1
}

cleanup() {
  rm -f "${TMP_KUBECONFIG}" "${TMP_WSL_ENV}"
}
trap cleanup EXIT

log "Checking SSH connectivity to '${VM_USER}@${VM_HOST}'"
as_user ssh "${SSH_OPTS[@]}" "${VM_HOST}" true \
  || fail "Cannot reach '${VM_USER}@${VM_HOST}' via SSH. Ensure the VM is running and SSH key auth is configured."

log "Fetching kubeconfig artifact over SSH: ${REMOTE_KUBECONFIG_ARTIFACT}"
fetch_remote_file "${REMOTE_KUBECONFIG_ARTIFACT}" "${TMP_KUBECONFIG}" \
  || fail "Failed to read '${REMOTE_KUBECONFIG_ARTIFACT}' from VM. Run ./01-build-cluster/08-access-artifacts.sh on the VM first."

if [[ "$(id -u)" -eq 0 ]]; then
  chown "${LOCAL_USER}:${LOCAL_USER}" "${TMP_KUBECONFIG}" 2>/dev/null || true
fi
chmod 600 "${TMP_KUBECONFIG}"

if as_user ssh "${SSH_OPTS[@]}" "${VM_HOST}" "test -f '${REMOTE_WSL_ENV_ARTIFACT}'"; then
  log "Fetching optional WSL env artifact over SSH: ${REMOTE_WSL_ENV_ARTIFACT}"
  fetch_remote_file "${REMOTE_WSL_ENV_ARTIFACT}" "${TMP_WSL_ENV}" || true
  chmod 600 "${TMP_WSL_ENV}" || true
fi

if [[ -s "${TMP_WSL_ENV}" ]]; then
  # shellcheck disable=SC1090
  source "${TMP_WSL_ENV}"
  CONTEXT_NAME="${DOCKER_CONTEXT_NAME:-${CONTEXT_NAME}}"
fi

# ------------------------------------------------------------------------------
# Install kubectl if absent
# ------------------------------------------------------------------------------

if ! command -v kubectl >/dev/null 2>&1; then
  log "kubectl not found — installing via official Kubernetes apt repository"

  command -v curl >/dev/null 2>&1 || run_root apt-get install -y curl

  run_root apt-get update -y
  run_root apt-get install -y apt-transport-https ca-certificates gnupg

  run_root install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.32/deb/Release.key \
    | run_root gpg --dearmor --yes -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
  run_root chmod a+r /etc/apt/keyrings/kubernetes-apt-keyring.gpg

  echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] \
https://pkgs.k8s.io/core:/stable:/v1.32/deb/ /" \
    | run_root tee /etc/apt/sources.list.d/kubernetes.list >/dev/null

  run_root apt-get update -y
  run_root apt-get install -y kubectl
  log "kubectl installed: $(as_user kubectl version --client --short 2>/dev/null || as_user kubectl version --client)"
else
  log "kubectl already present: $(as_user kubectl version --client --short 2>/dev/null || as_user kubectl version --client)"
fi

# ------------------------------------------------------------------------------
# Stage artifact read
# ------------------------------------------------------------------------------

chmod 600 "${TMP_KUBECONFIG}"

# ------------------------------------------------------------------------------
# Merge into local kubeconfig
# ------------------------------------------------------------------------------

USER_HOME="$(eval echo "~${LOCAL_USER}")"
LOCAL_KUBECONFIG="${USER_HOME}/.kube/config"

log "Ensuring ${LOCAL_KUBECONFIG} exists"
run_root mkdir -p "$(dirname "${LOCAL_KUBECONFIG}")"
run_root chown "${LOCAL_USER}:${LOCAL_USER}" "$(dirname "${LOCAL_KUBECONFIG}")"
if [[ -f "${LOCAL_KUBECONFIG}" ]]; then
  run_root chown "${LOCAL_USER}:${LOCAL_USER}" "${LOCAL_KUBECONFIG}"
fi
as_user touch "${LOCAL_KUBECONFIG}"
as_user chmod 600 "${LOCAL_KUBECONFIG}"

log "Merging into ${LOCAL_KUBECONFIG}"
MERGED="$(as_user mktemp)"
as_user bash -lc "KUBECONFIG='${LOCAL_KUBECONFIG}:${TMP_KUBECONFIG}' kubectl config view --flatten --merge > '${MERGED}'"
as_user mv "${MERGED}" "${LOCAL_KUBECONFIG}"
as_user chmod 600 "${LOCAL_KUBECONFIG}"

# ------------------------------------------------------------------------------
# Rename context to a friendly name and activate it
# ------------------------------------------------------------------------------

# The source context name from k0s admin.conf is typically "k0s-admin@k0s" or "admin@k0s";
# rename whatever was imported to CONTEXT_NAME.
IMPORTED_CONTEXT="$(as_user kubectl --kubeconfig="${TMP_KUBECONFIG}" config current-context)"

if [[ "${IMPORTED_CONTEXT}" != "${CONTEXT_NAME}" ]]; then
  log "Renaming context '${IMPORTED_CONTEXT}' -> '${CONTEXT_NAME}'"
  as_user kubectl --kubeconfig="${LOCAL_KUBECONFIG}" config rename-context \
    "${IMPORTED_CONTEXT}" "${CONTEXT_NAME}" 2>/dev/null || true
fi

log "Setting '${CONTEXT_NAME}' as current context"
as_user kubectl --kubeconfig="${LOCAL_KUBECONFIG}" config use-context "${CONTEXT_NAME}"

# ------------------------------------------------------------------------------
# Verify
# ------------------------------------------------------------------------------

log "Verifying API connectivity"
as_user kubectl --kubeconfig="${LOCAL_KUBECONFIG}" cluster-info \
  || fail "kubectl cluster-info failed — check API server reachability and TLS trust."

log "Listing nodes"
as_user kubectl --kubeconfig="${LOCAL_KUBECONFIG}" get nodes -o wide

log "Done. kubectl context '${CONTEXT_NAME}' is active and verified."
