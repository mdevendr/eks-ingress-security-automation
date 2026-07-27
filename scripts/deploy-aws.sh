#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/lib.sh"
load_config "${1:-}"
STAGE="${2:-1}"
REQUIRE_HEALTH_CHECK=true
[[ "$STAGE" == "0" || "${PUBLIC_DNS_ENABLED:-true}" != "true" ]] && REQUIRE_HEALTH_CHECK=false
"$ROOT_DIR/scripts/package-functions.sh" >/dev/null

ACCOUNT_ID="$(aws_cli sts get-caller-identity --query Account --output text)"
TABLE_NAME="EksSecureAlbInventory-${RUN_ID}"
GAP_NAME="eks-secure-alb-gap-${RUN_ID}"
RECON_NAME="eks-secure-alb-reconcile-${RUN_ID}"
ROLE_NAME="EksSecureAlbLambdaRole-${RUN_ID}"
POLICY_NAME="EksSecureAlbLambdaPolicy-${RUN_ID}"
DLQ_NAME="eks-secure-alb-dlq-${RUN_ID}"
SCHEDULER_ROLE="EksSecureAlbSchedulerRole-${RUN_ID}"
SAFE_RUN_ID="$(tr '[:upper:]_' '[:lower:]-' <<<"$RUN_ID" | tr -cd 'a-z0-9-')"
TRAIL_NAME="eks-secure-alb-${RUN_ID}"
TRAIL_BUCKET="eks-secure-alb-trail-${ACCOUNT_ID}-${AWS_REGION}-${SAFE_RUN_ID}"

if ! aws_cli s3api head-bucket --bucket "$TRAIL_BUCKET" >/dev/null 2>&1; then
  if [[ "$AWS_REGION" == "us-east-1" ]]; then
    aws_cli s3api create-bucket --bucket "$TRAIL_BUCKET" >/dev/null
  else
    aws_cli s3api create-bucket --bucket "$TRAIL_BUCKET" --create-bucket-configuration "LocationConstraint=$AWS_REGION" >/dev/null
  fi
fi
aws_cli s3api put-public-access-block --bucket "$TRAIL_BUCKET" --public-access-block-configuration BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
TRAIL_POLICY="{\"Version\":\"2012-10-17\",\"Statement\":[{\"Sid\":\"CloudTrailAclCheck\",\"Effect\":\"Allow\",\"Principal\":{\"Service\":\"cloudtrail.amazonaws.com\"},\"Action\":\"s3:GetBucketAcl\",\"Resource\":\"arn:aws:s3:::$TRAIL_BUCKET\"},{\"Sid\":\"CloudTrailWrite\",\"Effect\":\"Allow\",\"Principal\":{\"Service\":\"cloudtrail.amazonaws.com\"},\"Action\":\"s3:PutObject\",\"Resource\":\"arn:aws:s3:::$TRAIL_BUCKET/AWSLogs/$ACCOUNT_ID/*\",\"Condition\":{\"StringEquals\":{\"s3:x-amz-acl\":\"bucket-owner-full-control\"}}}]}"
aws_cli s3api put-bucket-policy --bucket "$TRAIL_BUCKET" --policy "$TRAIL_POLICY"
if aws_cli cloudtrail get-trail --name "$TRAIL_NAME" >/dev/null 2>&1; then
  aws_cli cloudtrail update-trail --name "$TRAIL_NAME" --s3-bucket-name "$TRAIL_BUCKET" --no-is-multi-region-trail >/dev/null
else
  aws_cli cloudtrail create-trail --name "$TRAIL_NAME" --s3-bucket-name "$TRAIL_BUCKET" --no-is-multi-region-trail >/dev/null
fi
aws_cli cloudtrail start-logging --name "$TRAIL_NAME"

if ! aws_cli dynamodb describe-table --table-name "$TABLE_NAME" >/dev/null 2>&1; then
  aws_cli dynamodb create-table --table-name "$TABLE_NAME" \
    --attribute-definitions AttributeName=ALBArn,AttributeType=S \
    --key-schema AttributeName=ALBArn,KeyType=HASH --billing-mode PAY_PER_REQUEST >/dev/null
  aws_cli dynamodb wait table-exists --table-name "$TABLE_NAME"
fi
TABLE_ARN="$(aws_cli dynamodb describe-table --table-name "$TABLE_NAME" --query Table.TableArn --output text)"

