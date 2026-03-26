#!/usr/bin/env bash
set -euo pipefail

log() { echo -e "\n[$(date +%H:%M:%S)] $*"; }

log "Stopping k0s (if running)"
sudo k0s stop 2>/dev/null || true

log "Disabling and removing k0s service"
sudo systemctl disable k0scontroller 2>/dev/null || true
sudo rm -f /etc/systemd/system/k0scontroller.service
sudo systemctl daemon-reexec
sudo systemctl daemon-reload

log "Stopping containerd (optional reset)"
sudo systemctl stop containerd 2>/dev/null || true

log "Killing leftover processes"
sudo pkill -f kubelet 2>/dev/null || true
sudo pkill -f kube-apiserver 2>/dev/null || true
sudo pkill -f kube-controller-manager 2>/dev/null || true
sudo pkill -f kube-scheduler 2>/dev/null || true
sudo pkill -f kube-proxy 2>/dev/null || true
sudo pkill -f containerd-shim 2>/dev/null || true

log "Unmounting kubelet and k0s mounts"
mount | grep -E '/var/lib/k0s|/var/lib/kubelet' 2>/dev/null | \
awk '{print $3}' | sort -r | while read -r m; do
  sudo umount -l "$m" 2>/dev/null || true
done || true

log "Removing Kubernetes state"
sudo rm -rf /var/lib/k0s
sudo rm -rf /var/lib/kubelet
sudo rm -rf /etc/k0s

log "Removing CNI state"
sudo rm -rf /etc/cni/net.d
sudo rm -rf /var/lib/cni
sudo rm -rf /var/run/calico

log "Resetting networking (interfaces)"
sudo ip link delete cni0 2>/dev/null || true
sudo ip link delete flannel.1 2>/dev/null || true
sudo ip link delete cali* 2>/dev/null || true || true

log "Flushing iptables (safe reset)"
sudo iptables -F || true
sudo iptables -t nat -F || true
sudo iptables -t mangle -F || true

log "Restarting containerd"
sudo systemctl start containerd

log "Cleanup complete"
