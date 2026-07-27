#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/lib.sh"
CONFIG_FILE="${1:-$ROOT_DIR/config/lab.env}"
STAGE="${2:-1}"
case "$STAGE" in
  0) "$ROOT_DIR/stages/00-ingress/deploy.sh" "$CONFIG_FILE" ;;
  1) "$ROOT_DIR/stages/01-gateway-api/deploy.sh" "$CONFIG_FILE" ;;
  2) "$ROOT_DIR/stages/02-kro/deploy.sh" "$CONFIG_FILE" ;;
  *) echo "Stage must be 0, 1 or 2" >&2; exit 2 ;;
esac
