#!/usr/bin/env bash
set -euo pipefail

# Purpose: Configure kubectl in WSL to talk to the Kubernetes API on the VM.
# Preconditions: kubectl installed in WSL; VM reachable at hostname "kubernetes" via SSH
#                with key-based (passwordless) auth; k0s control plane running on the VM.
# Invariants: Does not modify the cluster or its PKI.
# Idempotency: Safe to rerun; kubeconfig context is overwritten on each run.
# Postconditions: kubectl context "kubernetes" created, server patched to
#                 https://kubernetes:6443, and set as the current context.

CONTEXT_NAME="kubernetes"
VM_HOST="kubernetes"
API_SERVER="https://${VM_HOST}:6443"
REMOTE_KUBECONFIG="/var/lib/k0s/pki/admin.conf"
LOCAL_KUBECONFIG="${HOME}/.kube/config"
TMP_KUBECONFIG="$(mktemp)"

log()  { printf '\n[%s] [INFO]  %s\n' "$(date +%H:%M:%S)" "$*"; }
fail() { printf '\n[%s] [ERROR] %s\n' "$(date +%H:%M:%S)" "$*" >&2; rm -f "${TMP_KUBECONFIG}"; exit 1; }

cleanup() { rm -f "${TMP_KUBECONFIG}"; }
trap cleanup EXIT

# ------------------------------------------------------------------------------
# Pre-flight
# ------------------------------------------------------------------------------

log "Checking kubectl"
command -v kubectl >/dev/null 2>&1 || fail "kubectl not found in PATH"

log "Checking SSH connectivity to '${VM_HOST}'"
ssh -o BatchMode=yes -o ConnectTimeout=10 "${VM_HOST}" true \
  || fail "Cannot reach '${VM_HOST}' via SSH. Ensure the VM is running and SSH key auth is configured."

# ------------------------------------------------------------------------------
# Fetch kubeconfig from VM
# ------------------------------------------------------------------------------

log "Fetching admin kubeconfig from ${VM_HOST}:${REMOTE_KUBECONFIG}"
ssh "${VM_HOST}" "sudo cat ${REMOTE_KUBECONFIG}" > "${TMP_KUBECONFIG}" \
  || fail "Failed to read ${REMOTE_KUBECONFIG} from VM. Ensure k0s controller is running."

chmod 600 "${TMP_KUBECONFIG}"

# ------------------------------------------------------------------------------
# Patch server URL to use the VM hostname
# ------------------------------------------------------------------------------

log "Patching server URL to ${API_SERVER}"
KUBECONFIG="${TMP_KUBECONFIG}" kubectl config set-cluster "$(
  KUBECONFIG="${TMP_KUBECONFIG}" kubectl config get-clusters --no-headers | awk '{print $1}'
)" --server="${API_SERVER}"

# ------------------------------------------------------------------------------
# Merge into local kubeconfig
# ------------------------------------------------------------------------------

log "Ensuring ${LOCAL_KUBECONFIG} exists"
mkdir -p "$(dirname "${LOCAL_KUBECONFIG}")"
touch "${LOCAL_KUBECONFIG}"
chmod 600 "${LOCAL_KUBECONFIG}"

log "Merging into ${LOCAL_KUBECONFIG}"
MERGED="$(mktemp)"
KUBECONFIG="${LOCAL_KUBECONFIG}:${TMP_KUBECONFIG}" kubectl config view --flatten > "${MERGED}"
mv "${MERGED}" "${LOCAL_KUBECONFIG}"
chmod 600 "${LOCAL_KUBECONFIG}"

# ------------------------------------------------------------------------------
# Rename context to a friendly name and activate it
# ------------------------------------------------------------------------------

# The source context name from k0s admin.conf is typically "k0s-admin@k0s" or "admin@k0s";
# rename whatever was imported to CONTEXT_NAME.
IMPORTED_CONTEXT="$(KUBECONFIG="${TMP_KUBECONFIG}" kubectl config current-context)"

if [[ "${IMPORTED_CONTEXT}" != "${CONTEXT_NAME}" ]]; then
  log "Renaming context '${IMPORTED_CONTEXT}' -> '${CONTEXT_NAME}'"
  kubectl config rename-context "${IMPORTED_CONTEXT}" "${CONTEXT_NAME}" 2>/dev/null || true
fi

log "Setting '${CONTEXT_NAME}' as current context"
kubectl config use-context "${CONTEXT_NAME}"

# ------------------------------------------------------------------------------
# Verify
# ------------------------------------------------------------------------------

log "Verifying API connectivity"
kubectl cluster-info \
  || fail "kubectl cluster-info failed — check API server reachability and TLS trust."

log "Listing nodes"
kubectl get nodes -o wide

log "Done. kubectl context '${CONTEXT_NAME}' is active and verified."
