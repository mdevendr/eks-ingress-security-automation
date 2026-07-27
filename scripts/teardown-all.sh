#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/lib.sh"
CONFIG_FILE="${1:-$ROOT_DIR/config/lab.env}"
load_config "$CONFIG_FILE"
CONFIRMATION="${2:-}"
[[ "$CONFIRMATION" == "$RUN_ID" ]] || { echo "Refusing teardown. Pass RUN_ID as the second argument: $RUN_ID" >&2; exit 2; }

"$ROOT_DIR/stages/02-kro/teardown.sh" "$CONFIG_FILE" || true
"$ROOT_DIR/stages/01-gateway-api/teardown.sh" "$CONFIG_FILE" || true
"$ROOT_DIR/stages/00-ingress/teardown.sh" "$CONFIG_FILE" || true
kubectl delete -f "$ROOT_DIR/shared/kubernetes/demo-workload.yaml" --ignore-not-found || true
kubectl delete -f "$ROOT_DIR/shared/kubernetes/admission-policy.yaml" --ignore-not-found || true
kubectl delete -f "$ROOT_DIR/shared/kubernetes/platform.yaml" --ignore-not-found || true

aws_cli eks delete-capability --cluster-name "$CLUSTER_NAME" --capability-name secure-alb-kro 2>/dev/null || true
aws_cli eks delete-capability --cluster-name "$CLUSTER_NAME" --capability-name secure-alb-ack 2>/dev/null || true
"$ROOT_DIR/scripts/teardown-aws.sh" "$CONFIG_FILE"
eksctl delete cluster --name "$CLUSTER_NAME" --region "$AWS_REGION" --profile "$AWS_PROFILE" --wait

ACCOUNT_ID="$(aws_cli sts get-caller-identity --query Account --output text)"
aws_cli iam delete-policy --policy-arn "arn:aws:iam::${ACCOUNT_ID}:policy/EksSecureAlbExternalDns-${RUN_ID}" 2>/dev/null || true
for role in "EksKroCapabilityRole-${RUN_ID}" "EksAckCapabilityRole-${RUN_ID}"; do
  aws_cli iam delete-role-policy --role-name "$role" --policy-name Route53HealthChecks 2>/dev/null || true
  aws_cli iam delete-role --role-name "$role" 2>/dev/null || true
done
echo "Teardown completed for $RUN_ID"
