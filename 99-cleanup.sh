#!/usr/bin/env bash
set -euo pipefail

log() { echo -e "\n[$(date +%H:%M:%S)] $*"; }

# --- stop k0s ---
log "Stopping k0s services"
sudo k0s stop 2>/dev/null || true

# --- stop systemd services ---
log "Disabling k0s services"
sudo systemctl disable k0scontroller 2>/dev/null || true
sudo systemctl disable k0sworker 2>/dev/null || true

# --- remove systemd units ---
log "Removing systemd unit files"
sudo rm -f /etc/systemd/system/k0scontroller.service
sudo rm -f /etc/systemd/system/k0sworker.service
sudo systemctl daemon-reexec
sudo systemctl daemon-reload

# --- stop containerd HARD ---
log "Stopping containerd"
sudo systemctl stop containerd 2>/dev/null || true

# --- kill remaining processes ---
log "Killing leftover processes"
sudo pkill -9 -f kubelet 2>/dev/null || true
sudo pkill -9 -f kube-apiserver 2>/dev/null || true
sudo pkill -9 -f containerd-shim 2>/dev/null || true
sudo pkill -9 -f runc 2>/dev/null || true

# --- force unmount EVERYTHING kube-related ---
log "Force unmounting leftovers"
mount | grep -E '/var/lib/k0s|/var/lib/kubelet|/run/k0s' 2>/dev/null | \
awk '{print $3}' | sort -r | while read -r m; do
  sudo umount -lf "$m" 2>/dev/null || true
done || true

# --- remove cluster state ---
log "Removing cluster state"
sudo rm -rf /var/lib/k0s
sudo rm -rf /var/lib/kubelet
sudo rm -rf /etc/k0s

# --- remove containerd runtime leftovers ---
log "Cleaning containerd runtime state"
sudo rm -rf /run/k0s
sudo rm -rf /run/containerd/io.containerd.runtime.v2.task
sudo rm -rf /var/lib/containerd/io.containerd.runtime.v2.task

# --- remove CNI ---
log "Removing CNI state"
sudo rm -rf /var/lib/cni
sudo rm -rf /run/calico

# --- reset iptables ---
log "Resetting iptables"
sudo iptables -F || true
sudo iptables -t nat -F || true
sudo iptables -t mangle -F || true
sudo iptables -X || true

# --- restart containerd clean ---
log "Starting containerd"
sudo systemctl start containerd

# --- verification ---
log "Cleanup complete"

echo
echo "Remaining mounts (should be empty):"
mount | grep -E 'k0s|kubelet|containerd' || true

echo
echo "Remaining processes (should be empty):"
ps aux | grep -E 'kubelet|k0s|containerd-shim' | grep -v grep || true
