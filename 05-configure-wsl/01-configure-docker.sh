#!/usr/bin/env bash
set -euo pipefail

# Purpose: Configure a Docker context in WSL pointing to the Docker engine on the VM.
# Preconditions: Docker CLI installed in WSL; VM reachable at hostname "kubernetes" via SSH
#                with key-based (passwordless) auth; Docker daemon running on the VM.
# Invariants: Does not modify Docker daemon configuration on the VM.
# Idempotency: Safe to rerun; existing context is removed and recreated.
# Postconditions: Docker context "kubernetes" created and set as the active context.

CONTEXT_NAME="kubernetes"
VM_HOST="kubernetes"
DOCKER_HOST="ssh://${VM_HOST}"

log()  { printf '\n[%s] [INFO]  %s\n' "$(date +%H:%M:%S)" "$*"; }
fail() { printf '\n[%s] [ERROR] %s\n' "$(date +%H:%M:%S)" "$*" >&2; exit 1; }

# ------------------------------------------------------------------------------
# Pre-flight
# ------------------------------------------------------------------------------

log "Checking Docker CLI"
command -v docker >/dev/null 2>&1 || fail "docker CLI not found in PATH"

log "Checking SSH connectivity to '${VM_HOST}'"
ssh -o BatchMode=yes -o ConnectTimeout=10 "${VM_HOST}" true \
  || fail "Cannot reach '${VM_HOST}' via SSH. Ensure the VM is running and SSH key auth is configured."

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
