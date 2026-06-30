#!/usr/bin/env bats
# test_session_unlock.bats — password-mode session-unlock gating + --clear safety (B13)
#   - get_master_pw reuses the session agent when GORILLA_SESSION_UNLOCK=true
#   - get_master_pw prompts when unlock is off
#   - env-gorilla --clear <proj> never invokes touchid-gorilla in password mode (B11)

setup() {
    REPO="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
    TMP="$(mktemp -d)"
    mkdir -p "$TMP/bin"
}
teardown() {
    [[ -n "${TMP:-}" && -d "$TMP" ]] && rm -rf "$TMP"
}

@test "get_master_pw reuses the session agent when unlocked" {
    cat > "$TMP/bin/s3c-session-agent" <<'EOF'
#!/bin/bash
[[ "$1" == "get" ]] && { printf 'MOCKPW'; exit 0; }
exit 0
EOF
    chmod +x "$TMP/bin/s3c-session-agent"
    run env GORILLA_SESSION_UNLOCK=true GORILLA_SESSION_AGENT="$TMP/bin/s3c-session-agent" \
        bash -c "source '$REPO/src/lib/banners.sh'; ask_master_pw(){ printf SHOULD_NOT_PROMPT; }; get_master_pw"
    [ "$status" -eq 0 ]
    [ "$output" = "MOCKPW" ]
}

@test "get_master_pw prompts when session unlock is off" {
    run env GORILLA_SESSION_UNLOCK=false \
        bash -c "source '$REPO/src/lib/banners.sh'; ask_master_pw(){ printf PROMPTED; }; get_master_pw"
    [ "$status" -eq 0 ]
    [ "$output" = "PROMPTED" ]
}

@test "session_extract routes extraction through the agent (B1)" {
    cat > "$TMP/bin/s3c-session-agent" <<'EOF'
#!/bin/bash
[[ "$1" == "extract-env" ]] && { printf 'FOO=bar'; exit 0; }
exit 0
EOF
    chmod +x "$TMP/bin/s3c-session-agent"
    run env GORILLA_SESSION_UNLOCK=true GORILLA_SESSION_AGENT="$TMP/bin/s3c-session-agent" \
        bash -c "source '$REPO/src/lib/banners.sh'; session_extract env ENV/proj"
    [ "$status" -eq 0 ]
    [ "$output" = "FOO=bar" ]
}

@test "sha256(tty) vector matches the agent's socketPath contract (HR #5)" {
    # The agent keys its socket on SHA256(tty); ssh-gorilla.sh must compute the SAME hash
    # or ssh can't find the agent. Pin the cross-language vector here (Swift side asserted
    # by test_agent_e2e.bats, which checks the socket lands at this exact path).
    run bash -c "printf '%s' '/dev/ttys003' | shasum -a 256 | cut -d' ' -f1"
    [ "$status" -eq 0 ]
    [ "$output" = "e5d96d283faaf77c73806e19389eeee274841377d60815eb511bb35b79f03bc5" ]
}

@test "env-gorilla --clear <proj> does not invoke touchid in password mode (B11)" {
    # GORILLA_TOUCHID points at a missing path → have_chip is false (password mode).
    # The OLD code ran "$GORILLA_TOUCHID" wrap-clear → "No such file" error.
    run env GORILLA_TOUCHID="$TMP/bin/does-not-exist" GORILLA_BANNERS=/dev/null \
        bash "$REPO/src/env-gorilla" --clear someproj
    [ "$status" -eq 0 ]
    [[ "$output" != *"No such file"* ]]
    [[ "$output" != *"command not found"* ]]
}
