#!/usr/bin/env bash
# s3c-gorilla test orchestrator.
# Usage: src/tests/run.sh           # all layers
#        src/tests/run.sh swift     # only Swift
#        src/tests/run.sh shell     # only shell (bats)

set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
LAYER="${1:-all}"

pass=0
fail=0
skip=0
failures=()

run_swift() {
    local f
    for f in "$HERE/swift/"test_*.swift; do
        [[ -f "$f" ]] || continue
        local name; name="$(basename "$f")"
        echo "== $name =="
        if out=$(swift "$f" 2>&1); then
            # Parse the trailing "--- N passed, M failed, K skipped" line.
            printf '%s\n' "$out"
            local p fa sk
            p=$(grep -Eo '[0-9]+ passed'  <<<"$out" | awk '{print $1}' | tail -1)
            fa=$(grep -Eo '[0-9]+ failed'  <<<"$out" | awk '{print $1}' | tail -1)
            sk=$(grep -Eo '[0-9]+ skipped' <<<"$out" | awk '{print $1}' | tail -1)
            pass=$((pass + ${p:-0}))
            fail=$((fail + ${fa:-0}))
            skip=$((skip + ${sk:-0}))
        else
            printf '%s\n' "$out"
            failures+=("$name")
            fail=$((fail + 1))
        fi
    done
}

run_shell() {
    if ! command -v bats >/dev/null 2>&1; then
        echo "bats not installed — 'brew install bats-core' to run shell tests"
        return 0
    fi
    local f
    for f in "$HERE/shell/"test_*.bats; do
        [[ -f "$f" ]] || continue
        echo "== $(basename "$f") =="
        if bats --tap "$f"; then
            local p sk
            # bats TAP output doesn't cleanly count skips; rough parse:
            p=$(bats --tap "$f" 2>/dev/null | grep -cE '^ok ')
            sk=$(bats --tap "$f" 2>/dev/null | grep -cE '^ok .* # skip')
            pass=$((pass + p - sk))
            skip=$((skip + sk))
        else
            failures+=("$(basename "$f")")
            fail=$((fail + 1))
        fi
    done
}

case "$LAYER" in
    swift) run_swift ;;
    shell) run_shell ;;
    all)   run_swift; run_shell ;;
    *) echo "usage: $0 [swift|shell|all]"; exit 2 ;;
esac

echo
echo "==================="
echo "total: $pass passed, $fail failed, $skip skipped"
if (( fail > 0 )); then
    printf '  %s\n' "${failures[@]}"
    exit 1
fi
exit 0
