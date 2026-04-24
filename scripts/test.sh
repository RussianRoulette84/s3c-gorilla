#!/usr/bin/env bash
# test.sh — run src/tests/run.sh with output mirrored to logs/test.log.
# Thin wrapper; pass-through args.

set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
LOG_DIR="$ROOT/logs"
mkdir -p "$LOG_DIR"

{
    echo "===== test.sh run: $(date) ====="
    "$ROOT/src/tests/run.sh" "$@"
} 2>&1 | tee "$LOG_DIR/test.log"

exit "${PIPESTATUS[0]}"
