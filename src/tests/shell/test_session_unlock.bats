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

# --- unlock window → session-agent lifetime (Wave 4: Macs without Touch ID) ---
# The window prints "pw / scope= / askpw= / ttl=" and session_unlock must turn that into the
# TTL seconds it passes to `s3c-session-agent start`. Mock both sides and read back arg 4.

_mock_agent() {   # writes a mock agent that records `start`'s ttl arg into $TMP/ttl
    cat > "$TMP/bin/s3c-session-agent" <<EOF
#!/bin/bash
if [[ "\$1" == "get" ]]; then [[ -f "$TMP/ttl" ]] && exit 0; exit 1; fi
if [[ "\$1" == "start" ]]; then cat >/dev/null; printf '%s' "\$4" > "$TMP/ttl"; exit 0; fi
exit 0
EOF
    chmod +x "$TMP/bin/s3c-session-agent"
}
_mock_window() {  # $1 = scope, $2 = ttl minutes
    cat > "$TMP/bin/s3c-unlock-window" <<EOF
#!/bin/bash
printf 'WINPW\nscope=$1\naskpw=0\nttl=$2\n'
EOF
    chmod +x "$TMP/bin/s3c-unlock-window"
}
_run_session_unlock() {
    run env GORILLA_SESSION_UNLOCK=true GORILLA_SESSION_AGENT="$TMP/bin/s3c-session-agent" \
        GORILLA_UNLOCK_WINDOW="$TMP/bin/s3c-unlock-window" SSH_CONNECTION= \
        bash -c "source '$REPO/src/lib/banners.sh'; ask_master_pw(){ printf FALLBACK; }; session_unlock"
}

@test "session_unlock: window 'just once' → short idle TTL" {
    _mock_agent; _mock_window once 0
    _run_session_unlock
    [ "$status" -eq 0 ]
    [ "$(cat "$TMP/ttl")" = "30" ]
}

@test "session_unlock: window timer 15 min → 900 seconds" {
    _mock_agent; _mock_window session 15
    _run_session_unlock
    [ "$status" -eq 0 ]
    [ "$(cat "$TMP/ttl")" = "900" ]
}

@test "session_unlock: window 'until lock' → 0 (use the configured TTL)" {
    _mock_agent; _mock_window session 0
    _run_session_unlock
    [ "$status" -eq 0 ]
    [ "$(cat "$TMP/ttl")" = "0" ]
}

@test "session_unlock: no window installed → plain prompt, configured TTL" {
    _mock_agent
    run env GORILLA_SESSION_UNLOCK=true GORILLA_SESSION_AGENT="$TMP/bin/s3c-session-agent" \
        GORILLA_UNLOCK_WINDOW="$TMP/bin/nope" SSH_CONNECTION= \
        bash -c "source '$REPO/src/lib/banners.sh'; ask_master_pw(){ printf FALLBACK; }; session_unlock"
    [ "$status" -eq 0 ]
    [ "$(cat "$TMP/ttl")" = "0" ]
}

@test "session_unlock: remote shell never draws a window" {
    _mock_agent
    cat > "$TMP/bin/s3c-unlock-window" <<EOF
#!/bin/bash
printf 'WINPW\nscope=once\naskpw=0\nttl=0\n'
touch "$TMP/window-ran"
EOF
    chmod +x "$TMP/bin/s3c-unlock-window"
    run env GORILLA_SESSION_UNLOCK=true GORILLA_SESSION_AGENT="$TMP/bin/s3c-session-agent" \
        GORILLA_UNLOCK_WINDOW="$TMP/bin/s3c-unlock-window" SSH_CONNECTION="1.2.3.4 22 5.6.7.8 22" \
        bash -c "source '$REPO/src/lib/banners.sh'; ask_master_pw(){ printf FALLBACK; }; session_unlock"
    [ "$status" -eq 0 ]
    [ ! -f "$TMP/window-ran" ]
}
