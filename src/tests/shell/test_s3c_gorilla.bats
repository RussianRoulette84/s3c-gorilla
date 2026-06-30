#!/usr/bin/env bats
# test_s3c_gorilla.bats — umbrella CLI (P3): dispatch, dual-mode status, list, lock.

setup() {
    REPO="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
    CLI="$REPO/src/s3c-gorilla"
    TMP="$(mktemp -d)"; mkdir -p "$TMP/bin" "$TMP/home"
    export HOME="$TMP/home"
}
teardown() { [[ -n "${TMP:-}" && -d "$TMP" ]] && rm -rf "$TMP"; }

@test "help lists the subcommands" {
    run bash "$CLI" help
    [ "$status" -eq 0 ]
    [[ "$output" == *"s3c-gorilla wipe"* ]]
    [[ "$output" == *"uninstall"* ]]
}

@test "unknown command exits 2" {
    run bash "$CLI" frobnicate
    [ "$status" -eq 2 ]
}

@test "status reports password mode when no touchid binary" {
    run env GORILLA_TOUCHID="$TMP/bin/nope" bash "$CLI" status
    [[ "$output" == *"password (no Secure Enclave)"* ]]
}

@test "list otp routes through the session agent in password mode" {
    cat > "$TMP/bin/sa" <<'EOF'
#!/bin/bash
[[ "$1" == "list" ]] && printf 'github\natlassian\n'
exit 0
EOF
    chmod +x "$TMP/bin/sa"
    run env GORILLA_TOUCHID="$TMP/bin/nope" GORILLA_SESSION_AGENT="$TMP/bin/sa" bash "$CLI" list otp
    [ "$status" -eq 0 ]
    [[ "$output" == *github* ]]
}

@test "lock calls the agent stop subcommand" {
    cat > "$TMP/bin/sa" <<EOF
#!/bin/bash
echo "\$@" >> "$TMP/sa.calls"
EOF
    chmod +x "$TMP/bin/sa"
    run env GORILLA_TOUCHID="$TMP/bin/nope" GORILLA_SESSION_AGENT="$TMP/bin/sa" bash "$CLI" lock
    [ "$status" -eq 0 ]
    grep -q '^stop ' "$TMP/sa.calls"
}

@test "list with a bad kind exits 2" {
    run bash "$CLI" list bogus
    [ "$status" -eq 2 ]
}
