#!/usr/bin/env bats
# test_s3c_keychain.bats — keychain check categorization + redaction (no secret/account
# values printed) + the macOS-only guard. `security` is mocked (the suite runs on Linux CI).

setup() {
    REPO="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
    LIB="$REPO/src/lib/s3c-keychain.sh"
    TMP="$(mktemp -d)"; mkdir -p "$TMP/bin"; export HOME="$TMP/home"; mkdir -p "$HOME"
    cat > "$TMP/bin/security" <<'EOF'
#!/bin/bash
[[ "$1" == "dump-keychain" ]] || exit 1
cat <<'DUMP'
keychain: "/Users/x/Library/Keychains/login.keychain-db"
class: "inet"
attributes:
    0x00000007 <blob>="github.com"
    "acct"<blob>="yaro"
    "srvr"<blob>="github.com"
class: "genp"
attributes:
    0x00000007 <blob>="Amazon Web Services"
    "acct"<blob>="AKIASECRETACCOUNT"
    "svce"<blob>="aws"
class: "genp"
attributes:
    0x00000007 <blob>="Random Note"
    "svce"<blob>="notes"
DUMP
EOF
    chmod +x "$TMP/bin/security"
}
teardown() { [[ -n "${TMP:-}" && -d "$TMP" ]] && rm -rf "$TMP"; }

@test "check flags git + cloud, skips unrelated, exit 1" {
    run env PATH="$TMP/bin:$PATH" bash -c "source '$LIB'; cmd_keychain check"
    [ "$status" -eq 1 ]
    [[ "$output" == *"[git]"* ]]
    [[ "$output" == *"[cloud]"* ]]
    [[ "$output" != *"Random Note"* ]]
}

@test "check never prints account/secret values" {
    run env PATH="$TMP/bin:$PATH" bash -c "source '$LIB'; cmd_keychain check"
    [[ "$output" != *"AKIASECRETACCOUNT"* ]]
}

@test "clean keychain → exit 0" {
    printf '#!/bin/bash\n[[ "$1" == dump-keychain ]] && exit 0 || exit 1\n' > "$TMP/bin/security"
    chmod +x "$TMP/bin/security"
    run env PATH="$TMP/bin:$PATH" bash -c "source '$LIB'; cmd_keychain check"
    [ "$status" -eq 0 ]
    [[ "$output" == *"nothing in the Keychain"* ]]
}

@test "no security command → macOS-only note, exit 0" {
    # Don't add the mock to PATH; on Linux `security` is genuinely absent. Skip on macOS.
    command -v security >/dev/null 2>&1 && skip "security present (macOS)"
    run bash -c "source '$LIB'; cmd_keychain check"
    [ "$status" -eq 0 ]
    [[ "$output" == *"macOS only"* ]]
}

@test "bad subcommand exits 2" {
    run env PATH="$TMP/bin:$PATH" bash -c "source '$LIB'; cmd_keychain bogus"
    [ "$status" -eq 2 ]
}
