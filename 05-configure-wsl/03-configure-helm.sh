#!/usr/bin/env bash
set -euo pipefail

# Purpose: Install Helm (if absent) and validate it against the current kubectl context in WSL.
# Preconditions: Ubuntu-like WSL distro with apt; kubectl already configured (run 02-configure-kubectl.sh first).
# Invariants: Local CLI setup only; does not mutate cluster resources.
# Idempotency: Safe to rerun.
# Postconditions: helm command is installed and can access cluster metadata.

CONTEXT_NAME="${HELM_CONTEXT_NAME:-kubernetes}"
LOCAL_USER="${SUDO_USER:-${USER}}"
LOCAL_KUBECONFIG="$(eval echo "~${LOCAL_USER}")/.kube/config"

as_user() {
  if [[ -n "${SUDO_USER:-}" ]]; then
    sudo -u "${LOCAL_USER}" "$@"
  else
    "$@"
  fi
}

run_root() {
  if [[ "$(id -u)" -eq 0 ]]; then
    "$@"
  else
    sudo "$@"
  fi
}

log()  { printf '\n[%s] [INFO]  %s\n' "$(date +%H:%M:%S)" "$*"; }
fail() { printf '\n[%s] [ERROR] %s\n' "$(date +%H:%M:%S)" "$*" >&2; exit 1; }

# ------------------------------------------------------------------------------
# Pre-flight
# ------------------------------------------------------------------------------

command -v kubectl >/dev/null 2>&1 \
  || fail "kubectl is required before Helm setup. Run ./05-configure-wsl/02-configure-kubectl.sh first."

[[ -f "${LOCAL_KUBECONFIG}" ]] \
  || fail "Missing kubeconfig at ${LOCAL_KUBECONFIG}. Run ./05-configure-wsl/02-configure-kubectl.sh first."

# ------------------------------------------------------------------------------
# Install helm if absent
# ------------------------------------------------------------------------------

if ! command -v helm >/dev/null 2>&1; then
  log "Helm not found — installing via official Helm apt repository"

  command -v curl >/dev/null 2>&1 || run_root apt-get install -y curl
  run_root apt-get update -y
  run_root apt-get install -y apt-transport-https ca-certificates gnupg

  run_root install -m 0755 -d /etc/apt/keyrings
  curl --http1.1 -fsSL https://baltocdn.com/helm/signing.asc \
    | run_root gpg --dearmor --yes -o /etc/apt/keyrings/helm.gpg
  run_root chmod a+r /etc/apt/keyrings/helm.gpg

  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/helm.gpg] https://baltocdn.com/helm/stable/debian/ all main" \
    | run_root tee /etc/apt/sources.list.d/helm-stable-debian.list >/dev/null

  run_root apt-get update -y
  run_root apt-get install -y helm
  log "Helm installed: $(helm version --short 2>/dev/null || helm version)"
else
  log "Helm already present: $(helm version --short 2>/dev/null || helm version)"
fi

# ------------------------------------------------------------------------------
# Configure/verify context
# ------------------------------------------------------------------------------

if as_user kubectl --kubeconfig="${LOCAL_KUBECONFIG}" config get-contexts -o name | grep -qx "${CONTEXT_NAME}"; then
  log "Setting kubectl context '${CONTEXT_NAME}' before Helm verification"
  as_user kubectl --kubeconfig="${LOCAL_KUBECONFIG}" config use-context "${CONTEXT_NAME}" >/dev/null
fi

log "Verifying Helm can reach the active Kubernetes context"
as_user helm --kubeconfig "${LOCAL_KUBECONFIG}" list -A >/dev/null \
  || fail "Helm connectivity check failed. Ensure kubectl context is configured and cluster is reachable."

log "Done. Helm is installed and verified against kubeconfig: ${LOCAL_KUBECONFIG}"
