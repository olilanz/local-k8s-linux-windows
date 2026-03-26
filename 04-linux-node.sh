#!/usr/bin/env bash
set -euo pipefail

log() { echo -e "\n[$(date +%H:%M:%S)] $*"; }
fail() { echo "ERROR: $*" >&2; exit 1; }

NODE_NAME="$(hostname -s)"
WORKER_TOKEN_FILE="/tmp/k0s-worker-token"

dump_diagnostics() {
  log "==== Diagnostics: nodes ===="
  sudo k0s kubectl get nodes -o wide || true

  log "==== Diagnostics: kube-system pods ===="
  sudo k0s kubectl get pods -n kube-system -o wide || true

  log "==== Diagnostics: recent events ===="
  sudo k0s kubectl get events -A --sort-by=.lastTimestamp | tail -n 80 || true

  log "==== Diagnostics: k0sworker service ===="
  sudo systemctl status k0sworker --no-pager || true
  sudo journalctl -u k0sworker -n 120 --no-pager || true

  local calico_pod
  calico_pod="$(
    sudo k0s kubectl get pods -n kube-system \
      --field-selector "spec.nodeName=${NODE_NAME}" \
      -l k8s-app=calico-node \
      -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true
  )"

  if [[ -n "${calico_pod}" ]]; then
    log "==== Diagnostics: calico-node describe (${calico_pod}) ===="
    sudo k0s kubectl describe pod -n kube-system "${calico_pod}" || true

    log "==== Diagnostics: calico-node logs (${calico_pod}) ===="
    sudo k0s kubectl logs -n kube-system "${calico_pod}" --all-containers=true || true

    log "==== Diagnostics: calico-node previous logs (${calico_pod}) ===="
    sudo k0s kubectl logs -n kube-system "${calico_pod}" --all-containers=true --previous || true
  fi

  local konnectivity_pod
  konnectivity_pod="$(
    sudo k0s kubectl get pods -n kube-system \
      --field-selector "spec.nodeName=${NODE_NAME}" \
      -l app=konnectivity-agent \
      -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true
  )"

  if [[ -n "${konnectivity_pod}" ]]; then
    log "==== Diagnostics: konnectivity-agent describe (${konnectivity_pod}) ===="
    sudo k0s kubectl describe pod -n kube-system "${konnectivity_pod}" || true

    log "==== Diagnostics: konnectivity-agent logs (${konnectivity_pod}) ===="
    sudo k0s kubectl logs -n kube-system "${konnectivity_pod}" --all-containers=true || true
  fi
}

trap 'dump_diagnostics' ERR

log "Checking API availability"
sudo k0s kubectl get --raw=/healthz >/dev/null 2>&1 \
  || fail "API server not reachable. Run 02-cluster.sh first."

log "Checking Calico CRDs"
sudo k0s kubectl get crd ippools.crd.projectcalico.org >/dev/null 2>&1 \
  || fail "Calico CRDs not found. Run 03-network.sh first."

log "Checking Calico daemonset exists"
sudo k0s kubectl get daemonset calico-node -n kube-system >/dev/null 2>&1 \
  || fail "calico-node daemonset not found. Run 03-network.sh first."

log "Removing existing worker service (if any)"
sudo systemctl stop k0sworker 2>/dev/null || true
sudo systemctl disable k0sworker 2>/dev/null || true
sudo rm -f /etc/systemd/system/k0sworker.service
sudo systemctl daemon-reexec
sudo systemctl daemon-reload

log "Cleaning previous local worker state"
sudo rm -f "${WORKER_TOKEN_FILE}"
sudo rm -rf /var/lib/k0s/kubelet
sudo rm -rf /etc/k0s/kubelet.conf
sudo rm -rf /var/lib/kubelet
sudo mkdir -p /var/lib/kubelet

log "Creating worker token"
sudo k0s token create --role=worker > "${WORKER_TOKEN_FILE}"
sudo chmod 600 "${WORKER_TOKEN_FILE}"

log "Installing worker"
sudo k0s install worker --token-file "${WORKER_TOKEN_FILE}"

log "Starting worker service"
sudo systemctl start k0sworker

log "Ensuring worker service is active"
sudo systemctl is-active --quiet k0sworker \
  || fail "k0sworker service failed to start"

log "Waiting for node object registration: ${NODE_NAME}"
for i in {1..90}; do
  if sudo k0s kubectl get node "${NODE_NAME}" >/dev/null 2>&1; then
    log "Node object exists"
    break
  fi
  sleep 2
done
sudo k0s kubectl get node "${NODE_NAME}" >/dev/null 2>&1 \
  || fail "Node object was not registered"

log "Waiting for node Ready condition: ${NODE_NAME}"
for i in {1..120}; do
  node_ready="$(
    sudo k0s kubectl get node "${NODE_NAME}" \
      -o jsonpath='{range .status.conditions[?(@.type=="Ready")]}{.status}{end}' 2>/dev/null || true
  )"
  if [[ "${node_ready}" == "True" ]]; then
    log "Node is Ready"
    sudo k0s kubectl get node "${NODE_NAME}" -o wide
    break
  fi
  sleep 2
done
[[ "${node_ready:-}" == "True" ]] || fail "Node did not become Ready"

log "Waiting for calico-node pod to be scheduled on ${NODE_NAME}"
for i in {1..90}; do
  calico_pod="$(
    sudo k0s kubectl get pods -n kube-system \
      --field-selector "spec.nodeName=${NODE_NAME}" \
      -l k8s-app=calico-node \
      -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true
  )"
  if [[ -n "${calico_pod}" ]]; then
    log "Calico pod detected: ${calico_pod}"
    break
  fi
  sleep 2
done
[[ -n "${calico_pod:-}" ]] || fail "No calico-node pod was scheduled on ${NODE_NAME}"

log "Waiting for calico-node Ready condition on ${NODE_NAME}"
for i in {1..150}; do
  calico_ready="$(
    sudo k0s kubectl get pod -n kube-system "${calico_pod}" \
      -o jsonpath='{range .status.conditions[?(@.type=="Ready")]}{.status}{end}' 2>/dev/null || true
  )"
  calico_phase="$(
    sudo k0s kubectl get pod -n kube-system "${calico_pod}" \
      -o jsonpath='{.status.phase}' 2>/dev/null || true
  )"
  if [[ "${calico_ready}" == "True" ]]; then
    log "calico-node is Ready on ${NODE_NAME}"
    sudo k0s kubectl get pods -n kube-system -o wide
    break
  fi
  echo "Waiting: calico pod=${calico_pod} phase=${calico_phase:-unknown} ready=${calico_ready:-unknown}"
  sleep 2
done
[[ "${calico_ready:-}" == "True" ]] || fail "calico-node did not become Ready on ${NODE_NAME}"

log "Waiting for calico-kube-controllers deployment to become Available"
sudo k0s kubectl wait \
  --for=condition=Available \
  deployment/calico-kube-controllers \
  -n kube-system \
  --timeout=180s

log "Waiting for konnectivity-agent pod on ${NODE_NAME} to become Ready"
konnectivity_pod="$(
  sudo k0s kubectl get pods -n kube-system \
    --field-selector "spec.nodeName=${NODE_NAME}" \
    -l app=konnectivity-agent \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true
)"

if [[ -n "${konnectivity_pod}" ]]; then
  sudo k0s kubectl wait \
    --for=condition=Ready \
    "pod/${konnectivity_pod}" \
    -n kube-system \
    --timeout=180s
fi

log "Linux worker installation complete"
sudo k0s kubectl get nodes -o wide
sudo k0s kubectl get pods -n kube-system -o wide
