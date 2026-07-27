#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/lib.sh"
load_config "${1:-}"
if [[ "${SHIELD_ADVANCED_ENABLED:-false}" != "true" ]]; then
  echo "Shield health-check drift test: NOT EXECUTED (Shield Advanced disabled)."
  exit 0
fi
TABLE_NAME="EksSecureAlbInventory-${RUN_ID}"
RECON_NAME="eks-secure-alb-reconcile-${RUN_ID}"
ALB_ARN="$(aws_cli resourcegroupstaggingapi get-resources --resource-type-filters elasticloadbalancing:loadbalancer --tag-filters Key=secure-alb/id,Values=secure-alb-demo/demo --query 'ResourceTagMappingList[0].ResourceARN' --output text)"
PROTECTION_ID="$(aws_cli dynamodb get-item --table-name "$TABLE_NAME" --key "{\"ALBArn\":{\"S\":\"$ALB_ARN\"}}" --query 'Item.ProtectionId.S' --output text)"
HEALTH_CHECK_ID="$(aws_cli dynamodb get-item --table-name "$TABLE_NAME" --key "{\"ALBArn\":{\"S\":\"$ALB_ARN\"}}" --query 'Item.HealthCheckId.S' --output text)"
HEALTH_ARN="arn:aws:route53:::healthcheck/${HEALTH_CHECK_ID}"
aws_cli shield disassociate-health-check --protection-id "$PROTECTION_ID" --health-check-arn "$HEALTH_ARN"
RESULT_FILE="$ROOT_DIR/.build/drift-result.json"
aws_cli lambda invoke --function-name "$RECON_NAME" --payload '{}' "$(native_path "$RESULT_FILE")" >/dev/null
cat "$RESULT_FILE"
aws_cli shield describe-protection --protection-id "$PROTECTION_ID" --query Protection.HealthCheckIds
