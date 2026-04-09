#!/usr/bin/env bash
set -euo pipefail

# Purpose: Install Docker CLI (if absent) and configure Docker context in WSL
#          by fetching access artifacts from the controller VM over SSH.
# Preconditions: Ubuntu-like WSL distro with apt; VM reachable via SSH and
#                01-build-cluster/08-access-artifacts.sh already executed on VM.
# Invariants: Artifact-driven only. Does not install/modify Docker daemon on controller VM.
# Idempotency: Safe to rerun; context is reconciled each run.
# Postconditions: Docker CLI installed, context configured and active against artifact endpoint.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

CONTEXT_NAME="${DOCKER_CONTEXT_NAME:-kubernetes}"
LOCAL_USER="${SUDO_USER:-${USER}}"
VM_HOST="${VM_HOST:-kubernetes}"
VM_USER="${VM_USER:-${LOCAL_USER}}"
VM_SUDO_PASSWORD="${VM_SUDO_PASSWORD:-}"
REMOTE_ARTIFACT_DIR="${REMOTE_ARTIFACT_DIR:-/home/${VM_USER}/repos/local-k8s-linux-windows/01-build-cluster/artifacts}"
REMOTE_DOCKER_HOST_ARTIFACT="${REMOTE_DOCKER_HOST_ARTIFACT:-${REMOTE_ARTIFACT_DIR}/docker-host-uri}"
REMOTE_WSL_ENV_ARTIFACT="${REMOTE_WSL_ENV_ARTIFACT:-${REMOTE_ARTIFACT_DIR}/wsl.env}"
SSH_OPTS=(-o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new -l "${VM_USER}")

TMP_DOCKER_HOST="$(mktemp)"
TMP_WSL_ENV="$(mktemp)"

# When invoked via sudo, run commands as the original user so their ~/.ssh, agent,
# and DOCKER_CONFIG are available rather than root's.
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

parse_docker_ssh_host() {
  local uri="$1"
  local target="${uri#ssh://}"
  target="${target#*@}"
  target="${target%%/*}"
  target="${target%%:*}"
  printf '%s' "${target}"
}

ensure_known_host() {
  local host="$1"
  [[ -n "${host}" ]] || return 0

local ssh_dir
  ssh_dir="$(eval echo "~${LOCAL_USER}")/.ssh"
  as_user mkdir -p "${ssh_dir}"
  as_user chmod 700 "${ssh_dir}"
  as_user touch "${ssh_dir}/known_hosts"
  as_user chmod 600 "${ssh_dir}/known_hosts"

  if ! as_user ssh-keygen -F "${host}" -f "${ssh_dir}/known_hosts" >/dev/null 2>&1; then
    as_user ssh-keyscan -H "${host}" >> "${ssh_dir}/known_hosts" 2>/dev/null || true
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
  rm -f "${TMP_DOCKER_HOST}" "${TMP_WSL_ENV}"
}
trap cleanup EXIT

log "Checking SSH connectivity to '${VM_USER}@${VM_HOST}'"
as_user ssh "${SSH_OPTS[@]}" "${VM_HOST}" true \
  || fail "Cannot reach '${VM_USER}@${VM_HOST}' via SSH. Ensure the VM is running and SSH key auth is configured."

log "Fetching docker endpoint artifact over SSH: ${REMOTE_DOCKER_HOST_ARTIFACT}"
fetch_remote_file "${REMOTE_DOCKER_HOST_ARTIFACT}" "${TMP_DOCKER_HOST}" \
  || fail "Failed to read '${REMOTE_DOCKER_HOST_ARTIFACT}' from VM. Run ./01-build-cluster/08-access-artifacts.sh on the VM first."

if as_user ssh "${SSH_OPTS[@]}" "${VM_HOST}" "test -f '${REMOTE_WSL_ENV_ARTIFACT}'"; then
  log "Fetching optional WSL env artifact over SSH: ${REMOTE_WSL_ENV_ARTIFACT}"
  fetch_remote_file "${REMOTE_WSL_ENV_ARTIFACT}" "${TMP_WSL_ENV}" || true
fi

if [[ -s "${TMP_WSL_ENV}" ]]; then
  # shellcheck disable=SC1090
  source "${TMP_WSL_ENV}"
  CONTEXT_NAME="${DOCKER_CONTEXT_NAME:-${CONTEXT_NAME}}"
fi

DOCKER_HOST="$(<"${TMP_DOCKER_HOST}")"
[[ -n "${DOCKER_HOST}" ]] || fail "Artifact '${REMOTE_DOCKER_HOST_ARTIFACT}' is empty"
DOCKER_TARGET_HOST="$(parse_docker_ssh_host "${DOCKER_HOST}")"

log "Ensuring SSH known_hosts entries for '${VM_HOST}' and '${DOCKER_TARGET_HOST}'"
ensure_known_host "${VM_HOST}"
ensure_known_host "${DOCKER_TARGET_HOST}"

# ------------------------------------------------------------------------------
# Install Docker CLI if absent
# ------------------------------------------------------------------------------

if ! command -v docker >/dev/null 2>&1; then
  log "Docker CLI not found — installing via official Docker apt repository"

  command -v curl >/dev/null 2>&1 || run_root apt-get install -y curl

  # Add Docker's official GPG key and repository (idempotent)
  run_root apt-get update -y
  run_root apt-get install -y ca-certificates gnupg

  run_root install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
    | run_root gpg --dearmor --yes -o /etc/apt/keyrings/docker.gpg
  run_root chmod a+r /etc/apt/keyrings/docker.gpg

  echo \
    "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/ubuntu \
$(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}") stable" \
    | run_root tee /etc/apt/sources.list.d/docker.list >/dev/null

  run_root apt-get update -y
  # Install the CLI only — no daemon needed in WSL
  run_root apt-get install -y docker-ce-cli docker-buildx-plugin docker-compose-plugin
  log "Docker CLI installed: $(docker --version)"
else
  log "Docker CLI already present: $(docker --version)"
fi

# ------------------------------------------------------------------------------
# Create context
# ------------------------------------------------------------------------------

log "Removing existing Docker context '${CONTEXT_NAME}' if present"
as_user docker context use default >/dev/null 2>&1 || true
as_user docker context rm "${CONTEXT_NAME}" 2>/dev/null || true

log "Creating Docker context '${CONTEXT_NAME}' -> ${DOCKER_HOST}"
as_user docker context create "${CONTEXT_NAME}" \
  --description "Docker engine endpoint from cluster access artifacts" \
  --docker "host=${DOCKER_HOST}" \
  || as_user docker context update "${CONTEXT_NAME}" --description "Docker engine endpoint from cluster access artifacts" --docker "host=${DOCKER_HOST}"

# ------------------------------------------------------------------------------
# Activate context
# ------------------------------------------------------------------------------

log "Setting '${CONTEXT_NAME}' as active Docker context"
as_user docker context use "${CONTEXT_NAME}"

# ------------------------------------------------------------------------------
# Verify
# ------------------------------------------------------------------------------

log "Verifying Docker connectivity"
as_user docker info --format 'Server version: {{.ServerVersion}}' \
  || fail "Docker connectivity check failed — review controller reachability and artifact endpoint"

log "Done. Docker context '${CONTEXT_NAME}' is active and verified from artifacts."
