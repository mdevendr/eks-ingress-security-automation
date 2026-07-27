#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/lib.sh"
CONFIG_FILE="${1:-$ROOT_DIR/config/lab.env}"
STAGE="${2:-1}"
load_config "$CONFIG_FILE"
START="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "Deployment started at $START"
"$ROOT_DIR/scripts/validate-prerequisites.sh" "$CONFIG_FILE" "$STAGE"
"$ROOT_DIR/scripts/deploy-aws.sh" "$CONFIG_FILE" "$STAGE" & AWS_PID=$!
"$ROOT_DIR/scripts/create-cluster.sh" "$CONFIG_FILE" "$STAGE"
wait "$AWS_PID"
if [[ "$STAGE" == "0" ]]; then
  echo "Stage 0 uses no EKS capability or ExternalDNS."
elif [[ "$STAGE" == "1" ]]; then
  "$ROOT_DIR/scripts/enable-capabilities.sh" "$CONFIG_FILE" ACK_ONLY
else
  "$ROOT_DIR/scripts/enable-capabilities.sh" "$CONFIG_FILE" ALL
fi
if [[ "$STAGE" != "0" && "${PUBLIC_DNS_ENABLED:-true}" == "true" ]]; then
  "$ROOT_DIR/scripts/install-external-dns.sh" "$CONFIG_FILE" "$STAGE"
fi
"$ROOT_DIR/scripts/deploy-kubernetes.sh" "$CONFIG_FILE" "$STAGE"
"$ROOT_DIR/scripts/smoke-test.sh" "$CONFIG_FILE" "$STAGE"
"$ROOT_DIR/scripts/capture-evidence.sh" "$CONFIG_FILE" "$STAGE"
echo "Deployment completed at $(date -u +%Y-%m-%dT%H:%M:%SZ)"
