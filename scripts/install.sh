#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "This package requires macOS 13 or newer." >&2
  exit 1
fi
prefix="${1:-$HOME/.local}"
./scripts/build.sh
mkdir -p "$prefix/bin"
install -m 755 dist/c2c "$prefix/bin/c2c"
printf 'Installed %s/bin/c2c\nAdd %s/bin to PATH if needed.\n' "$prefix" "$prefix"
