#!/usr/bin/env bash
set -euo pipefail

# Purpose: Install kubectl on the VM (if absent) and configure local kubeconfig.
# Preconditions: Ubuntu-like VM with apt and sudo/root privileges.
# Invariants: Reads kubeconfig artifact when available; falls back to local admin.conf.
# Idempotency: Safe to rerun; merged kubeconfig/context is reconciled.
# Postconditions: kubectl installed and context "kubernetes" activated.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ARTIFACT_DIR="${ARTIFACT_DIR:-${SCRIPT_DIR}/../01-build-cluster/artifacts}"
KUBECONFIG_ARTIFACT="${KUBECONFIG_ARTIFACT:-${ARTIFACT_DIR}/kubeconfig-controller-ip.yaml}"
FALLBACK_ADMIN_KUBECONFIG="${FALLBACK_ADMIN_KUBECONFIG:-/var/lib/k0s/pki/admin.conf}"
CONTEXT_NAME="${KUBECTL_CONTEXT_NAME:-kubernetes}"

VM_USER="${SUDO_USER:-${USER}}"

log()  { printf '\n[%s] [INFO]  %s\n' "$(date +%H:%M:%S)" "$*"; }
warn() { printf '\n[%s] [WARN]  %s\n' "$(date +%H:%M:%S)" "$*"; }
fail() { printf '\n[%s] [ERROR] %s\n' "$(date +%H:%M:%S)" "$*" >&2; exit 1; }

as_root() {
  if [[ "${EUID}" -eq 0 ]]; then
    "$@"
  else
    sudo "$@"
  fi
}

as_user() {
  if [[ -n "${SUDO_USER:-}" ]]; then
    sudo -u "${VM_USER}" "$@"
  else
    "$@"
  fi
}

if ! command -v kubectl >/dev/null 2>&1; then
  log "kubectl not found — installing via official Kubernetes apt repository"

  as_root apt-get update -y
  as_root apt-get install -y apt-transport-https ca-certificates curl gnupg

  as_root install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.32/deb/Release.key \
    | as_root gpg --dearmor --yes -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
  as_root chmod a+r /etc/apt/keyrings/kubernetes-apt-keyring.gpg

  echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.32/deb/ /" \
    | as_root tee /etc/apt/sources.list.d/kubernetes.list >/dev/null

  as_root apt-get update -y
  as_root apt-get install -y kubectl
  log "kubectl installed"
else
  log "kubectl already present"
fi

TMP_KUBECONFIG="$(mktemp)"
MERGED=""
cleanup() { rm -f "${TMP_KUBECONFIG}" "${MERGED}"; }
trap cleanup EXIT

if [[ -f "${KUBECONFIG_ARTIFACT}" ]]; then
  log "Using kubeconfig artifact: ${KUBECONFIG_ARTIFACT}"
  cp "${KUBECONFIG_ARTIFACT}" "${TMP_KUBECONFIG}"
elif [[ -f "${FALLBACK_ADMIN_KUBECONFIG}" ]]; then
  log "Artifact missing; using fallback admin kubeconfig: ${FALLBACK_ADMIN_KUBECONFIG}"
  as_root cp "${FALLBACK_ADMIN_KUBECONFIG}" "${TMP_KUBECONFIG}"
  as_root chown "$(id -u)":"$(id -g)" "${TMP_KUBECONFIG}"
else
  fail "No kubeconfig source found. Missing '${KUBECONFIG_ARTIFACT}' and '${FALLBACK_ADMIN_KUBECONFIG}'"
fi

chmod 600 "${TMP_KUBECONFIG}"
if [[ -n "${SUDO_USER:-}" ]]; then
  as_root chown "${VM_USER}":"${VM_USER}" "${TMP_KUBECONFIG}"
fi

USER_HOME="$(eval echo "~${VM_USER}")"
LOCAL_KUBECONFIG="${USER_HOME}/.kube/config"
MERGED="${USER_HOME}/.kube/config.merged.$$"

log "Ensuring local kubeconfig at ${LOCAL_KUBECONFIG}"
as_user mkdir -p "${USER_HOME}/.kube"
if [[ -n "${SUDO_USER:-}" ]]; then
  as_root chown "${VM_USER}":"${VM_USER}" "${USER_HOME}/.kube"
fi
as_user chmod 700 "${USER_HOME}/.kube"
as_user touch "${LOCAL_KUBECONFIG}"
as_user chmod 600 "${LOCAL_KUBECONFIG}"

log "Merging imported kubeconfig"
as_user bash -lc "KUBECONFIG='${LOCAL_KUBECONFIG}:${TMP_KUBECONFIG}' kubectl config view --flatten > '${MERGED}'"
as_user mv "${MERGED}" "${LOCAL_KUBECONFIG}"
as_user chmod 600 "${LOCAL_KUBECONFIG}"

IMPORTED_CONTEXT="$(as_user kubectl --kubeconfig="${TMP_KUBECONFIG}" config current-context)"
if [[ -n "${IMPORTED_CONTEXT}" && "${IMPORTED_CONTEXT}" != "${CONTEXT_NAME}" ]]; then
  log "Renaming context '${IMPORTED_CONTEXT}' -> '${CONTEXT_NAME}'"
  as_user kubectl --kubeconfig="${LOCAL_KUBECONFIG}" config rename-context "${IMPORTED_CONTEXT}" "${CONTEXT_NAME}" 2>/dev/null || true
fi

log "Activating context '${CONTEXT_NAME}'"
as_user kubectl --kubeconfig="${LOCAL_KUBECONFIG}" config use-context "${CONTEXT_NAME}"

if ! as_user kubectl --kubeconfig="${LOCAL_KUBECONFIG}" cluster-info >/dev/null 2>&1; then
  warn "kubectl is installed and configured, but API connectivity is not currently available"
else
  log "kubectl API connectivity verified"
fi

log "Done. kubectl is configured with context '${CONTEXT_NAME}'."