TRUST='{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"lambda.amazonaws.com"},"Action":"sts:AssumeRole"}]}'
aws_cli iam get-role --role-name "$ROLE_NAME" >/dev/null 2>&1 || aws_cli iam create-role --role-name "$ROLE_NAME" --assume-role-policy-document "$TRUST" >/dev/null
POLICY_DOC="$(sed "s|DDB_TABLE_ARN|$TABLE_ARN|g" "$ROOT_DIR/shared/iam/lambda-policy.json")"
POLICY_ARN="arn:aws:iam::${ACCOUNT_ID}:policy/${POLICY_NAME}"
if aws_cli iam get-policy --policy-arn "$POLICY_ARN" >/dev/null 2>&1; then
  VERSION="$(aws_cli iam create-policy-version --policy-arn "$POLICY_ARN" --policy-document "$POLICY_DOC" --set-as-default --query PolicyVersion.VersionId --output text)"
  for old in $(aws_cli iam list-policy-versions --policy-arn "$POLICY_ARN" --query "Versions[?IsDefaultVersion==\`false\`].VersionId" --output text); do
    aws_cli iam delete-policy-version --policy-arn "$POLICY_ARN" --version-id "$old"
  done
else
  aws_cli iam create-policy --policy-name "$POLICY_NAME" --policy-document "$POLICY_DOC" >/dev/null
fi
aws_cli iam attach-role-policy --role-name "$ROLE_NAME" --policy-arn "$POLICY_ARN"
ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${ROLE_NAME}"

DLQ_URL="$(aws_cli sqs get-queue-url --queue-name "$DLQ_NAME" --query QueueUrl --output text 2>/dev/null || aws_cli sqs create-queue --queue-name "$DLQ_NAME" --attributes MessageRetentionPeriod=1209600 --query QueueUrl --output text)"
DLQ_ARN="$(aws_cli sqs get-queue-attributes --queue-url "$DLQ_URL" --attribute-names QueueArn --query Attributes.QueueArn --output text)"
QUEUE_POLICY="{\"Version\":\"2012-10-17\",\"Statement\":[{\"Sid\":\"EventBridgeAndScheduler\",\"Effect\":\"Allow\",\"Principal\":{\"Service\":[\"events.amazonaws.com\",\"scheduler.amazonaws.com\"]},\"Action\":\"sqs:SendMessage\",\"Resource\":\"$DLQ_ARN\",\"Condition\":{\"StringEquals\":{\"aws:SourceAccount\":\"$ACCOUNT_ID\"}}}]}"
ESCAPED_QUEUE_POLICY="${QUEUE_POLICY//\"/\\\"}"
QUEUE_ATTRIBUTES="{\"Policy\":\"$ESCAPED_QUEUE_POLICY\"}"
QUEUE_ATTRIBUTES_FILE="$(mktemp)"
printf '%s' "$QUEUE_ATTRIBUTES" >"$QUEUE_ATTRIBUTES_FILE"
aws_cli sqs set-queue-attributes --queue-url "$DLQ_URL" --attributes "file://$(native_path "$QUEUE_ATTRIBUTES_FILE")"
rm -f "$QUEUE_ATTRIBUTES_FILE"

