#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "This package requires macOS 13 or newer." >&2
  exit 1
fi
if [[ "${1:-}" == "--universal" ]]; then
  swift build -c release --arch arm64 --arch x86_64
  build_dir="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)"
else
  swift build -c release
  build_dir="$(swift build -c release --show-bin-path)"
fi
mkdir -p dist
install -m 755 "$build_dir/c2c" dist/c2c
codesign --force --sign - dist/c2c
printf 'Built %s/dist/c2c\n' "$PWD"
