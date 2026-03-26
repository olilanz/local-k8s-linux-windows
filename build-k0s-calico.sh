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
  log "Ensuring containerd"

  if ! dpkg -s containerd >/dev/null 2>&1; then
    sudo apt update
    sudo apt install -y containerd
  fi

  sudo systemctl enable containerd >/dev/null 2>&1 || true
  sudo systemctl restart containerd
  sudo systemctl is-active --quiet containerd || fail "containerd not running"
}

ensure_cni() {
  log "Ensuring CNI dirs + binaries"

  sudo mkdir -p /etc/cni/net.d
  sudo mkdir -p /opt/cni/bin

  if [ ! -f /opt/cni/bin/bridge ]; then
    sudo apt update
    sudo apt install -y containernetworking-plugins
  fi
}

ensure_k0s() {
  if ! command -v k0s >/dev/null 2>&1; then
    log "Installing k0s"
    curl -sSLf https://get.k0s.sh | sudo sh
  fi
}

install_k0s() {
  log "Installing k0s controller (single-node)"

  K0S_CONFIG_ABS=$(readlink -f "${K0S_CONFIG}")

  sudo systemctl stop k0scontroller 2>/dev/null || true
  sudo rm -f /etc/systemd/system/k0scontroller.service
  sudo systemctl daemon-reload

  sudo k0s install controller --single --config "${K0S_CONFIG_ABS}"
}

start_k0s() {
  log "Starting k0s"
  sudo k0s start
}

wait_for_api() {
  log "Waiting for API"

  for i in {1..90}; do
    if sudo k0s kubectl get ns >/dev/null 2>&1; then
      return
    fi
    sleep 2
  done

  fail "API did not come up"
}

wait_for_node() {
  log "Waiting for node registration"

  for i in {1..90}; do
    if sudo k0s kubectl get nodes 2>/dev/null | grep -q "Ready\|NotReady"; then
      return
    fi
    sleep 2
  done

  fail "Node did not register"
}

install_calico() {
  log "Installing Calico"

  sudo k0s kubectl apply -f "${CALICO_MANIFEST}"
}

wait_for_calico() {
  log "Waiting for Calico CRDs"

  for i in {1..120}; do
    if sudo k0s kubectl get crd ippools.crd.projectcalico.org >/dev/null 2>&1; then
      break
    fi
    sleep 2
  done

  log "Applying Calico IPPool + IPAM"
  sudo k0s kubectl apply -f "${CALICO_IPPOOL}"
  sudo k0s kubectl apply -f "${CALICO_IPAM}"
}

wait_for_calico_ready() {
  log "Waiting for Calico pods"

  for i in {1..120}; do
    if sudo k0s kubectl get pods -n kube-system | grep calico-node | grep -q Running; then
      return
    fi
    sleep 2
  done

  fail "Calico did not become ready"
}

status() {
  log "Cluster status"

  sudo k0s kubectl get nodes -o wide
  sudo k0s kubectl get pods -n kube-system -o wide
  sudo k0s kubectl get ippool || true
}

main() {
  require_file "${K0S_CONFIG}"
  require_file "${CALICO_MANIFEST}"
  require_file "${CALICO_IPPOOL}"
  require_file "${CALICO_IPAM}"

  ensure_containerd
  ensure_cni
  ensure_k0s
  install_k0s
  start_k0s

  wait_for_api
  wait_for_node

  install_calico
  wait_for_calico
  wait_for_calico_ready

  status

  log "Cluster build complete"
}

main "$@"
