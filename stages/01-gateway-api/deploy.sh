#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/../../scripts/lib.sh"
load_config "${1:-}"
kubectl apply -f "$ROOT_DIR/shared/kubernetes/platform.yaml"
kubectl apply -f "$ROOT_DIR/shared/kubernetes/admission-policy.yaml"
kubectl apply -f "$ROOT_DIR/shared/kubernetes/demo-workload.yaml"
kubectl rollout status deployment/demo -n secure-alb-demo --timeout=3m
RENDERED="$(mktemp)"
trap 'rm -f "$RENDERED"' EXIT
if [[ "${PUBLIC_DNS_ENABLED:-true}" == "true" ]]; then
  TEMPLATE="$ROOT_DIR/stages/01-gateway-api/kubernetes/gateway-api.yaml.tpl"
else
  TEMPLATE="$ROOT_DIR/stages/01-gateway-api/kubernetes/gateway-api-http-evidence.yaml.tpl"
fi
sed -e "s|__HOSTNAME__|$HOSTNAME|g" \
    -e "s|__WEB_ACL_ARN__|$WEB_ACL_ARN|g" \
    -e "s|__CERTIFICATE_ARN__|$ACM_CERTIFICATE_ARN|g" \
    -e "s|__ACCESS_LOG_BUCKET__|$ALB_LOG_BUCKET|g" \
    -e "s|__RUN_ID__|$RUN_ID|g" "$TEMPLATE" >"$RENDERED"
kubectl apply -f "$RENDERED"
kubectl get gateways.gateway.networking.k8s.io,httproutes.gateway.networking.k8s.io,loadbalancerconfigurations.gateway.k8s.aws,targetgroupconfigurations.gateway.k8s.aws -n secure-alb-demo -o wide
[[ "${PUBLIC_DNS_ENABLED:-true}" != "true" ]] || kubectl get healthcheck -n secure-alb-demo -o wide
