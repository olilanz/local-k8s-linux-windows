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
SSH_OPTS=(-o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new -l "${VM_USER}")

# When invoked via sudo, run commands as the original user so their ~/.ssh, agent,
# and KUBECONFIG/home directory are used rather than root's.
as_user() {
  if [[ -n "${SUDO_USER:-}" ]]; then
    sudo -u "${VM_USER}" "$@"
  else
    "$@"
  fi
}

log()  { printf '\n[%s] [INFO]  %s\n' "$(date +%H:%M:%S)" "$*"; }
fail() { printf '\n[%s] [ERROR] %s\n' "$(date +%H:%M:%S)" "$*" >&2; rm -f "${TMP_KUBECONFIG}"; exit 1; }

cleanup() { rm -f "${TMP_KUBECONFIG}"; }
trap cleanup EXIT

# ------------------------------------------------------------------------------
# Install kubectl if absent
# ------------------------------------------------------------------------------

if ! command -v kubectl >/dev/null 2>&1; then
  log "kubectl not found — installing via official Kubernetes apt repository"

  command -v curl >/dev/null 2>&1 || apt-get install -y curl

  apt-get update -y
  apt-get install -y apt-transport-https ca-certificates gnupg

  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.32/deb/Release.key \
    | gpg --dearmor --yes -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
  chmod a+r /etc/apt/keyrings/kubernetes-apt-keyring.gpg

  echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] \
https://pkgs.k8s.io/core:/stable:/v1.32/deb/ /" \
    | tee /etc/apt/sources.list.d/kubernetes.list >/dev/null

  apt-get update -y
  apt-get install -y kubectl
  log "kubectl installed: $(as_user kubectl version --client --short 2>/dev/null || as_user kubectl version --client)"
else
  log "kubectl already present: $(as_user kubectl version --client --short 2>/dev/null || as_user kubectl version --client)"
fi

# ------------------------------------------------------------------------------
# Pre-flight
# ------------------------------------------------------------------------------

log "Checking SSH connectivity to '${VM_USER}@${VM_HOST}'"
as_user ssh "${SSH_OPTS[@]}" "${VM_HOST}" true \
  || fail "Cannot reach '${VM_USER}@${VM_HOST}' via SSH. Ensure the VM is running and SSH key auth is configured."

# ------------------------------------------------------------------------------
# Fetch kubeconfig from VM
# ------------------------------------------------------------------------------

# 02-cluster.sh already copies admin.conf to ~/.kube/config on the VM for the local user,
# so we can read it without sudo.
log "Fetching kubeconfig from ${VM_HOST}:~/.kube/config"
as_user ssh "${SSH_OPTS[@]}" "${VM_HOST}" "cat ~/.kube/config" > "${TMP_KUBECONFIG}" \
  || fail "Failed to read ~/.kube/config from VM. Ensure k0s controller has run 02-cluster.sh."

chmod 600 "${TMP_KUBECONFIG}"

# ------------------------------------------------------------------------------
# Patch server URL to use the VM hostname
# ------------------------------------------------------------------------------

log "Patching server URL to ${API_SERVER}"
CLUSTER_NAME="$(as_user kubectl --kubeconfig="${TMP_KUBECONFIG}" config view \
  --output=jsonpath='{.clusters[0].name}')"
[[ -n "${CLUSTER_NAME}" ]] || fail "Could not determine cluster name from fetched kubeconfig"
log "Cluster name: ${CLUSTER_NAME}"
as_user kubectl --kubeconfig="${TMP_KUBECONFIG}" config set-cluster "${CLUSTER_NAME}" \
  --server="${API_SERVER}"

# ------------------------------------------------------------------------------
# Merge into local kubeconfig
# ------------------------------------------------------------------------------

USER_HOME="$(eval echo "~${VM_USER}")"
LOCAL_KUBECONFIG="${USER_HOME}/.kube/config"

log "Ensuring ${LOCAL_KUBECONFIG} exists"
as_user mkdir -p "$(dirname "${LOCAL_KUBECONFIG}")"
as_user touch "${LOCAL_KUBECONFIG}"
chmod 600 "${LOCAL_KUBECONFIG}"

log "Merging into ${LOCAL_KUBECONFIG}"
MERGED="$(mktemp)"
as_user kubectl --kubeconfig="${LOCAL_KUBECONFIG}" config view --flatten \
  --merge "${TMP_KUBECONFIG}" > "${MERGED}"
mv "${MERGED}" "${LOCAL_KUBECONFIG}"
chmod 600 "${LOCAL_KUBECONFIG}"

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
