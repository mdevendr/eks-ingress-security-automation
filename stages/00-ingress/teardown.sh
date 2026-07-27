#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/../../scripts/lib.sh"
load_config "${1:-}"
kubectl delete ingress demo -n secure-alb-demo --ignore-not-found --wait=true
