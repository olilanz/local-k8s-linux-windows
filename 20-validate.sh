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
require_privileged_access

print_section() {
  local title="$1"
  printf "\n===== %s =====\n" "${title}" | tee /dev/fd/3
}

run_check() {
  local description="$1"
  shift

  printf "%s\n" "-- ${description}" | tee /dev/fd/3
  if "$@" 2>&1 | tee /dev/fd/3; then
    printf "[PASS] %s\n" "${description}" | tee /dev/fd/3
  else
    local rc=$?
    printf "[WARN] %s (exit=%s)\n" "${description}" "${rc}" | tee /dev/fd/3
  fi
}

print_section "SYSTEMD SERVICES"
for svc in containerd k0scontroller k0sworker kubelet; do
  run_check "systemctl is-active ${svc}" as_root systemctl is-active "${svc}"
  run_check "systemctl is-enabled ${svc}" as_root systemctl is-enabled "${svc}"
  run_check "systemctl status ${svc}" as_root systemctl status "${svc}" --no-pager
done

print_section "CONTROL PLANE CONNECTIVITY"
run_check "Kubernetes version via API" k0s_kubectl version
run_check "API /healthz" k0s_kubectl get --raw=/healthz

print_section "CALICO STATUS"
run_check "Calico daemonset" k0s_kubectl -n kube-system get daemonset calico-node -o wide
run_check "Calico kube-controllers" k0s_kubectl -n kube-system get deployment calico-kube-controllers -o wide
run_check "Calico node pods" k0s_kubectl -n kube-system get pods -l k8s-app=calico-node -o wide
run_check "Calico kube-controllers pods" k0s_kubectl -n kube-system get pods -l k8s-app=calico-kube-controllers -o wide
run_check "Calico IP pools" k0s_kubectl get ippool
run_check "Calico IPAM config" k0s_kubectl get ipamconfigs

print_section "LINUX NODE CONNECTIVITY"
run_check "Linux nodes (selector kubernetes.io/os=linux)" k0s_kubectl get nodes -l kubernetes.io/os=linux -o wide --show-labels
run_check "Linux node details" k0s_kubectl get nodes -l kubernetes.io/os=linux -o yaml

print_section "WINDOWS NODE CONNECTIVITY"
run_check "Windows nodes (selector node.kubernetes.io/windows-build)" k0s_kubectl get nodes -l node.kubernetes.io/windows-build -o wide --show-labels

WINDOWS_NODE_NAMES="$(k0s_kubectl get nodes -l node.kubernetes.io/windows-build -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null || true)"
if [[ -z "${WINDOWS_NODE_NAMES}" ]]; then
  printf "[WARN] No Windows nodes matched label selector: node.kubernetes.io/windows-build\n" | tee /dev/fd/3
else
  while IFS= read -r node; do
    [[ -z "${node}" ]] && continue
    run_check "Windows node detail: ${node}" k0s_kubectl get node "${node}" -o wide --show-labels
    run_check "Windows node describe: ${node}" k0s_kubectl describe node "${node}"
  done <<<"${WINDOWS_NODE_NAMES}"
fi

print_section "KUBECTL NON-ROOT CONVENIENCE"
run_check "kubectl binary available in PATH" command -v kubectl
run_check "kubectl client version (non-root)" kubectl version --client
run_check "kubectl current context (non-root)" kubectl config current-context
run_check "kubectl node query (non-root)" kubectl get nodes -o wide

print_section "BROAD SNAPSHOT (SUPPLEMENTAL)"
run_check "All nodes" k0s_kubectl get nodes -o wide
run_check "kube-system pods" k0s_kubectl get pods -n kube-system -o wide
run_check "All pods" k0s_kubectl get pods -A -o wide
run_check "All services" k0s_kubectl get svc -A

print_section "END"
summary "Run ./99-cleanup.sh when contamination is suspected"
