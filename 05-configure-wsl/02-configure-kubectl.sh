#!/usr/bin/env bash
set -euo pipefail

# Purpose: Install kubectl (if absent) and configure it in WSL to talk to the
#          Kubernetes API on the VM.
# Preconditions: Ubuntu-like WSL distro with apt; VM reachable at hostname "kubernetes"
#                via SSH with key-based (passwordless) auth; k0s control plane running.
# Invariants: Does not modify the cluster or its PKI.
# Idempotency: Safe to rerun; kubeconfig context is overwritten on each run.
# Postconditions: kubectl installed, context "kubernetes" created, server patched to
#                 https://kubernetes:6443, and set as the current context.

CONTEXT_NAME="kubernetes"
VM_HOST="kubernetes"
VM_USER="${SUDO_USER:-${USER}}"
API_SERVER="https://${VM_HOST}:6443"
REMOTE_KUBECONFIG="/var/lib/k0s/pki/admin.conf"
LOCAL_KUBECONFIG="${HOME}/.kube/config"
TMP_KUBECONFIG="$(mktemp)"
SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new -l "${VM_USER}")

log()  { printf '\n[%s] [INFO]  %s\n' "$(date +%H:%M:%S)" "$*"; }
fail() { printf '\n[%s] [ERROR] %s\n' "$(date +%H:%M:%S)" "$*" >&2; rm -f "${TMP_KUBECONFIG}"; exit 1; }

cleanup() { rm -f "${TMP_KUBECONFIG}"; }
trap cleanup EXIT

# ------------------------------------------------------------------------------
# Install kubectl if absent
# ------------------------------------------------------------------------------

if ! command -v kubectl >/dev/null 2>&1; then
  log "kubectl not found — installing via official Kubernetes apt repository"

  command -v curl >/dev/null 2>&1 || sudo apt-get install -y curl

  sudo apt-get update -y
  sudo apt-get install -y apt-transport-https ca-certificates gnupg

  sudo install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.32/deb/Release.key \
    | sudo gpg --dearmor --yes -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
  sudo chmod a+r /etc/apt/keyrings/kubernetes-apt-keyring.gpg

  echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] \
https://pkgs.k8s.io/core:/stable:/v1.32/deb/ /" \
    | sudo tee /etc/apt/sources.list.d/kubernetes.list >/dev/null

  sudo apt-get update -y
  sudo apt-get install -y kubectl
  log "kubectl installed: $(kubectl version --client --short 2>/dev/null || kubectl version --client)"
else
  log "kubectl already present: $(kubectl version --client --short 2>/dev/null || kubectl version --client)"
fi

# ------------------------------------------------------------------------------
# Pre-flight
# ------------------------------------------------------------------------------

log "Checking SSH connectivity to '${VM_USER}@${VM_HOST}'"
ssh "${SSH_OPTS[@]}" "${VM_HOST}" true \
  || fail "Cannot reach '${VM_USER}@${VM_HOST}' via SSH. Ensure the VM is running and SSH key auth is configured."

# ------------------------------------------------------------------------------
# Fetch kubeconfig from VM
# ------------------------------------------------------------------------------

log "Fetching admin kubeconfig from ${VM_HOST}:${REMOTE_KUBECONFIG}"
ssh "${SSH_OPTS[@]}" "${VM_HOST}" "sudo cat ${REMOTE_KUBECONFIG}" > "${TMP_KUBECONFIG}" \
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
