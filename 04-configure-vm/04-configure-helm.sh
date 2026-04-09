#!/usr/bin/env bash
set -euo pipefail

# Purpose: Install Helm on the VM (if absent) and ensure cluster context usability.
# Preconditions: Ubuntu-like VM with apt and sudo/root privileges.
# Invariants: Uses existing kubeconfig context; does not mutate cluster state.
# Idempotency: Safe to rerun; helm installation and basic checks are repeatable.
# Postconditions: helm installed and able to target current kubectl context.

CONTEXT_NAME="${HELM_CONTEXT_NAME:-kubernetes}"
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

if ! command -v helm >/dev/null 2>&1; then
  log "helm not found — installing from official release tarball"

  as_root apt-get update -y
  as_root apt-get install -y curl tar

  TMP_DIR="$(mktemp -d)"
  cleanup() { rm -rf "${TMP_DIR}"; }
  trap cleanup EXIT

  ARCH="$(dpkg --print-architecture)"
  case "${ARCH}" in
    amd64) HELM_ARCH="amd64" ;;
    arm64) HELM_ARCH="arm64" ;;
    *) fail "Unsupported architecture for helm install: ${ARCH}" ;;
  esac

  HELM_VERSION="${HELM_VERSION:-v3.16.2}"
  HELM_TGZ="helm-${HELM_VERSION}-linux-${HELM_ARCH}.tar.gz"

  curl -fsSL "https://get.helm.sh/${HELM_TGZ}" -o "${TMP_DIR}/${HELM_TGZ}"
  tar -xzf "${TMP_DIR}/${HELM_TGZ}" -C "${TMP_DIR}"
  as_root install -m 0755 "${TMP_DIR}/linux-${HELM_ARCH}/helm" /usr/local/bin/helm
  log "helm installed: $(helm version --short)"
else
  log "helm already present: $(helm version --short 2>/dev/null || helm version)"
fi

if ! command -v kubectl >/dev/null 2>&1; then
  warn "kubectl not found in PATH; run ./03-configure-kubectl.sh first"
  log "Done. helm is installed."
  exit 0
fi

CURRENT_CONTEXT="$(as_user kubectl config current-context 2>/dev/null || true)"
if [[ -z "${CURRENT_CONTEXT}" ]]; then
  warn "No active kubectl context found; run ./03-configure-kubectl.sh first"
  log "Done. helm is installed."
  exit 0
fi

if [[ "${CURRENT_CONTEXT}" != "${CONTEXT_NAME}" ]]; then
  warn "Active kubectl context is '${CURRENT_CONTEXT}' (expected '${CONTEXT_NAME}')"
fi

if ! as_user helm list -A >/dev/null 2>&1; then
  warn "helm is installed, but cluster connectivity is not currently available"
else
  log "helm cluster connectivity verified"
fi

log "Done. helm is installed and ready."

