#!/usr/bin/env bash
set -euo pipefail

# ---- config ----
K0S_CONFIG_PATH="${K0S_CONFIG_PATH:-/home/ocl/k0s.yaml}"
API_ADDRESS="${API_ADDRESS:-192.168.250.10}"
CALICO_VERSION="${CALICO_VERSION:-v3.31.4}"

log() {
  printf '\n[%s] %s\n' "$(date '+%H:%M:%S')" "$*"
}

# ---- ensure container runtime ----
ensure_containerd() {
  if ! systemctl list-unit-files | grep -q containerd.service; then
    log "Installing containerd"
    sudo apt update
    sudo apt install -y containerd
  fi

  log "Ensuring containerd is running"
  sudo systemctl enable containerd
  sudo systemctl restart containerd
}

# ---- ensure CNI dirs ----
ensure_cni_dirs() {
  log "Ensuring CNI directories"
  sudo mkdir -p /etc/cni/net.d
  sudo mkdir -p /opt/cni/bin
}

# ---- generate config ----
generate_config() {
  log "Generating k0s config"
  sudo k0s config create > "$K0S_CONFIG_PATH"

  log "Patching config safely"

  # API address
  sed -i "s/address: .*/address: ${API_ADDRESS}/" "$K0S_CONFIG_PATH"

  # enforce custom provider
  sed -i "s/provider: .*/provider: custom/" "$K0S_CONFIG_PATH"

  # remove kube-router section if present (important)
  sed -i '/kuberouter:/,/^[^ ]/d' "$K0S_CONFIG_PATH"

  # ensure workerProfiles exists ONLY if already present
  if grep -q "^  workerProfiles:" "$K0S_CONFIG_PATH"; then
    log "workerProfiles already present"
  else
    log "Skipping workerProfiles injection (not required)"
  fi
}

# ---- install k0s ----
install_k0s() {
  if ! command -v k0s >/dev/null; then
    log "Installing k0s"
    curl -sSLf https://get.k0s.sh | sudo sh
  fi

  log "Ensuring clean k0s service"

  sudo systemctl stop k0scontroller 2>/dev/null || true
  sudo rm -f /etc/systemd/system/k0scontroller.service || true
  sudo systemctl daemon-reload

  log "Installing controller"
  sudo k0s install controller --config "$K0S_CONFIG_PATH"

  log "Starting k0s"
  sudo k0s start
}

# ---- wait for API ----
wait_for_api() {
  log "Waiting for API"
  until sudo k0s kubectl get ns >/dev/null 2>&1; do
    sleep 2
  done
}

# ---- install calico ----
install_calico() {
  log "Downloading Calico"
  curl -fsSL "https://raw.githubusercontent.com/projectcalico/calico/${CALICO_VERSION}/manifests/calico.yaml" -o calico.yaml

  log "Applying Calico"
  sudo k0s kubectl apply -f calico.yaml
}

# ---- ensure ippool ----
ensure_ippool() {
  if ! sudo k0s kubectl get ippool default-ipv4-ippool >/dev/null 2>&1; then
    log "Creating IPPool (VXLAN)"

    sudo k0s kubectl apply -f - <<EOF
apiVersion: crd.projectcalico.org/v1
kind: IPPool
metadata:
  name: default-ipv4-ippool
spec:
  cidr: 172.16.0.0/16
  ipipMode: Never
  vxlanMode: Always
  natOutgoing: true
  nodeSelector: all()
EOF
  else
    log "IPPool already exists"
  fi
}

# ---- ensure ipam ----
ensure_ipam() {
  log "Ensuring IPAM strictAffinity"

  sudo k0s kubectl apply -f - <<EOF
apiVersion: crd.projectcalico.org/v1
kind: IPAMConfig
metadata:
  name: default
spec:
  strictAffinity: true
EOF
}

# ---- restart calico ----
restart_calico() {
  log "Restarting calico-node"
  sudo k0s kubectl rollout restart daemonset/calico-node -n kube-system || true
}

# ---- wait for node ----
wait_for_node() {
  log "Waiting for node registration"

  until sudo k0s kubectl get nodes 2>/dev/null | grep -q "$(hostname)"; do
    sleep 2
  done

  log "Node registered"
}

# ---- main ----

log "=== BUILD START ==="

ensure_containerd
ensure_cni_dirs
generate_config
install_k0s
wait_for_api
wait_for_node
install_calico

# give calico CRDs time to appear
sleep 5

ensure_ippool
ensure_ipam
restart_calico

log "Final state:"
sudo k0s kubectl get nodes -o wide || true
sudo k0s kubectl get pods -n kube-system || true

log "=== DONE ==="
