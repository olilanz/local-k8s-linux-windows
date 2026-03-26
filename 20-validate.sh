#!/usr/bin/env bash
set -euo pipefail

# Purpose: Provide a broad validation snapshot of cluster and host runtime state.
# Preconditions: Any prior stage may have been run; API access may be partial.
# Invariants: Validation is observational; avoid mutating cluster state.
# Inputs: Current cluster and host service/process state.
# Idempotency: Safe to rerun; read-only diagnostics with tolerant error handling.
# Postconditions: Operator receives consolidated diagnostics view.
# Safe rerun notes: Re-running is encouraged during troubleshooting.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/common.sh
source "${SCRIPT_DIR}/scripts/lib/common.sh"
init_script "${BASH_SOURCE[0]}"
register_error_trap

echo ""
echo "===== NODES ====="
sudo k0s kubectl get nodes -o wide || true

echo ""
echo "===== SYSTEM PODS ====="
sudo k0s kubectl get pods -n kube-system -o wide || true

echo ""
echo "===== ALL PODS ====="
sudo k0s kubectl get pods -A -o wide || true

echo ""
echo "===== CALICO ====="
sudo k0s kubectl get ippool 2>/dev/null || true
sudo k0s kubectl get ipamconfigs 2>/dev/null || true

echo ""
echo "===== SERVICES ====="
sudo k0s kubectl get svc -A || true

echo ""
echo "===== KUBELET PROCESS ====="
ps aux | grep kubelet | grep -v grep || true

echo ""
echo "===== CONTAINERD ====="
sudo systemctl status containerd --no-pager || true

echo ""
echo "===== API HEALTH ====="
sudo k0s kubectl get --raw=/healthz || true

echo ""
echo "===== END ====="
summary "Run ./99-cleanup.sh when contamination is suspected"
