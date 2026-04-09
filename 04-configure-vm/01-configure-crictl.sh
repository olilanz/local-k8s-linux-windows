#!/usr/bin/env bash
set -euo pipefail

# Purpose: Install crictl (if absent) and configure containerd endpoints on the VM.
# Preconditions: Ubuntu-like VM with curl/tar and sudo/root privileges.
# Invariants: Targets host containerd runtime used by k0s; no Docker daemon dependency.
# Idempotency: Safe to rerun; binary and config are reconciled.
# Postconditions: crictl available and configured via /etc/crictl.yaml.

CRICTL_VERSION="${CRICTL_VERSION:-v1.32.0}"
CRICTL_CONFIG_PATH="${CRICTL_CONFIG_PATH:-/etc/crictl.yaml}"
RUNTIME_ENDPOINT="${RUNTIME_ENDPOINT:-unix:///run/containerd/containerd.sock}"
IMAGE_ENDPOINT="${IMAGE_ENDPOINT:-unix:///run/containerd/containerd.sock}"

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
  amd64) CRICTL_ARCH="amd64" ;;
  arm64) CRICTL_ARCH="arm64" ;;
  *) fail "Unsupported architecture for crictl: ${ARCH}" ;;
esac

if ! command -v crictl >/dev/null 2>&1; then
  log "Installing crictl ${CRICTL_VERSION}"
  as_root apt-get update -y
  as_root apt-get install -y curl tar

  TMP_DIR="$(mktemp -d)"
  cleanup() { rm -rf "${TMP_DIR}"; }
  trap cleanup EXIT

  CRICTL_TGZ="crictl-${CRICTL_VERSION}-linux-${CRICTL_ARCH}.tar.gz"
  curl -fsSL "https://github.com/kubernetes-sigs/cri-tools/releases/download/${CRICTL_VERSION}/${CRICTL_TGZ}" -o "${TMP_DIR}/${CRICTL_TGZ}"
  tar -xzf "${TMP_DIR}/${CRICTL_TGZ}" -C "${TMP_DIR}"
  as_root install -m 0755 "${TMP_DIR}/crictl" /usr/local/bin/crictl
  log "crictl installed: $(crictl --version)"
else
  log "crictl already present: $(crictl --version)"
fi

log "Writing ${CRICTL_CONFIG_PATH}"
as_root tee "${CRICTL_CONFIG_PATH}" >/dev/null <<EOF
runtime-endpoint: ${RUNTIME_ENDPOINT}
image-endpoint: ${IMAGE_ENDPOINT}
timeout: 10
debug: false
EOF
as_root chmod 644 "${CRICTL_CONFIG_PATH}"

log "Verifying crictl against containerd endpoint"
as_root crictl info >/dev/null

log "Done. crictl is installed and configured."

