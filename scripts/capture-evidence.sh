#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/lib.sh"
load_config "${1:-}"
STAGE="${2:-unknown}"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
OUT="$ROOT_DIR/evidence/stage-$STAGE/$STAMP"
mkdir -p "$OUT"
aws_cli sts get-caller-identity >"$OUT/identity.json"
aws_cli eks describe-cluster --name "$CLUSTER_NAME" >"$OUT/eks-cluster.json"
aws_cli eks list-capabilities --cluster-name "$CLUSTER_NAME" >"$OUT/eks-capabilities.json"
for resource in ingress securealb resourcegraphdefinitions.kro.run graphrevisions.internal.kro.run gateways.gateway.networking.k8s.io httproutes.gateway.networking.k8s.io loadbalancerconfigurations.gateway.k8s.aws targetgroupconfigurations.gateway.k8s.aws healthchecks.route53.services.k8s.aws; do
  kubectl get "$resource" -A -o yaml >>"$OUT/kubernetes-resources.yaml" 2>/dev/null || true
done
kubectl get events -A --sort-by=.lastTimestamp >"$OUT/kubernetes-events.txt"
aws_cli dynamodb scan --table-name "EksSecureAlbInventory-${RUN_ID}" >"$OUT/inventory.json"
ALB_ARN="$(aws_cli resourcegroupstaggingapi get-resources --resource-type-filters elasticloadbalancing:loadbalancer --tag-filters Key=secure-alb/id,Values=secure-alb-demo/demo --query 'ResourceTagMappingList[0].ResourceARN' --output text 2>/dev/null || true)"
if [[ -n "$ALB_ARN" && "$ALB_ARN" != "None" ]]; then
  aws_cli elbv2 describe-load-balancers --load-balancer-arns "$ALB_ARN" >"$OUT/alb.json"
  aws_cli elbv2 describe-load-balancer-attributes --load-balancer-arn "$ALB_ARN" >"$OUT/alb-attributes.json"
  aws_cli wafv2 get-web-acl-for-resource --resource-arn "$ALB_ARN" >"$OUT/waf-association.json" 2>"$OUT/waf-association-error.txt" || true
fi
[[ ! -f "$ROOT_DIR/.build/stage-1-admission-error.txt" ]] || cp "$ROOT_DIR/.build/stage-1-admission-error.txt" "$OUT/admission-rejection.txt"
[[ ! -f "$ROOT_DIR/.build/stage-2-policy-error.txt" ]] || cp "$ROOT_DIR/.build/stage-2-policy-error.txt" "$OUT/waf-policy-rejection.txt"
aws_cli logs tail "/aws/lambda/eks-secure-alb-gap-${RUN_ID}" --since 1h >"$OUT/gap-filler.log" 2>&1 || true
aws_cli logs tail "/aws/lambda/eks-secure-alb-reconcile-${RUN_ID}" --since 1h >"$OUT/reconciler.log" 2>&1 || true
git -C "$ROOT_DIR" status --short --branch >"$OUT/git-status.txt"
printf 'stage=%s\ncapturedAt=%s\n' "$STAGE" "$STAMP" >"$OUT/run-metadata.txt"
echo "$OUT"
