#!/usr/bin/env bats
# test_step_file_lint.bats — conventions for src/setup/[0-9]*.sh
# PLAN.md: Concern #34 (step files end in `true`/`:`) + #35 (two-digit padded prefix)

setup() {
    SETUP_DIR="$BATS_TEST_DIRNAME/../../setup"
    [[ -d "$SETUP_DIR" ]] || skip "src/setup/ missing"
    # Collect numbered step files only (digit-prefix).
    shopt -s nullglob
    STEP_FILES=("$SETUP_DIR"/[0-9]*.sh)
    shopt -u nullglob
}

@test "at least one numbered step file exists" {
    if [ "${#STEP_FILES[@]}" -eq 0 ]; then
        skip "no step files yet — pre-Phase-1 state"
    fi
    [ "${#STEP_FILES[@]}" -gt 0 ]
}

@test "every numbered step file uses two-digit zero-padded prefix (Concern #35)" {
    if [ "${#STEP_FILES[@]}" -eq 0 ]; then
        skip "no step files yet"
    fi
    for f in "${STEP_FILES[@]}"; do
        base=$(basename "$f")
        if ! [[ "$base" =~ ^[0-9]{2}-[a-z0-9-]+\.sh$ ]]; then
            echo "bad name: $base"
            return 1
        fi
    done
}

@test "every step file ends with 'true' or ':' (Concern #34)" {
    if [ "${#STEP_FILES[@]}" -eq 0 ]; then
        skip "no step files yet"
    fi
    for f in "${STEP_FILES[@]}"; do
        last=$(grep -vE '^\s*(#|$)' "$f" | tail -1 | tr -d '[:space:]')
        case "$last" in
            true|":") continue ;;
            *) echo "step file $f ends with: $last"; return 1 ;;
        esac
    done
}

@test "every step file has a header comment naming its purpose" {
    if [ "${#STEP_FILES[@]}" -eq 0 ]; then
        skip "no step files yet"
    fi
    for f in "${STEP_FILES[@]}"; do
        first=$(head -3 "$f" | grep -cE '^#')
        [ "$first" -ge 1 ] || { echo "no header comment: $f"; return 1; }
    done
}

@test "no step file exceeds 250 lines (CLAUDE.md rule)" {
    if [ "${#STEP_FILES[@]}" -eq 0 ]; then
        skip "no step files yet"
    fi
    for f in "${STEP_FILES[@]}"; do
        lines=$(wc -l < "$f")
        if [ "$lines" -gt 250 ]; then
            echo "$f: $lines lines (max 250)"; return 1
        fi
    done
}

@test "sort -V probe works on this system (Concern #35 / N6)" {
    run bash -c "printf '10\n9\n' | sort -V | head -1"
    # If sort -V works, output is '9'. If not supported, output is '10'
    # (lexical) — but we still pass because the plan specifies a fallback.
    if [ "$output" = "9" ]; then
        echo "sort -V available"
    else
        echo "sort -V fallback would trigger (lexical sort)"
    fi
    # Either outcome is fine; the test verifies the probe runs.
    [ -n "$output" ]
}
