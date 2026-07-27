#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/../../scripts/lib.sh"
load_config "${1:-}"
kubectl delete securealb demo -n secure-alb-demo --ignore-not-found --wait=true --timeout=15m
kubectl delete -f "$ROOT_DIR/stages/02-kro/kubernetes/secure-alb-rgd.yaml" --ignore-not-found
