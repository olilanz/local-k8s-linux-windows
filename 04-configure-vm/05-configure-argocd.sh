#!/usr/bin/env bash
set -euo pipefail

# Purpose: Install Argo CD CLI (argocd) on the VM and verify client usability.
# Preconditions: Ubuntu-like VM with curl and sudo/root privileges.
# Invariants: Installs CLI only; does not modify in-cluster Argo CD resources.
# Idempotency: Safe to rerun; binary is reconciled.
# Postconditions: argocd CLI available in PATH.

ARGOCD_VERSION="${ARGOCD_VERSION:-v2.12.3}"

log()  { printf '\n[%s] [INFO]  %s\n' "$(date +%H:%M:%S)" "$*"; }
fail() { printf '\n[%s] [ERROR] %s\n' "$(date +%H:%M:%S)" "$*" >&2; exit 1; }

as_root() {
  if [[ "${EUID}" -eq 0 ]]; then
    "$@"
  else
    sudo "$@"
  fi
}

ARCH="$(dpkg --print-architecture)"
case "${ARCH}" in
  amd64) ARGOCD_ARCH="amd64" ;;
  arm64) ARGOCD_ARCH="arm64" ;;
  *) fail "Unsupported architecture for argocd CLI: ${ARCH}" ;;
esac

if ! command -v argocd >/dev/null 2>&1; then
  log "Installing argocd CLI ${ARGOCD_VERSION}"
  as_root apt-get update -y
  as_root apt-get install -y curl ca-certificates

  TMP_FILE="$(mktemp)"
  cleanup() { rm -f "${TMP_FILE}"; }
  trap cleanup EXIT

  curl -fsSL "https://github.com/argoproj/argo-cd/releases/download/${ARGOCD_VERSION}/argocd-linux-${ARGOCD_ARCH}" -o "${TMP_FILE}"
  as_root install -m 0755 "${TMP_FILE}" /usr/local/bin/argocd
  log "argocd installed"
else
  log "argocd already present"
fi

argocd version --client >/dev/null
log "Done. argocd CLI is installed and verified."

