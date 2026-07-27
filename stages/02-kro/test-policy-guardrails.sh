#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/../../scripts/lib.sh"
mkdir -p "$ROOT_DIR/.build"
INVALID="$(mktemp)"
trap 'rm -f "$INVALID"' EXIT
cat >"$INVALID" <<'EOF'
apiVersion: platform.eks.example/v1alpha1
kind: SecureALB
metadata:
  name: invalid-policy-test
  namespace: secure-alb-demo
spec:
  serviceName: demo
  servicePort: 80
  wafPolicyRef: arn:aws:wafv2:eu-west-2:000000000000:regional/webacl/unapproved/id
  accessLogBucket: invalid
EOF
if kubectl apply --dry-run=server -f "$INVALID" >/dev/null 2>"$ROOT_DIR/.build/stage-2-policy-error.txt"; then
  echo "FAIL: raw or unknown WAF policy reference was accepted" >&2
  exit 1
fi
echo "PASS: unknown WAF policy reference rejected"
cat "$ROOT_DIR/.build/stage-2-policy-error.txt"
