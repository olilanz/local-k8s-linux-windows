#!/usr/bin/env bash
set -euo pipefail

# Purpose: Perform a destructive local cleanup of cluster/runtime/network state.
# Preconditions: Operator intends full local reset and accepts destructive side effects.
# Invariants: Cleanup removes local cluster artifacts to restore a clean rebuild baseline.
# Inputs: Current host service/process/runtime/network state.
# Idempotency: Safe to rerun; missing resources are tolerated.
# Postconditions: k0s/container runtime leftovers and CNI state are cleared as much as possible.
# Safe rerun notes: Reboot after cleanup is recommended before sequential rebuild.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/common.sh
source "${SCRIPT_DIR}/scripts/lib/common.sh"
init_script "${BASH_SOURCE[0]}"
register_error_trap

SUDO_BIN=""
if [[ "${EUID}" -eq 0 ]]; then
  log "Running as root"
elif command -v sudo >/dev/null 2>&1; then
  if sudo -n true >/dev/null 2>&1; then
    SUDO_BIN="sudo"
    log "Using non-interactive sudo"
  else
    fail "This script needs privileged operations. Run with root privileges or enable non-interactive sudo for this session."
  fi
else
  fail "sudo is required when not running as root"
fi

as_root() {
  if [[ -n "${SUDO_BIN}" ]]; then
    "${SUDO_BIN}" "$@"
  else
    "$@"
  fi
}

safe_remove_path() {
  local path="$1"
  if ! as_root rm -rf "${path}" 2>/dev/null; then
    warn "Skipping removal of ${path}; resource may be busy or protected"
  fi
}

# --- stop k0s ---
log "Stopping k0s services"
as_root k0s stop 2>/dev/null || true

# --- stop systemd services ---
log "Disabling k0s services"
as_root systemctl disable k0scontroller 2>/dev/null || true
as_root systemctl disable k0sworker 2>/dev/null || true

# --- remove systemd units ---
log "Removing systemd unit files"
as_root rm -f /etc/systemd/system/k0scontroller.service
as_root rm -f /etc/systemd/system/k0sworker.service
as_root systemctl daemon-reexec
as_root systemctl daemon-reload

# --- stop containerd HARD ---
log "Stopping containerd"
as_root systemctl stop containerd 2>/dev/null || true

# --- kill remaining processes ---
log "Killing leftover processes"
as_root pkill -9 -f kubelet 2>/dev/null || true
as_root pkill -9 -f kube-apiserver 2>/dev/null || true
as_root pkill -9 -f containerd-shim 2>/dev/null || true
as_root pkill -9 -f runc 2>/dev/null || true

# --- force unmount EVERYTHING kube-related ---
log "Force unmounting leftovers"
mount | grep -E '/var/lib/k0s|/var/lib/kubelet|/run/k0s' 2>/dev/null | \
awk '{print $3}' | sort -r | while read -r m; do
  as_root umount -lf "$m" 2>/dev/null || true
done || true

# --- remove cluster state ---
log "Removing cluster state"
safe_remove_path /var/lib/k0s
safe_remove_path /var/lib/kubelet
safe_remove_path /etc/k0s

# --- remove containerd runtime leftovers ---
log "Cleaning containerd runtime state"
safe_remove_path /run/k0s
safe_remove_path /run/containerd/io.containerd.runtime.v2.task
safe_remove_path /var/lib/containerd/io.containerd.runtime.v2.task

# --- remove CNI ---
log "Removing CNI state"
safe_remove_path /var/lib/cni
safe_remove_path /run/calico

# --- reset iptables ---
log "Resetting iptables"
as_root iptables -F || true
as_root iptables -t nat -F || true
as_root iptables -t mangle -F || true
as_root iptables -X || true

# --- restart containerd clean ---
log "Starting containerd"
as_root systemctl start containerd 2>/dev/null || warn "containerd could not be started automatically"

# --- verification ---
log "Cleanup complete"

echo
echo "Remaining mounts (should be empty):"
mount | grep -E 'k0s|kubelet|containerd' || true

echo
echo "Remaining processes (should be empty):"
ps aux | grep -E 'kubelet|k0s|containerd-shim' | grep -v grep || true

summary "Reboot, then restart with ./01-prereqs.sh"
