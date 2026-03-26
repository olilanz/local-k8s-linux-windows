#!/usr/bin/env bash
set -euo pipefail

CONFIG_DIR="./config"
K0S_CONFIG="${CONFIG_DIR}/k0s.yaml"
CALICO_MANIFEST="${CONFIG_DIR}/calico.yaml"
CALICO_IPPOOL="${CONFIG_DIR}/calico-ippool.yaml"
CALICO_IPAM="${CONFIG_DIR}/calico-ipam.yaml"

log() {
  printf '\n[%s] %s\n' "$(date '+%H:%M:%S')" "$*"
}

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

require_file() {
  local f="$1"
  [[ -f "$f" ]] || fail "Missing required file: $f"
}

ensure_containerd() {
  log "Ensuring containerd package/service"

  if ! dpkg -s containerd >/dev/null 2>&1; then
    log "Installing containerd"
    sudo apt update
    sudo apt install -y containerd
  fi

  sudo systemctl enable containerd >/dev/null 2>&1 || true
  sudo systemctl restart containerd
  sudo systemctl is-active --quiet containerd || fail "containerd is not running"
}

ensure_cni_dirs() {
  log "Ensuring CNI directories"
  sudo mkdir -p /etc/cni/net.d
  sudo mkdir -p /opt/cni/bin
}

ensure_cni_binaries() {
  log "Ensuring CNI plugin binaries"

  if [ ! -f /opt/cni/bin/bridge ]; then
    log "CNI plugins missing → installing containernetworking-plugins"
    sudo apt update
    sudo apt install -y containernetworking-plugins
  else
    log "CNI plugins already present"
  fi
}

ensure_k0s_binary() {
  if ! command -v k0s >/dev/null 2>&1; then
    log "Installing k0s binary"
    curl -sSLf https://get.k0s.sh | sudo sh
  fi
}

install_or_refresh_k0s_service() {
  log "Refreshing k0s controller service from ${K0S_CONFIG}"
  sudo systemctl stop k0scontroller 2>/dev/null || true
  sudo rm -f /etc/systemd/system/k0scontroller.service
  sudo systemctl daemon-reload
  sudo k0s install controller --config "${K0S_CONFIG}"
}

start_k0s() {
  log "Starting k0s"
  sudo k0s start
}

wait_for_api() {
  log "Waiting for API server"
  local tries=0
  until sudo k0s kubectl get ns >/dev/null 2>&1; do
    tries=$((tries + 1))
    if [[ $tries -gt 90 ]]; then
      fail "Timed out waiting for Kubernetes API"
    fi
    sleep 2
  done
}

wait_for_node_registration() {
  log "Waiting for local node registration"
  local node_name
  node_name="$(hostname)"
  local tries=0
  until sudo k0s kubectl get node "${node_name}" >/dev/null 2>&1; do
    tries=$((tries + 1))
    if [[ $tries -gt 90 ]]; then
      fail "Timed out waiting for node ${node_name} to register"
    fi
    sleep 2
  done
}

wait_for_calico_crds() {
  log "Waiting for Calico CRDs"
  local tries=0
  until sudo k0s kubectl get crd ippools.crd.projectcalico.org >/dev/null 2>&1 \
    && sudo k0s kubectl get crd ipamconfigs.crd.projectcalico.org >/dev/null 2>&1; do
    tries=$((tries + 1))
    if [[ $tries -gt 120 ]]; then
      fail "Timed out waiting for Calico CRDs"
    fi
    sleep 2
  done
}

apply_cluster_manifests() {
  log "Applying Calico base"
  sudo k0s kubectl apply -f "${CALICO_MANIFEST}"

  wait_for_calico_crds

  log "Applying Calico IPPool"
  sudo k0s kubectl apply -f "${CALICO_IPPOOL}"

  log "Applying Calico IPAM"
  sudo k0s kubectl apply -f "${CALICO_IPAM}"
}

restart_calico_if_present() {
  log "Restarting calico-node daemonset if present"
  sudo k0s kubectl rollout restart daemonset/calico-node -n kube-system >/dev/null 2>&1 || true
}

show_status() {
  log "Current nodes"
  sudo k0s kubectl get nodes -o wide || true

  log "Current kube-system pods"
  sudo k0s kubectl get pods -n kube-system -o wide || true

  log "Current IPPool"
  sudo k0s kubectl get ippool -o wide || true

  log "Current IPAMConfig"
  sudo k0s kubectl get ipamconfigs -o yaml || true
}

main() {
  require_file "${K0S_CONFIG}"
  require_file "${CALICO_MANIFEST}"
  require_file "${CALICO_IPPOOL}"
  require_file "${CALICO_IPAM}"

  ensure_containerd
  ensure_cni_dirs
  ensure_cni_binaries
  ensure_k0s_binary
  install_or_refresh_k0s_service
  start_k0s
  wait_for_api
  wait_for_node_registration
  apply_cluster_manifests
  restart_calico_if_present
  show_status

  log "Build script completed"
}

main "$@"
