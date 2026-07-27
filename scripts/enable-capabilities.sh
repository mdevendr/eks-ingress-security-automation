#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/lib.sh"
load_config "${1:-}"
CAPABILITY_SET="${2:-ALL}"
ACCOUNT_ID="$(aws_cli sts get-caller-identity --query Account --output text)"
TRUST='{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"capabilities.eks.amazonaws.com"},"Action":["sts:AssumeRole","sts:TagSession"]}]}'

ACK_ROLE="EksAckCapabilityRole-${RUN_ID}"
ACK_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${ACK_ROLE}"
aws_cli iam get-role --role-name "$ACK_ROLE" >/dev/null 2>&1 || aws_cli iam create-role --role-name "$ACK_ROLE" --assume-role-policy-document "$TRUST" >/dev/null
aws_cli iam update-assume-role-policy --role-name "$ACK_ROLE" --policy-document "$TRUST"
ACK_POLICY_DOC="$(<"$ROOT_DIR/shared/iam/ack-policy.json")"
aws_cli iam put-role-policy --role-name "$ACK_ROLE" --policy-name Route53HealthChecks --policy-document "$ACK_POLICY_DOC"
sleep 10
aws_cli eks describe-capability --cluster-name "$CLUSTER_NAME" --capability-name secure-alb-ack >/dev/null 2>&1 || \
  aws_cli eks create-capability --cluster-name "$CLUSTER_NAME" --capability-name secure-alb-ack --type ACK --role-arn "$ACK_ARN" --delete-propagation-policy RETAIN >/dev/null
wait_capability secure-alb-ack

if [[ "$CAPABILITY_SET" == "ALL" ]]; then
  KRO_ROLE="EksKroCapabilityRole-${RUN_ID}"
  KRO_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${KRO_ROLE}"
  aws_cli iam get-role --role-name "$KRO_ROLE" >/dev/null 2>&1 || aws_cli iam create-role --role-name "$KRO_ROLE" --assume-role-policy-document "$TRUST" >/dev/null
  aws_cli iam update-assume-role-policy --role-name "$KRO_ROLE" --policy-document "$TRUST"
  sleep 10
  aws_cli eks describe-capability --cluster-name "$CLUSTER_NAME" --capability-name secure-alb-kro >/dev/null 2>&1 || \
    aws_cli eks create-capability --cluster-name "$CLUSTER_NAME" --capability-name secure-alb-kro --type KRO --role-arn "$KRO_ARN" --delete-propagation-policy RETAIN >/dev/null
  wait_capability secure-alb-kro
  aws_cli eks associate-access-policy --cluster-name "$CLUSTER_NAME" --principal-arn "$KRO_ARN" \
    --policy-arn arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy --access-scope type=cluster >/dev/null 2>&1 || true
fi

kubectl api-resources | grep services.k8s.aws
[[ "$CAPABILITY_SET" != "ALL" ]] || kubectl api-resources | grep kro.run
