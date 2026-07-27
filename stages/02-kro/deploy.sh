#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/../../scripts/lib.sh"
load_config "${1:-}"
kubectl apply -f "$ROOT_DIR/shared/kubernetes/platform.yaml"
kubectl apply -f "$ROOT_DIR/shared/kubernetes/admission-policy.yaml"
kubectl apply -f "$ROOT_DIR/shared/kubernetes/demo-workload.yaml"
kubectl rollout status deployment/demo -n secure-alb-demo --timeout=3m
CATALOG="$(mktemp)"
INSTANCE="$(mktemp)"
trap 'rm -f "$CATALOG" "$INSTANCE"' EXIT
sed "s|__WEB_ACL_ARN__|$WEB_ACL_ARN|g" "$ROOT_DIR/stages/02-kro/kubernetes/waf-policy-catalog.yaml.tpl" >"$CATALOG"
kubectl apply -f "$CATALOG"
kubectl apply -f "$ROOT_DIR/stages/02-kro/kubernetes/rbac.yaml"
if [[ "${PUBLIC_DNS_ENABLED:-true}" == "true" ]]; then
  RGD="$ROOT_DIR/stages/02-kro/kubernetes/secure-alb-rgd.yaml"
  INSTANCE_TEMPLATE="$ROOT_DIR/stages/02-kro/kubernetes/secure-alb-instance.yaml.tpl"
else
  RGD="$ROOT_DIR/stages/02-kro/kubernetes/secure-alb-rgd-http-evidence.yaml"
  INSTANCE_TEMPLATE="$ROOT_DIR/stages/02-kro/kubernetes/secure-alb-instance-http-evidence.yaml.tpl"
fi
kubectl apply -f "$RGD"
kubectl wait --for=condition=GraphAccepted resourcegraphdefinition/secure-alb --timeout=3m
sed -e "s|__HOSTNAME__|$HOSTNAME|g" \
    -e "s|__CERTIFICATE_ARN__|$ACM_CERTIFICATE_ARN|g" \
    -e "s|__ACCESS_LOG_BUCKET__|$ALB_LOG_BUCKET|g" \
    "$INSTANCE_TEMPLATE" >"$INSTANCE"
kubectl apply -f "$INSTANCE"
kubectl wait --for=condition=Ready securealb/demo -n secure-alb-demo --timeout=15m || true
kubectl get securealb,gateways.gateway.networking.k8s.io,httproutes.gateway.networking.k8s.io,loadbalancerconfigurations.gateway.k8s.aws,targetgroupconfigurations.gateway.k8s.aws,healthchecks.route53.services.k8s.aws -n secure-alb-demo -o wide
