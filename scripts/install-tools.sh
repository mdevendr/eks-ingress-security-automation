#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/lib.sh"
require_command curl
require_command unzip

EKSCTL_VERSION="${EKSCTL_VERSION:-0.229.0}"
HELM_VERSION="${HELM_VERSION:-4.2.3}"
TOOLS_DIR="$ROOT_DIR/.tools"
mkdir -p "$TOOLS_DIR"

install_zip_executable() {
  local url="$1" archive_path="$2" executable_name="$3" target_name="$4"
  local extract_dir
  [[ -x "$TOOLS_DIR/$target_name" ]] && return 0
  extract_dir="$TMP_DIR/extract-$target_name"
  mkdir -p "$extract_dir"
  curl -fsSL "$url" -o "$archive_path"
  unzip -q -o "$archive_path" -d "$extract_dir"
  local source_path
  source_path="$(find "$extract_dir" -type f -name "$executable_name" -print -quit)"
  [[ -n "$source_path" ]] || { echo "$executable_name was not found in $archive_path" >&2; return 1; }
  cp "$source_path" "$TOOLS_DIR/$target_name"
  chmod +x "$TOOLS_DIR/$target_name"
}

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
install_zip_executable \
  "https://github.com/eksctl-io/eksctl/releases/download/v${EKSCTL_VERSION}/eksctl_Windows_amd64.zip" \
  "$TMP_DIR/eksctl.zip" eksctl.exe eksctl.exe
install_zip_executable \
  "https://get.helm.sh/helm-v${HELM_VERSION}-windows-amd64.zip" \
  "$TMP_DIR/helm.zip" helm.exe helm.exe

"$TOOLS_DIR/eksctl.exe" version
"$TOOLS_DIR/helm.exe" version --short
echo "Tools installed in $TOOLS_DIR"
