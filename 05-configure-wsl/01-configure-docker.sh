#!/usr/bin/env bash
set -euo pipefail

# Purpose: Install the Docker CLI (if absent) and configure a Docker context in WSL
#          pointing to the Docker engine on the VM.
# Preconditions: Ubuntu-like WSL distro with apt; VM reachable at hostname "kubernetes"
#                via SSH with key-based (passwordless) auth; Docker daemon running on the VM.
# Invariants: Does not modify Docker daemon configuration on the VM.
# Idempotency: Safe to rerun; existing context is removed and recreated.
# Postconditions: Docker CLI installed, context "kubernetes" created and set as active.

CONTEXT_NAME="kubernetes"
VM_HOST="kubernetes"
VM_USER="${SUDO_USER:-${USER}}"
DOCKER_HOST="ssh://${VM_USER}@${VM_HOST}"
SSH_OPTS=(-o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new -l "${VM_USER}")

# When invoked via sudo, run ssh as the original user so their ~/.ssh and agent are available.
ssh_as_user() {
  if [[ -n "${SUDO_USER:-}" ]]; then
    sudo -u "${VM_USER}" ssh "${SSH_OPTS[@]}" "$@"
  else
    ssh "${SSH_OPTS[@]}" "$@"
  fi
}

log()  { printf '\n[%s] [INFO]  %s\n' "$(date +%H:%M:%S)" "$*"; }
fail() { printf '\n[%s] [ERROR] %s\n' "$(date +%H:%M:%S)" "$*" >&2; exit 1; }

# ------------------------------------------------------------------------------
# Install Docker CLI if absent
# ------------------------------------------------------------------------------

if ! command -v docker >/dev/null 2>&1; then
  log "Docker CLI not found — installing via official Docker apt repository"

  command -v curl >/dev/null 2>&1 || sudo apt-get install -y curl

  # Add Docker's official GPG key and repository (idempotent)
  sudo apt-get update -y
  sudo apt-get install -y ca-certificates gnupg

  sudo install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
    | sudo gpg --dearmor --yes -o /etc/apt/keyrings/docker.gpg
  sudo chmod a+r /etc/apt/keyrings/docker.gpg

  echo \
    "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/ubuntu \
$(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}") stable" \
    | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null

  sudo apt-get update -y
  # Install the CLI only — no daemon needed in WSL
  sudo apt-get install -y docker-ce-cli docker-buildx-plugin docker-compose-plugin
  log "Docker CLI installed: $(docker --version)"
else
  log "Docker CLI already present: $(docker --version)"
fi

# ------------------------------------------------------------------------------
# Pre-flight
# ------------------------------------------------------------------------------

log "Checking SSH connectivity to '${VM_USER}@${VM_HOST}'"
ssh_as_user "${VM_HOST}" true \
  || fail "Cannot reach '${VM_USER}@${VM_HOST}' via SSH. Ensure the VM is running and SSH key auth is configured."

# ------------------------------------------------------------------------------
# Create context
# ------------------------------------------------------------------------------

log "Removing existing Docker context '${CONTEXT_NAME}' if present"
docker context rm "${CONTEXT_NAME}" 2>/dev/null || true

log "Creating Docker context '${CONTEXT_NAME}' -> ${DOCKER_HOST}"
docker context create "${CONTEXT_NAME}" \
  --description "Docker engine on the kubernetes VM (via SSH)" \
  --docker "host=${DOCKER_HOST}"

# ------------------------------------------------------------------------------
# Activate context
# ------------------------------------------------------------------------------

log "Setting '${CONTEXT_NAME}' as active Docker context"
docker context use "${CONTEXT_NAME}"

# ------------------------------------------------------------------------------
# Verify
# ------------------------------------------------------------------------------

log "Verifying Docker connectivity"
docker info --format 'Server version: {{.ServerVersion}}' \
  || fail "Docker connectivity check failed — review VM Docker daemon and SSH config"

log "Done. Docker context '${CONTEXT_NAME}' is active and verified."
