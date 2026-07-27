#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PATH="$ROOT_DIR/.tools:$PATH"

load_config() {
  local config_file="${1:-$ROOT_DIR/config/lab.env}"
  if [[ ! -f "$config_file" ]]; then
    echo "Missing $config_file. Copy config/example.env and fill required values." >&2
    return 1
  fi
  set -a
  # shellcheck disable=SC1090
  source "$config_file"
  set +a
  export AWS_PROFILE AWS_REGION
  : "${CLUSTER_NAME:?CLUSTER_NAME is required}"
  : "${AWS_REGION:?AWS_REGION is required}"
  : "${RUN_ID:?RUN_ID is required}"
}

aws_cli() {
  aws --profile "$AWS_PROFILE" --region "$AWS_REGION" --cli-binary-format raw-in-base64-out "$@"
}

native_path() {
  if command -v cygpath >/dev/null 2>&1; then
    cygpath -m "$1"
  else
    printf '%s\n' "$1"
  fi
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || { echo "Required command not found: $1" >&2; return 1; }
}

wait_capability() {
  local name="$1"
  local status
  for _ in {1..60}; do
    status="$(aws_cli eks describe-capability --cluster-name "$CLUSTER_NAME" --capability-name "$name" --query capability.status --output text 2>/dev/null || true)"
    [[ "$status" == "ACTIVE" ]] && return 0
    [[ "$status" == "FAILED" ]] && { aws_cli eks describe-capability --cluster-name "$CLUSTER_NAME" --capability-name "$name"; return 1; }
    sleep 10
  done
  echo "Timed out waiting for capability $name" >&2
  return 1
}
