#!/usr/bin/env bash
set -euo pipefail

# Purpose: Install Argo CD from raw upstream manifests and expose UI via ingress.
# Preconditions: ingress-nginx installed and API reachable.
# Invariants: No Helm dependency; Argo CD installed declaratively.
# Inputs: ARGOCD_INSTALL_URL, config/argocd/* manifests.
# Idempotency: Safe to rerun; resources are reconciled with apply.
# Postconditions: Argo CD API/UI reachable at argo.kubernetes.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/common.sh
source "${SCRIPT_DIR}/scripts/lib/common.sh"
init_script "${BASH_SOURCE[0]}"
register_error_trap
require_privileged_access

ARGOCD_INSTALL_URL="${ARGOCD_INSTALL_URL:-https://raw.githubusercontent.com/argoproj/argo-cd/v2.12.3/manifests/install.yaml}"

log "Checking API availability"
k0s_kubectl get --raw=/healthz >/dev/null 2>&1 \
  || fail "API server not reachable. Run 02-cluster.sh first."

log "Installing Argo CD from ${ARGOCD_INSTALL_URL}"
k0s_kubectl apply -f "${ARGOCD_INSTALL_URL}"

log "Applying Argo CD local configuration and ingress"
k0s_kubectl apply -f ./config/argocd/10-cmd-params.yaml
k0s_kubectl apply -f ./config/argocd/20-server-service.yaml
k0s_kubectl apply -f ./config/argocd/30-ingress.yaml

log "Restarting argocd-server to pick up cmd params"
k0s_kubectl -n argocd rollout restart deployment/argocd-server
k0s_kubectl -n argocd rollout status deployment/argocd-server --timeout=300s

log "Argo CD ingress"
k0s_kubectl -n argocd get ingress argocd-server -o wide

summary "./14-otel-collector.sh"
