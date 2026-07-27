#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/lib.sh"
load_config "${1:-}"
STAGE="${2:-1}"
require_command aws
require_command kubectl

aws_cli sts get-caller-identity
aws_cli ec2 describe-regions --region-names "$AWS_REGION" --query 'Regions[0].RegionName' --output text

if [[ "$STAGE" == "0" ]]; then
  echo "Stage 0 EDA prerequisites validated; no Shield, WAF, ACM, Route 53 or ExternalDNS prerequisite is required."
  exit 0
fi

REQUIRED_VALUES=(WEB_ACL_ARN ALB_LOG_BUCKET)
if [[ "${PUBLIC_DNS_ENABLED:-true}" == "true" ]]; then
  REQUIRED_VALUES+=(HOSTED_ZONE_ID HOSTNAME ACM_CERTIFICATE_ARN)
fi
for value_name in "${REQUIRED_VALUES[@]}"; do
  value="${!value_name:-}"
  [[ -n "$value" && "$value" != "REQUIRED" ]] || { echo "$value_name must be configured" >&2; exit 1; }
done

aws_cli wafv2 get-web-acl --scope REGIONAL --id "$(awk -F/ '{print $NF}' <<<"$WEB_ACL_ARN")" --name "$(awk -F/ '{print $(NF-1)}' <<<"$WEB_ACL_ARN")" >/dev/null
if [[ "${PUBLIC_DNS_ENABLED:-true}" == "true" ]]; then
  aws_cli route53 get-hosted-zone --id "$HOSTED_ZONE_ID" >/dev/null
  aws_cli acm describe-certificate --certificate-arn "$ACM_CERTIFICATE_ARN" >/dev/null
fi
aws_cli s3api head-bucket --bucket "$ALB_LOG_BUCKET"
echo "Prerequisites validated"
