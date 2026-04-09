#!/usr/bin/env bash
set -euo pipefail

# Purpose: Deploy OpenTelemetry Collector with external OTLP/HTTP ingress and internal OTLP/gRPC.
# Preconditions: ingress-nginx installed and API reachable.
# Invariants: OTLP/HTTP exposed at otel.kubernetes; OTLP/gRPC remains cluster-internal.
# Inputs: config/otel/* manifests.
# Idempotency: Safe to rerun; resources are reconciled declaratively.
# Postconditions: Collector is running and ingest endpoints are available.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/common.sh
source "${SCRIPT_DIR}/scripts/lib/common.sh"
init_script "${BASH_SOURCE[0]}"
register_error_trap
require_privileged_access

log "Checking API availability"
k0s_kubectl get --raw=/healthz >/dev/null 2>&1 \
  || fail "API server not reachable. Run 02-cluster.sh first."

log "Applying OpenTelemetry Collector manifests"
k0s_kubectl apply -f ./config/otel/00-namespace.yaml
k0s_kubectl apply -f ./config/otel/10-configmap.yaml
k0s_kubectl apply -f ./config/otel/20-deployment.yaml
k0s_kubectl apply -f ./config/otel/30-service.yaml
k0s_kubectl apply -f ./config/otel/40-ingress.yaml

log "Waiting for collector rollout"
k0s_kubectl -n observability rollout status deployment/otel-collector --timeout=240s

log "Collector service"
k0s_kubectl -n observability get svc otel-collector -o wide

log "Collector ingress"
k0s_kubectl -n observability get ingress otel-collector -o wide

summary "./15-aspire-dashboard.sh"

