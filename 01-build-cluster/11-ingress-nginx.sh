#!/usr/bin/env bash
set -euo pipefail

# Purpose: Install ingress-nginx controller from raw upstream Kubernetes manifests.
# Preconditions: Cluster and networking stages completed; API reachable.
# Invariants: No Helm dependency; installation is manifest-driven.
# Inputs: INGRESS_NGINX_MANIFEST_URL.
# Idempotency: Safe to rerun; manifests are applied declaratively.
# Postconditions: ingress-nginx controller is running and able to reconcile Ingress resources.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/common.sh
source "${SCRIPT_DIR}/scripts/lib/common.sh"
init_script "${BASH_SOURCE[0]}"
register_error_trap
require_privileged_access

INGRESS_NGINX_MANIFEST_URL="${INGRESS_NGINX_MANIFEST_URL:-https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.11.1/deploy/static/provider/cloud/deploy.yaml}"

log "Checking API availability"
k0s_kubectl get --raw=/healthz >/dev/null 2>&1 \
  || fail "API server not reachable. Run 02-cluster.sh first."

log "Applying ingress-nginx manifests from ${INGRESS_NGINX_MANIFEST_URL}"
k0s_kubectl apply -f "${INGRESS_NGINX_MANIFEST_URL}"

log "Patching ingress controller to bind host ports 80/443 on Linux node"
k0s_kubectl -n ingress-nginx patch deployment ingress-nginx-controller \
  --type='merge' \
  -p '{"spec":{"template":{"spec":{"hostNetwork":true,"dnsPolicy":"ClusterFirstWithHostNet"}}}}'

log "Waiting for ingress controller rollout"
k0s_kubectl -n ingress-nginx rollout status deployment/ingress-nginx-controller --timeout=240s

log "Ingress classes"
k0s_kubectl get ingressclass

summary "./12-registry.sh"

