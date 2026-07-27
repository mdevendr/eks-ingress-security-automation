#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/lib.sh"
BUILD_DIR="$ROOT_DIR/.build"
mkdir -p "$BUILD_DIR/gap-filler" "$BUILD_DIR/reconciler"
cp "$ROOT_DIR/shared/functions/gap-filler/lambda_function.py" "$BUILD_DIR/gap-filler/lambda_function.py"
cp "$ROOT_DIR/shared/functions/reconciler/lambda_function.py" "$BUILD_DIR/reconciler/lambda_function.py"
if command -v python3 >/dev/null 2>&1; then
  PYTHON=(python3)
elif command -v py >/dev/null 2>&1; then
  PYTHON=(py -3)
elif command -v python >/dev/null 2>&1; then
  PYTHON=(python)
else
  echo "Python 3 is required to create Lambda ZIP files." >&2
  exit 1
fi
rm -f "$BUILD_DIR/gap-filler.zip" "$BUILD_DIR/reconciler.zip"
(cd "$BUILD_DIR/gap-filler" && "${PYTHON[@]}" -m zipfile -c ../gap-filler.zip lambda_function.py)
(cd "$BUILD_DIR/reconciler" && "${PYTHON[@]}" -m zipfile -c ../reconciler.zip lambda_function.py)
echo "$BUILD_DIR"
