#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/../../scripts/lib.sh"
mkdir -p "$ROOT_DIR/.build"
if kubectl apply -f - >/dev/null 2>"$ROOT_DIR/.build/stage-1-admission-error.txt" <<'EOF'
apiVersion: gateway.k8s.aws/v1
kind: LoadBalancerConfiguration
metadata:
  name: insecure-test
  namespace: secure-alb-demo
spec:
  scheme: internet-facing
EOF
then
  kubectl delete loadbalancerconfigurations.gateway.k8s.aws insecure-test -n secure-alb-demo --ignore-not-found
  echo "ERROR: insecure LoadBalancerConfiguration was admitted" >&2
  exit 1
fi
echo "PASS: admission policy rejected a LoadBalancerConfiguration without WAF and access logging"
cat "$ROOT_DIR/.build/stage-1-admission-error.txt"
