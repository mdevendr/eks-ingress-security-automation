#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/lib.sh"
load_config "${1:-}"
STAGE="${2:-1}"
require_command eksctl
require_command helm
require_command kubectl

IFS=',' read -r -a INSTANCE_TYPES <<<"$NODE_INSTANCE_TYPES"
INSTANCE_YAML=""
for type in "${INSTANCE_TYPES[@]}"; do INSTANCE_YAML+="      - $type"$'\n'; done
TMP_CONFIG="$(mktemp)"
trap 'rm -f "$TMP_CONFIG"' EXIT
cat >"$TMP_CONFIG" <<EOF
apiVersion: eksctl.io/v1alpha5
kind: ClusterConfig
metadata:
  name: $CLUSTER_NAME
  region: $AWS_REGION
  version: "$KUBERNETES_VERSION"
iam:
  withOIDC: true
vpc:
  nat:
    gateway: Disable
  clusterEndpoints:
    publicAccess: true
    privateAccess: false
managedNodeGroups:
  - name: spot-workers
    instanceTypes:
$INSTANCE_YAML
    spot: true
    minSize: 1
    desiredCapacity: 1
    maxSize: 2
    volumeSize: 20
    volumeType: gp3
    privateNetworking: false
    labels:
      workload: secure-alb-lab
    tags:
      secure-alb/run-id: $RUN_ID
EOF

if ! aws_cli eks describe-cluster --name "$CLUSTER_NAME" >/dev/null 2>&1; then
  eksctl create cluster -f "$TMP_CONFIG" --profile "$AWS_PROFILE"
else
  aws_cli eks update-kubeconfig --name "$CLUSTER_NAME"
fi

if [[ "$STAGE" != "0" ]]; then
  kubectl apply --server-side=true -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.5.0/standard-install.yaml
  kubectl apply -f https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/refs/heads/main/config/crd/gateway/gateway-crds.yaml
fi

ACCOUNT_ID="$(aws_cli sts get-caller-identity --query Account --output text)"
LBC_POLICY_ARN="arn:aws:iam::${ACCOUNT_ID}:policy/AWSLoadBalancerControllerIAMPolicy"
TMP_POLICY="$(mktemp)"
curl -fsSL https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v3.4.2/docs/install/iam_policy.json -o "$TMP_POLICY"
LBC_POLICY_DOC="$(<"$TMP_POLICY")"
aws_cli iam get-policy --policy-arn "$LBC_POLICY_ARN" >/dev/null 2>&1 || aws_cli iam create-policy --policy-name AWSLoadBalancerControllerIAMPolicy --policy-document "$LBC_POLICY_DOC" >/dev/null
eksctl create iamserviceaccount --cluster "$CLUSTER_NAME" --namespace kube-system --name aws-load-balancer-controller \
  --attach-policy-arn "$LBC_POLICY_ARN" --override-existing-serviceaccounts --region "$AWS_REGION" --profile "$AWS_PROFILE" --approve
helm repo add eks https://aws.github.io/eks-charts >/dev/null
helm repo update >/dev/null
HELM_ARGS=(upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller --namespace kube-system
  --set clusterName="$CLUSTER_NAME" --set serviceAccount.create=false --set serviceAccount.name=aws-load-balancer-controller
  --wait --timeout 10m)
if [[ "$STAGE" != "0" ]]; then
  HELM_ARGS+=(--set controllerConfig.featureGates.ALBGatewayAPI=true)
fi
helm "${HELM_ARGS[@]}"
kubectl rollout status deployment/aws-load-balancer-controller -n kube-system --timeout=5m
