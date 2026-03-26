#!/usr/bin/env bash
set -euo pipefail

echo ""
echo "===== NODES ====="
sudo k0s kubectl get nodes -o wide || true

echo ""
echo "===== SYSTEM PODS ====="
sudo k0s kubectl get pods -n kube-system -o wide || true

echo ""
echo "===== ALL PODS ====="
sudo k0s kubectl get pods -A -o wide || true

echo ""
echo "===== CALICO ====="
sudo k0s kubectl get ippool 2>/dev/null || true
sudo k0s kubectl get ipamconfigs 2>/dev/null || true

echo ""
echo "===== SERVICES ====="
sudo k0s kubectl get svc -A || true

echo ""
echo "===== KUBELET PROCESS ====="
ps aux | grep kubelet | grep -v grep || true

echo ""
echo "===== CONTAINERD ====="
sudo systemctl status containerd --no-pager || true

echo ""
echo "===== API HEALTH ====="
sudo k0s kubectl get --raw=/healthz || true

echo ""
echo "===== END ====="
