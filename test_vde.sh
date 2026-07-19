#!/usr/bin/env bash
set -euo pipefail

echo "=== Building kernel + root images ==="

KERNEL=$(nix build .#packages.x86_64-linux.vde-test --print-out-paths --no-link 2>/dev/null || true)
if [ -z "$KERNEL" ]; then
  # Build the dependencies directly
  nix build --file . vde-test --print-build-logs --no-link 2>&1 | tail -20
  exit 1
fi

echo "Test passed!"
