#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/lib.sh"
load_config "${1:-}"
STAGE="${2:-1}"
ACCOUNT_ID="$(aws_cli sts get-caller-identity --query Account --output text)"
POLICY_NAME="EksSecureAlbExternalDns-${RUN_ID}"
POLICY_ARN="arn:aws:iam::${ACCOUNT_ID}:policy/${POLICY_NAME}"
ZONE_ID="${HOSTED_ZONE_ID#/hostedzone/}"
ZONE_ARN="arn:aws:route53:::hostedzone/${ZONE_ID}"
POLICY_DOC="$(sed "s|HOSTED_ZONE_ARN|$ZONE_ARN|g" "$ROOT_DIR/shared/iam/external-dns-policy.json")"
aws_cli iam get-policy --policy-arn "$POLICY_ARN" >/dev/null 2>&1 || aws_cli iam create-policy --policy-name "$POLICY_NAME" --policy-document "$POLICY_DOC" >/dev/null
eksctl create iamserviceaccount --cluster "$CLUSTER_NAME" --namespace kube-system --name external-dns \
  --attach-policy-arn "$POLICY_ARN" --override-existing-serviceaccounts --region "$AWS_REGION" --profile "$AWS_PROFILE" --approve
helm repo add external-dns https://kubernetes-sigs.github.io/external-dns/ >/dev/null
helm repo update >/dev/null
HELM_ARGS=(upgrade --install external-dns external-dns/external-dns --namespace kube-system
  --set serviceAccount.create=false --set serviceAccount.name=external-dns
  --set provider.name=aws --set 'sources[0]=ingress'
  --set policy=sync --set registry=txt --set txtOwnerId="$RUN_ID"
  --set 'extraArgs[0]=--zone-id-filter='"$ZONE_ID" --wait --timeout 5m)
if [[ "$STAGE" != "0" ]]; then
  HELM_ARGS+=(--set 'sources[1]=gateway-httproute')
fi
helm "${HELM_ARGS[@]}"
