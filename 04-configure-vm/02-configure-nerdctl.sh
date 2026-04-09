#!/usr/bin/env bash
set -euo pipefail

# Purpose: Install nerdctl (if absent) and configure default containerd settings on the VM.
# Preconditions: Ubuntu-like VM with curl/tar and sudo/root privileges.
# Invariants: Targets host containerd runtime used by k0s; no Docker daemon dependency.
# Idempotency: Safe to rerun; binary and config are reconciled.
# Postconditions: nerdctl available and connected to containerd.

NERDCTL_VERSION="${NERDCTL_VERSION:-v2.0.0}"
NERDCTL_CONFIG_DIR="${NERDCTL_CONFIG_DIR:-/etc/nerdctl}"
CONTAINERD_ADDRESS="${CONTAINERD_ADDRESS:-/run/containerd/containerd.sock}"
DEFAULT_NAMESPACE="${DEFAULT_NAMESPACE:-k8s.io}"

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
  amd64) NERDCTL_ARCH="amd64" ;;
  arm64) NERDCTL_ARCH="arm64" ;;
  *) fail "Unsupported architecture for nerdctl: ${ARCH}" ;;
esac

if ! command -v nerdctl >/dev/null 2>&1; then
  log "Installing nerdctl ${NERDCTL_VERSION}"
  as_root apt-get update -y
  as_root apt-get install -y curl tar uidmap

  TMP_DIR="$(mktemp -d)"
  cleanup() { rm -rf "${TMP_DIR}"; }
  trap cleanup EXIT

  NERDCTL_TGZ="nerdctl-${NERDCTL_VERSION}-linux-${NERDCTL_ARCH}.tar.gz"
  curl -fsSL "https://github.com/containerd/nerdctl/releases/download/${NERDCTL_VERSION}/${NERDCTL_TGZ}" -o "${TMP_DIR}/${NERDCTL_TGZ}"
  tar -xzf "${TMP_DIR}/${NERDCTL_TGZ}" -C "${TMP_DIR}"
  as_root install -m 0755 "${TMP_DIR}/nerdctl" /usr/local/bin/nerdctl
  log "nerdctl installed: $(nerdctl --version)"
else
  log "nerdctl already present: $(nerdctl --version)"
fi

log "Writing ${NERDCTL_CONFIG_DIR}/nerdctl.toml"
as_root mkdir -p "${NERDCTL_CONFIG_DIR}"
as_root tee "${NERDCTL_CONFIG_DIR}/nerdctl.toml" >/dev/null <<EOF
address = "${CONTAINERD_ADDRESS}"
namespace = "${DEFAULT_NAMESPACE}"
EOF
as_root chmod 644 "${NERDCTL_CONFIG_DIR}/nerdctl.toml"

log "Verifying nerdctl"
nerdctl --version >/dev/null
as_root nerdctl -n "${DEFAULT_NAMESPACE}" --address "${CONTAINERD_ADDRESS}" images ls >/dev/null

log "Done. nerdctl is installed and configured."

