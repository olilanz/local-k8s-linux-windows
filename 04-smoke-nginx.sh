#!/usr/bin/env bash
set -euo pipefail

log() { echo -e "\n[$(date +%H:%M:%S)] $*"; }

log "Deploying nginx"
sudo k0s kubectl delete deployment nginx 2>/dev/null || true
sudo k0s kubectl delete svc nginx 2>/dev/null || true

sudo k0s kubectl create deployment nginx --image=nginx
sudo k0s kubectl expose deployment nginx --port=80 --type=ClusterIP

log "Waiting for pod"
sudo k0s kubectl rollout status deployment/nginx --timeout=120s

log "Testing connectivity"
sudo k0s kubectl run curl --rm -it --image=curlimages/curl --restart=Never -- \
  curl -s http://nginx | head -n 5

log "nginx test complete"
