#!/usr/bin/env bash
# lint.sh — project-wide lint + typecheck, output mirrored to logs/lint.log.
#
# Usage:
#   ./scripts/lint.sh                 # lint src/, typecheck each .swift
#   ./scripts/lint.sh --lint-only     # skip swiftc typecheck
#   ./scripts/lint.sh --typecheck-only
#
# Exit code reflects the linter's exit code (non-zero on errors). Warnings
# do not fail the run.

set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
LOG_DIR="$ROOT/logs"
LOG_FILE="$LOG_DIR/lint.log"
mkdir -p "$LOG_DIR"

MODE="all"
for arg in "$@"; do
    case "$arg" in
        --lint-only)      MODE="lint" ;;
        --typecheck-only) MODE="typecheck" ;;
        -h|--help)        sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) printf "unknown arg: %s\n" "$arg" >&2; exit 2 ;;
    esac
done

{
    echo "===== lint.sh run: $(date) ====="

    rc_lint=0
    rc_tc=0

    if [[ "$MODE" == "all" || "$MODE" == "lint" ]]; then
        echo
        echo "--- swift-linter on src/ ---"
        "$HERE/linters/swift-linter.sh" "$ROOT/src"
        rc_lint=$?
    fi

    if [[ "$MODE" == "all" || "$MODE" == "typecheck" ]]; then
        echo
        echo "--- swiftc -typecheck on each top-level .swift ---"
        shopt -s nullglob
        for f in "$ROOT/src/"*.swift; do
            name="$(basename "$f")"
            if out=$(swiftc -typecheck "$f" 2>&1); then
                echo "  OK    $name"
            else
                echo "  FAIL  $name"
                printf '%s\n' "$out" | sed 's/^/        /'
                rc_tc=1
            fi
        done
    fi

    echo
    echo "===== done: lint rc=$rc_lint  typecheck rc=$rc_tc ====="
    exit $(( rc_lint | rc_tc ))
} 2>&1 | tee "$LOG_FILE"

# Preserve pipeline exit status (the subshell's exit via `exit` is captured
# by PIPESTATUS[0]).
exit "${PIPESTATUS[0]}"
