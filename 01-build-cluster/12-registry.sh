#!/usr/bin/env bash
set -euo pipefail

# Purpose: Deploy an in-cluster local/private container registry with ingress route.
# Preconditions: ingress-nginx is installed and API is reachable.
# Invariants: Public upstream images continue pulling directly from internet.
# Inputs: config/registry/* manifests.
# Idempotency: Safe to rerun; manifests are reconciled declaratively.
# Postconditions: Registry is reachable at cr.kubernetes through ingress.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/common.sh
source "${SCRIPT_DIR}/scripts/lib/common.sh"
init_script "${BASH_SOURCE[0]}"
register_error_trap
require_privileged_access

log "Checking API availability"
k0s_kubectl get --raw=/healthz >/dev/null 2>&1 \
  || fail "API server not reachable. Run 02-cluster.sh first."

log "Applying local registry manifests"
k0s_kubectl apply -f ./config/registry/00-namespace.yaml
k0s_kubectl apply -f ./config/registry/10-pvc.yaml
k0s_kubectl apply -f ./config/registry/20-deployment.yaml
k0s_kubectl apply -f ./config/registry/30-service.yaml
k0s_kubectl apply -f ./config/registry/40-ingress.yaml

log "Waiting for registry rollout"
k0s_kubectl -n registry rollout status deployment/registry --timeout=240s

log "Registry ingress"
k0s_kubectl -n registry get ingress registry -o wide

summary "./13-argocd.sh"

