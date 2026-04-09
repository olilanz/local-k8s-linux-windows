#!/usr/bin/env bash
set -euo pipefail

# Purpose: Deploy Aspire dashboard and sample OTLP traffic generator.
# Preconditions: OpenTelemetry collector stage completed and API reachable.
# Invariants: Dashboard remains in-cluster and exposed via ingress.
# Inputs: config/aspire/* manifests.
# Idempotency: Safe to rerun; resources are applied declaratively.
# Postconditions: Aspire UI reachable at aspire.kubernetes; sample telemetry sent to collector.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/common.sh
source "${SCRIPT_DIR}/scripts/lib/common.sh"
init_script "${BASH_SOURCE[0]}"
register_error_trap
require_privileged_access

log "Checking API availability"
k0s_kubectl get --raw=/healthz >/dev/null 2>&1 \
  || fail "API server not reachable. Run 02-cluster.sh first."

log "Applying Aspire dashboard manifests"
k0s_kubectl apply -f ./config/aspire/00-namespace.yaml
k0s_kubectl apply -f ./config/aspire/10-deployment.yaml
k0s_kubectl apply -f ./config/aspire/20-service.yaml
k0s_kubectl apply -f ./config/aspire/30-ingress.yaml

log "Applying sample telemetry generator"
k0s_kubectl apply -f ./config/aspire/40-telemetrygen-job.yaml

log "Waiting for aspire dashboard rollout"
k0s_kubectl -n observability rollout status deployment/aspire-dashboard --timeout=240s

log "Aspire ingress"
k0s_kubectl -n observability get ingress aspire-dashboard -o wide

log "Recent telemetry generator jobs"
k0s_kubectl -n observability get jobs -l app=otel-telemetrygen -o wide || true

summary "./20-validate.sh"

