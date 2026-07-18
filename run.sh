#!/usr/bin/env bash
set -euo pipefail

NIX_FLAGS=(
  --builders "ssh-ng://eu.nixbuild.net x86_64-linux - 100 1 kvm,nixos-test,benchmark,big-parallel"
)
INSTALLABLE=(--file . umn.config.system.build.umlRunner)

echo "=== Building (log: /tmp/umlbuild.log) ==="
nix "${NIX_FLAGS[@]}" build "${INSTALLABLE[@]}" --print-build-logs --no-link 2>&1 | tee /tmp/umlbuild.log | tail -n 30

echo "=== Running (log: /tmp/umlrun.log) ==="
nix "${NIX_FLAGS[@]}" run "${INSTALLABLE[@]}" -- 2>&1 | tee /tmp/umlrun.log

echo "=== Done ==="
