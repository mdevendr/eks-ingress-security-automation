#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/lib.sh"
load_config "${1:-}"
STAGE="${2:-1}"
TABLE_NAME="EksSecureAlbInventory-${RUN_ID}"
RECON_NAME="eks-secure-alb-reconcile-${RUN_ID}"

if kubectl get ingress demo -n secure-alb-demo >/dev/null 2>&1; then
  kubectl get ingress demo -n secure-alb-demo -o wide
else
  kubectl get gateways.gateway.networking.k8s.io demo -n secure-alb-demo -o jsonpath='{range .status.conditions[*]}{.type}={.status}{"\n"}{end}'
fi
ALB_ARN=""
for _ in {1..60}; do
  ALB_ARN="$(aws_cli elbv2 describe-load-balancers --query "LoadBalancers[?contains(DNSName, '')].LoadBalancerArn | [0]" --output text 2>/dev/null || true)"
  ALB_ARN="$(aws_cli resourcegroupstaggingapi get-resources --resource-type-filters elasticloadbalancing:loadbalancer --tag-filters Key=secure-alb/id,Values=secure-alb-demo/demo --query 'ResourceTagMappingList[0].ResourceARN' --output text 2>/dev/null || true)"
  [[ -n "$ALB_ARN" && "$ALB_ARN" != "None" ]] && break
  sleep 10
done
[[ -n "$ALB_ARN" && "$ALB_ARN" != "None" ]] || { echo "ALB was not discovered" >&2; exit 1; }

aws_cli elbv2 describe-load-balancers --load-balancer-arns "$ALB_ARN"
if [[ "$STAGE" != "0" ]]; then
  aws_cli wafv2 get-web-acl-for-resource --resource-arn "$ALB_ARN"
else
  echo "Stage 0 WAF/Shield/DNS checks: NOT REQUIRED; proving ALB lifecycle EDA."
fi
if [[ "${SHIELD_ADVANCED_ENABLED:-false}" == "true" ]]; then
  aws_cli shield list-protections --query "Protections[?ResourceArn=='$ALB_ARN']"
else
  echo 'Shield Advanced: NOT EXECUTED (low-cost evidence mode; Shield Standard remains automatic)'
fi

for _ in {1..30}; do
  ITEM="$(aws_cli dynamodb get-item --table-name "$TABLE_NAME" --key "{\"ALBArn\":{\"S\":\"$ALB_ARN\"}}" --query Item --output json)"
  [[ "$ITEM" != "null" && "$ITEM" != "{}" ]] && break
  sleep 10
done
echo "$ITEM"
RESULT_FILE="$ROOT_DIR/.build/reconciliation-result.json"
aws_cli lambda invoke --function-name "$RECON_NAME" --payload '{}' "$(native_path "$RESULT_FILE")" >/dev/null
cat "$RESULT_FILE"
