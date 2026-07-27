#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/../../scripts/lib.sh"
load_config "${1:-}"
kubectl apply -f "$ROOT_DIR/shared/kubernetes/demo-workload.yaml"
kubectl rollout status deployment/demo -n secure-alb-demo --timeout=3m
RENDERED="$(mktemp)"
trap 'rm -f "$RENDERED"' EXIT
sed "s|__RUN_ID__|$RUN_ID|g" "$ROOT_DIR/stages/00-ingress/kubernetes/ingress.yaml.tpl" >"$RENDERED"
kubectl apply -f "$RENDERED"
kubectl get ingress -n secure-alb-demo -o wide
