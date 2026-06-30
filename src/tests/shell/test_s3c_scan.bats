#!/usr/bin/env bats
# test_s3c_scan.bats — exposure scanner. The headline assertion: REDACTION holds —
# planted secret bytes must NEVER appear in scan output.

setup() {
    REPO="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
    LIB="$REPO/src/lib/s3c-scan.sh"
    TMP="$(mktemp -d)"; export HOME="$TMP/home"
    AWS="AKIAIOSFODNN7EXAMPLE"
    R="$HOME/Projects/proj"; mkdir -p "$R"
    git -C "$R" init -q
    printf 'SECRET=topsecretvalue1234567890\n' > "$R/.env"
    printf 'A=1\n' > "$R/.env.local"          # variant — should be flagged (#9)
    printf 'A=1\n' > "$R/.env.example"        # example — should be ignored (#10)
    printf 'aws=%s\nstripe=sk_live_ABCDEFGH12345678\n' "$AWS" > "$R/creds.txt"
    git -C "$R" add -A >/dev/null 2>&1
    git -C "$R" -c user.email=a@b.c -c user.name=x commit -qm init
    printf 'export MYTOKEN=abcdefghij1234567890ABCDEFGH\n' > "$HOME/.zsh_history"
}
teardown() { [[ -n "${TMP:-}" && -d "$TMP" ]] && rm -rf "$TMP"; }

run_scan() { GORILLA_SCAN_ROOTS="$HOME/Projects" bash -c "source '$LIB'; cmd_scan $1" 2>&1; }

@test "scan --env flags a git-tracked .env, exit 1" {
    run run_scan --env
    [ "$status" -eq 1 ]
    [[ "$output" == *"TRACKED IN GIT"* ]]
}

@test "scan --git finds the AWS key but REDACTS the bytes" {
    run run_scan --git
    [ "$status" -eq 1 ]
    [[ "$output" == *"REDACTED — aws-access-key"* ]]
    [[ "$output" != *"AKIAIOSFODNN7EXAMPLE"* ]]
}

@test "scan --shell-history redacts the export value" {
    run run_scan --shell-history
    [ "$status" -eq 1 ]
    [[ "$output" == *"REDACTED — long-export"* ]]
    [[ "$output" != *"abcdefghij1234567890ABCDEFGH"* ]]
}

@test "scan --all is exit 1 and prints none of the planted secrets" {
    run run_scan --all
    [ "$status" -eq 1 ]
    [[ "$output" != *"AKIAIOSFODNN7EXAMPLE"* ]]
    [[ "$output" != *"topsecretvalue1234567890"* ]]
    [[ "$output" != *"abcdefghij1234567890ABCDEFGH"* ]]
}

@test "scan --env flags .env.local but ignores .env.example (#9/#10)" {
    run run_scan --env
    [[ "$output" == *".env.local"* ]]
    [[ "$output" != *".env.example"* ]]
}

@test "scan --git catches a Stripe key, still redacted (#8)" {
    run run_scan --git
    [ "$status" -eq 1 ]
    [[ "$output" == *"REDACTED — stripe-key"* ]]
    [[ "$output" != *"sk_live_ABCDEFGH12345678"* ]]
}

@test "scan --bogus exits 2" {
    run run_scan --bogus
    [ "$status" -eq 2 ]
}
