#!/usr/bin/env bash
set -euo pipefail

log() { echo -e "\n[$(date +%H:%M:%S)] $*"; }

CONFIG_FILE="./config/k0s.yaml"

if [ ! -f "$CONFIG_FILE" ]; then
  echo "ERROR: $CONFIG_FILE not found"
  exit 1
fi

# --- stop previous cluster ---
log "Stopping k0s (if running)"
sudo k0s stop 2>/dev/null || true

# --- remove systemd services ---
log "Removing old k0s services"
sudo systemctl disable k0scontroller 2>/dev/null || true
sudo systemctl disable k0sworker 2>/dev/null || true
sudo rm -f /etc/systemd/system/k0scontroller.service
sudo rm -f /etc/systemd/system/k0sworker.service
sudo systemctl daemon-reexec
sudo systemctl daemon-reload

# --- kill leftovers ---
log "Killing leftover processes"
sudo pkill -f kubelet 2>/dev/null || true
sudo pkill -f containerd-shim 2>/dev/null || true

# --- unmount leftovers ---
log "Unmounting leftovers"
mount | grep -E '/var/lib/k0s|/var/lib/kubelet' 2>/dev/null | \
awk '{print $3}' | sort -r | while read -r m; do
  sudo umount -l "$m" 2>/dev/null || true
done || true

# --- wipe state ---
log "Removing cluster state"
sudo rm -rf /var/lib/k0s
sudo rm -rf /var/lib/kubelet
sudo rm -rf /etc/k0s

# --- ensure containerd ---
log "Ensuring containerd is running"
if ! systemctl is-active --quiet containerd; then
  sudo systemctl start containerd
fi

# --- install controller ---
log "Installing k0s controller"
sudo k0s install controller --config "$CONFIG_FILE"

# --- start controller ---
log "Starting k0s controller"
sudo k0s start

# --- wait for API ---
log "Waiting for API server"
for i in {1..60}; do
  if sudo k0s kubectl get --raw=/healthz >/dev/null 2>&1; then
    log "API is up"
    exit 0
  fi
  sleep 2
done

echo "ERROR: API server did not become ready"
exit 1
