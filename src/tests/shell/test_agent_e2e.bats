#!/usr/bin/env bats
# test_agent_e2e.bats — the REAL cross-process round-trip (no mock agent). Builds the actual
# s3c-session-agent and exercises it. macOS + swiftc only; skips elsewhere (HR #19/#20/#5/#12).

setup() {
    [[ "$(uname)" == "Darwin" ]] || skip "s3c-session-agent needs macOS frameworks"
    command -v swiftc >/dev/null || skip "swiftc not available"
    REPO="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
    source "$REPO/scripts/swift-targets.sh"
    TMP="$(mktemp -d)"; export HOME="$TMP/home"; mkdir -p "$HOME"
    AGENT="$TMP/s3c-session-agent"
    local srcs=""; for s in $(swift_sources s3c-session-agent); do srcs+=" $REPO/src/$s"; done
    swiftc $srcs $(swift_frameworks s3c-session-agent) -o "$AGENT" 2>"$TMP/build.err" \
        || { cat "$TMP/build.err"; skip "agent build failed"; }
}
teardown() {
    [[ -n "${AGENT:-}" && -x "$AGENT" ]] && "$AGENT" stop /dev/ttys003 2>/dev/null
    [[ -n "${AGENT:-}" ]] && pkill -f "$AGENT __serve" 2>/dev/null
    [[ -n "${TMP:-}" && -d "$TMP" ]] && rm -rf "$TMP"
}

@test "local TOTP matches the RFC 6238 vector (base32Decode + totpAt)" {
    run "$AGENT" __totptest
    [ "$status" -eq 0 ]
    [ "$output" = "94287082" ]
}

@test "socket lands at the SHA256(tty) contract path; get returns the pw; stop clears it" {
    printf 'MASTERPW' | "$AGENT" start /dev/ttys003 0
    # SHA256("/dev/ttys003") — the exact hash the agent and ssh-gorilla.sh both compute.
    sock="$HOME/.s3c-gorilla/session/e5d96d283faaf77c73806e19389eeee274841377d60815eb511bb35b79f03bc5.sock"
    for _ in $(seq 1 15); do [[ -S "$sock" ]] && break; sleep 0.2; done
    [ -S "$sock" ]
    run "$AGENT" get /dev/ttys003
    [ "$output" = "MASTERPW" ]
    "$AGENT" stop /dev/ttys003
    for _ in $(seq 1 10); do [[ -e "$sock" ]] || break; sleep 0.2; done
    [ ! -e "$sock" ]
}
