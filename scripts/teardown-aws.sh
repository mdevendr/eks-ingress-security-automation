#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/lib.sh"
load_config "${1:-}"
ACCOUNT_ID="$(aws_cli sts get-caller-identity --query Account --output text)"
SCHEDULE="eks-secure-alb-reconcile-${RUN_ID}"
RULE_NAME="eks-secure-alb-lifecycle-${RUN_ID}"
GAP_NAME="eks-secure-alb-gap-${RUN_ID}"
RECON_NAME="eks-secure-alb-reconcile-${RUN_ID}"
SCHEDULER_ROLE="EksSecureAlbSchedulerRole-${RUN_ID}"
ROLE_NAME="EksSecureAlbLambdaRole-${RUN_ID}"
POLICY_ARN="arn:aws:iam::${ACCOUNT_ID}:policy/EksSecureAlbLambdaPolicy-${RUN_ID}"
DLQ_NAME="eks-secure-alb-dlq-${RUN_ID}"
SAFE_RUN_ID="$(tr '[:upper:]_' '[:lower:]-' <<<"$RUN_ID" | tr -cd 'a-z0-9-')"
TRAIL_NAME="eks-secure-alb-${RUN_ID}"
TRAIL_BUCKET="eks-secure-alb-trail-${ACCOUNT_ID}-${AWS_REGION}-${SAFE_RUN_ID}"

aws_cli scheduler delete-schedule --name "$SCHEDULE" 2>/dev/null || true
aws_cli events remove-targets --rule "$RULE_NAME" --ids gap-filler 2>/dev/null || true
aws_cli events delete-rule --name "$RULE_NAME" 2>/dev/null || true
aws_cli lambda delete-function --function-name "$GAP_NAME" 2>/dev/null || true
aws_cli lambda delete-function --function-name "$RECON_NAME" 2>/dev/null || true
aws_cli iam delete-role-policy --role-name "$SCHEDULER_ROLE" --policy-name InvokeReconciler 2>/dev/null || true
aws_cli iam delete-role --role-name "$SCHEDULER_ROLE" 2>/dev/null || true
aws_cli iam detach-role-policy --role-name "$ROLE_NAME" --policy-arn "$POLICY_ARN" 2>/dev/null || true
aws_cli iam delete-role --role-name "$ROLE_NAME" 2>/dev/null || true
for version in $(aws_cli iam list-policy-versions --policy-arn "$POLICY_ARN" --query "Versions[?IsDefaultVersion==\`false\`].VersionId" --output text 2>/dev/null || true); do
  aws_cli iam delete-policy-version --policy-arn "$POLICY_ARN" --version-id "$version"
done
aws_cli iam delete-policy --policy-arn "$POLICY_ARN" 2>/dev/null || true
DLQ_URL="$(aws_cli sqs get-queue-url --queue-name "$DLQ_NAME" --query QueueUrl --output text 2>/dev/null || true)"
[[ -z "$DLQ_URL" ]] || aws_cli sqs delete-queue --queue-url "$DLQ_URL"
aws_cli dynamodb delete-table --table-name "EksSecureAlbInventory-${RUN_ID}" >/dev/null 2>&1 || true
aws_cli cloudtrail stop-logging --name "$TRAIL_NAME" 2>/dev/null || true
aws_cli cloudtrail delete-trail --name "$TRAIL_NAME" 2>/dev/null || true
if aws_cli s3api head-bucket --bucket "$TRAIL_BUCKET" >/dev/null 2>&1; then
  aws --profile "$AWS_PROFILE" s3 rm "s3://$TRAIL_BUCKET" --recursive
  aws_cli s3api delete-bucket --bucket "$TRAIL_BUCKET"
fi
