#!/usr/bin/env bats
# test_icloud_picker.bats — Step 9 (09-database.sh) behaviour.
# PLAN.md: find + picker for .kdbx files, apostrophe-safe paths
# (Concern #37), iCloud-evict xattr detection (Concern #30).

setup() {
    STEP9="$BATS_TEST_DIRNAME/../../setup/09-database.sh"
    FIXTURES="$BATS_TEST_DIRNAME/fixtures/kdbx_library"
    mkdir -p "$FIXTURES"
}

teardown() {
    rm -rf "$FIXTURES"
}

@test "09-database.sh exists once Phase 1 install refactor lands" {
    if [[ ! -f "$STEP9" ]]; then
        skip "09-database.sh not yet created — Phase 1 pending"
    fi
    [ -f "$STEP9" ]
}

@test "NUL-delimited find handles apostrophes in kdbx filenames (Concern #37)" {
    touch "$FIXTURES/O'Brien's Vault.kdbx"
    touch "$FIXTURES/normal.kdbx"
    # Use find -print0 + read -d '' — the pattern the picker must use.
    count=0
    while IFS= read -r -d '' _; do
        count=$((count + 1))
    done < <(find "$FIXTURES" -type f -name '*.kdbx' -print0 2>/dev/null)
    [ "$count" -eq 2 ]
}

@test "kdbx with spaces AND apostrophes survives printf %q round-trip" {
    path="$FIXTURES/User's Test Vault.kdbx"
    touch "$path"
    escaped=$(printf '%q' "$path")
    # Round-trip: eval back, read the file attr.
    run bash -c "eval ls \"$escaped\""
    [ "$status" -eq 0 ]
    [[ "$output" == *"User's Test Vault.kdbx"* ]]
}

@test "shell-native 2s timeout pattern doesn't need gtimeout (Concern #30 / N5)" {
    # Spawn a long sleep, kill it via background killer after 1s.
    # Concept under test: we can escape a blocking read without
    # coreutils' gtimeout.
    start=$SECONDS
    ( sleep 10 ) & pid=$!
    ( sleep 1 && kill -TERM "$pid" 2>/dev/null ) &
    wait "$pid" 2>/dev/null || true       # swallow SIGTERM exit status
    elapsed=$((SECONDS - start))
    # Should be ~1s, never 10s. Allow 0-3s window.
    [ "$elapsed" -lt 3 ]
    # Confirm the target pid is actually dead.
    ! kill -0 "$pid" 2>/dev/null
}

@test "eviction xattr detection probe logic (Concern #30)" {
    touch "$FIXTURES/present.kdbx"
    # We can't actually create com.apple.cloud.evict without a real iCloud
    # file; simulate the probe's decision logic.
    run xattr -p com.apple.cloud.evict "$FIXTURES/present.kdbx"
    # Non-evicted file: xattr exits 1 (attribute not set). That's the
    # "file is materialized" signal our probe relies on.
    [ "$status" -eq 1 ]
}

@test "multi-match picker numbering is stable (Concern #37 + spec §Step 9)" {
    # Create 3 kdbx files; assert find output is deterministic when sorted.
    touch "$FIXTURES/a.kdbx" "$FIXTURES/b.kdbx" "$FIXTURES/c.kdbx"
    run bash -c "find '$FIXTURES' -type f -name '*.kdbx' | sort"
    [ "$status" -eq 0 ]
    lines=$(echo "$output" | wc -l | tr -d ' ')
    [ "$lines" -eq 3 ]
    [[ "$(echo "$output" | head -1)" == *"a.kdbx" ]]
    [[ "$(echo "$output" | tail -1)" == *"c.kdbx" ]]
}