sleep 8
upsert_lambda() {
  local name="$1" zip="$2" handler="$3" mode="$4"
  local zip_native
  zip_native="$(native_path "$zip")"
  if aws_cli lambda get-function --function-name "$name" >/dev/null 2>&1; then
    aws_cli lambda update-function-code --function-name "$name" --zip-file "fileb://$zip_native" >/dev/null
    aws_cli lambda wait function-updated --function-name "$name"
    aws_cli lambda update-function-configuration --function-name "$name" --role "$ROLE_ARN" --runtime python3.13 --handler "$handler" --timeout 120 --memory-size 256 \
      --environment "Variables={DDB_TABLE=$TABLE_NAME,MODE=$mode,LOG_LEVEL=INFO,SHIELD_ADVANCED_ENABLED=${SHIELD_ADVANCED_ENABLED:-false},REQUIRE_HEALTH_CHECK=$REQUIRE_HEALTH_CHECK}" --dead-letter-config "TargetArn=$DLQ_ARN" --tracing-config Mode=Active >/dev/null
  else
    aws_cli lambda create-function --function-name "$name" --role "$ROLE_ARN" --runtime python3.13 --handler "$handler" --timeout 120 --memory-size 256 \
      --zip-file "fileb://$zip_native" --environment "Variables={DDB_TABLE=$TABLE_NAME,MODE=$mode,LOG_LEVEL=INFO,SHIELD_ADVANCED_ENABLED=${SHIELD_ADVANCED_ENABLED:-false},REQUIRE_HEALTH_CHECK=$REQUIRE_HEALTH_CHECK}" --dead-letter-config "TargetArn=$DLQ_ARN" --tracing-config Mode=Active >/dev/null
  fi
  aws_cli lambda wait function-active-v2 --function-name "$name"
}
upsert_lambda "$GAP_NAME" "$ROOT_DIR/.build/gap-filler.zip" lambda_function.lambda_handler AUDIT
upsert_lambda "$RECON_NAME" "$ROOT_DIR/.build/reconciler.zip" lambda_function.lambda_handler "${RECONCILIATION_MODE:-AUDIT}"
GAP_ARN="$(aws_cli lambda get-function --function-name "$GAP_NAME" --query Configuration.FunctionArn --output text)"
RECON_ARN="$(aws_cli lambda get-function --function-name "$RECON_NAME" --query Configuration.FunctionArn --output text)"

RULE_NAME="eks-secure-alb-lifecycle-${RUN_ID}"
PATTERN='{"source":["aws.elasticloadbalancing"],"detail-type":["AWS API Call via CloudTrail"],"detail":{"eventSource":["elasticloadbalancing.amazonaws.com"],"eventName":["CreateLoadBalancer","DeleteLoadBalancer"]}}'
RULE_ARN="$(aws_cli events put-rule --name "$RULE_NAME" --event-pattern "$PATTERN" --state ENABLED --query RuleArn --output text)"
aws_cli lambda add-permission --function-name "$GAP_NAME" --statement-id "eventbridge-${RUN_ID}" --action lambda:InvokeFunction --principal events.amazonaws.com --source-arn "$RULE_ARN" >/dev/null 2>&1 || true
aws_cli events put-targets --rule "$RULE_NAME" --targets "Id=gap-filler,Arn=$GAP_ARN,DeadLetterConfig={Arn=$DLQ_ARN}" >/dev/null

SCHED_TRUST='{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"scheduler.amazonaws.com"},"Action":"sts:AssumeRole"}]}'
aws_cli iam get-role --role-name "$SCHEDULER_ROLE" >/dev/null 2>&1 || aws_cli iam create-role --role-name "$SCHEDULER_ROLE" --assume-role-policy-document "$SCHED_TRUST" >/dev/null
SCHED_ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${SCHEDULER_ROLE}"
SCHED_POLICY="{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Action\":\"lambda:InvokeFunction\",\"Resource\":\"$RECON_ARN\"},{\"Effect\":\"Allow\",\"Action\":\"sqs:SendMessage\",\"Resource\":\"$DLQ_ARN\"}]}"
aws_cli iam put-role-policy --role-name "$SCHEDULER_ROLE" --policy-name InvokeReconciler --policy-document "$SCHED_POLICY"
sleep 5
SCHEDULE="eks-secure-alb-reconcile-${RUN_ID}"
TARGET="{\"Arn\":\"$RECON_ARN\",\"RoleArn\":\"$SCHED_ROLE_ARN\",\"Input\":\"{}\",\"DeadLetterConfig\":{\"Arn\":\"$DLQ_ARN\"},\"RetryPolicy\":{\"MaximumEventAgeInSeconds\":300,\"MaximumRetryAttempts\":2}}"
if aws_cli scheduler get-schedule --name "$SCHEDULE" >/dev/null 2>&1; then
  aws_cli scheduler update-schedule --name "$SCHEDULE" --schedule-expression 'rate(5 minutes)' --flexible-time-window Mode=OFF --target "$TARGET" --state ENABLED >/dev/null
else
  aws_cli scheduler create-schedule --name "$SCHEDULE" --schedule-expression 'rate(5 minutes)' --flexible-time-window Mode=OFF --target "$TARGET" --state ENABLED >/dev/null
fi

echo "TABLE_NAME=$TABLE_NAME"
echo "GAP_FUNCTION=$GAP_NAME"
echo "RECONCILER_FUNCTION=$RECON_NAME"
echo "CLOUDTRAIL=$TRAIL_NAME"
