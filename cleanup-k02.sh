#!/usr/bin/env bash
set -euo pipefail

echo "== k0s full cleanup starting =="

# --- Stop services ---
echo "-- Stopping k0s + containerd"
sudo systemctl stop k0scontroller 2>/dev/null || true
sudo systemctl stop containerd 2>/dev/null || true

# --- Kill remaining processes ---
echo "-- Killing leftover processes"
sudo pkill -f kubelet 2>/dev/null || true
sudo pkill -f containerd-shim 2>/dev/null || true
sudo pkill -f k0s 2>/dev/null || true

# --- Remove systemd service ---
echo "-- Removing k0s systemd service"
sudo systemctl disable k0scontroller 2>/dev/null || true
sudo rm -f /etc/systemd/system/k0scontroller.service
sudo systemctl daemon-reload

# --- Unmount kubelet mounts ---
echo "-- Unmounting kubelet mounts"
mount | grep -E 'k0s|kubelet' | awk '{print $3}' | while read -r m; do
  sudo umount -l "$m" 2>/dev/null || true
done

# --- Remove directories ---
echo "-- Removing k0s directories"
sudo rm -rf /var/lib/k0s
sudo rm -rf /etc/k0s
sudo rm -rf /var/lib/kubelet
sudo rm -rf /etc/cni
sudo rm -rf /opt/cni

# --- Cleanup network interfaces ---
echo "-- Cleaning network interfaces"

# delete known interfaces
for iface in vxlan.calico tunl0 kube-bridge; do
  sudo ip link delete "$iface" 2>/dev/null || true
done

# delete calico interfaces
ip link | grep cali | awk -F: '{print $2}' | tr -d ' ' | while read -r iface; do
  sudo ip link delete "$iface" 2>/dev/null || true
done

# --- Reset iptables ---
echo "-- Resetting iptables"
sudo iptables -F || true
sudo iptables -t nat -F || true
sudo iptables -t mangle -F || true

echo "== k0s cleanup complete =="
echo "Recommended: reboot before reinstall"
