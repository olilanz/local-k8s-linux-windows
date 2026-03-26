#!/usr/bin/env bash
set -euo pipefail

# Purpose: Run a simple nginx smoke test against the cluster.
# Preconditions: Cluster and networking stages completed; API reachable.
# Invariants: Test stage must not introduce hidden state beyond test resources.
# Inputs: cluster API and public nginx image.
# Idempotency: Safe to rerun; deployment/service are recreated each run.
# Postconditions: nginx deployment exposed and basic in-cluster HTTP check executed.
# Safe rerun notes: Existing nginx test resources are removed before recreation.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/common.sh
source "${SCRIPT_DIR}/scripts/lib/common.sh"
init_script "${BASH_SOURCE[0]}"
register_error_trap

log "Deploying nginx"
sudo k0s kubectl delete deployment nginx 2>/dev/null || true
sudo k0s kubectl delete svc nginx 2>/dev/null || true

sudo k0s kubectl create deployment nginx --image=nginx
sudo k0s kubectl expose deployment nginx --port=80 --type=ClusterIP

log "Waiting for pod"
sudo k0s kubectl rollout status deployment/nginx --timeout=120s

log "Testing connectivity"
sudo k0s kubectl run curl --rm -it --image=curlimages/curl --restart=Never -- \
  curl -s http://nginx | head -n 5

summary "./20-validate.sh"
