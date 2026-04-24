#!/usr/bin/env bash
# scripts/dev-setup-check.sh — environment sanity check for s3c-gorilla.
#
# Run any time; especially after macOS upgrades, KeePassXC version
# bumps, or Xcode CLT updates. Validates every assumption baked
# into PLAN.md (toolchain, signing, keepassxc-cli XML export
# format, macOS limits).
#
# Exit 0 on pass (warnings OK), 1 on any FAIL.

set -u
PASS=0 WARN=0 FAIL=0
FAILED=()

pass()    { printf '  [PASS] %s\n' "$*"; PASS=$((PASS+1)); }
warn()    { printf '  [WARN] %s\n' "$*"; WARN=$((WARN+1)); }
fail()    { printf '  [FAIL] %s\n' "$*"; FAIL=$((FAIL+1)); FAILED+=("$*"); }
info()    { printf '         %s\n' "$*"; }
section() { printf '\n=== %s ===\n' "$*"; }

# ---- 1. Platform ----
section "Platform"
macos=$(sw_vers -productVersion 2>/dev/null || echo '?')
[[ "${macos%%.*}" -ge 12 ]] 2>/dev/null \
    && pass "macOS $macos (need 12+)" \
    || fail "macOS $macos — need 12 (Monterey) or later"

arch=$(uname -m)
case "$arch" in
    arm64|x86_64) pass "arch $arch" ;;
    *) fail "unexpected arch $arch (need arm64 or x86_64)" ;;
esac

# ---- 2. Toolchain ----
section "Toolchain"
if command -v swift >/dev/null; then
    pass "$(swift --version 2>&1 | head -1)"
else
    fail "swift not found — install: xcode-select --install"
fi

if command -v git >/dev/null; then
    pass "git $(git --version | awk '{print $3}')"
else
    fail "git not found (needed for curl-bash install bootstrap)"
fi

for bin in codesign security launchctl find xattr stat; do
    if command -v "$bin" >/dev/null; then pass "$bin present"
    else fail "$bin not found"; fi
done

# sort -V probe (Concern #35 / N6)
if printf '10\n9\n' | sort -V 2>/dev/null | head -1 | grep -q '^9$'; then
    pass "sort -V works (orchestrator uses it directly)"
else
    warn "sort -V unavailable — orchestrator will fall back to lexical + two-digit-pad convention"
fi

# ---- 3. Signing identity ----
section "Signing identity"
id_lines=$(security find-identity -v -p codesigning 2>/dev/null \
    | grep -E 'Developer ID|Apple Development|Apple Distribution' || true)
if [[ -n "$id_lines" ]]; then
    pass "$(echo "$id_lines" | wc -l | tr -d ' ') codesigning identit(y|ies) available"
    if grep -q 'Developer ID Application' <<<"$id_lines"; then
        pass "Developer ID Application cert present (preferred for SE entitlement)"
    else
        warn "no 'Developer ID Application' cert — Apple Development works locally but can't distribute"
    fi
else
    fail "no codesigning identity — Xcode → Preferences → Accounts → Manage Certificates → +"
fi

# ---- 4. KeePassXC ----
section "KeePassXC"
if command -v keepassxc-cli >/dev/null; then
    kxv=$(keepassxc-cli --version 2>&1 | head -1)
    pass "keepassxc-cli $kxv"
    kxmaj=${kxv%%.*}
    kxrest=${kxv#*.}
    kxmin=${kxrest%%.*}
    if [[ "$kxmaj" -gt 2 || ( "$kxmaj" -eq 2 && "$kxmin" -ge 7 ) ]] 2>/dev/null; then
        pass "version >= 2.7 (XML export format verified for this branch)"
    else
        fail "keepassxc-cli $kxv < 2.7 — upgrade: brew upgrade --cask keepassxc"
    fi
else
    fail "keepassxc-cli missing — install: brew install --cask keepassxc"
fi

if [[ -d /Applications/KeePassXC.app ]]; then
    bid=$(defaults read /Applications/KeePassXC.app/Contents/Info.plist CFBundleIdentifier 2>/dev/null)
    if [[ "$bid" == "org.keepassxc.keepassxc" ]]; then
        pass "bundle ID $bid (matches Concern #40 default allowlist)"
    else
        warn "bundle ID '$bid' — default allowlist expects org.keepassxc.keepassxc"
    fi
else
    warn "KeePassXC.app not in /Applications — SSH Agent push (Phase 2) disabled; CLI-only use fine"
fi

if command -v terminal-notifier >/dev/null; then
    pass "terminal-notifier $(terminal-notifier -help 2>&1 | head -1 | awk '{print $2}' | tr -d '()')"
else
    warn "terminal-notifier missing — otp-gorilla notifications won't work (brew install terminal-notifier)"
fi

# ---- 5. macOS limits ----
section "macOS limits"
ml=$(ulimit -l)
if [[ "$ml" == unlimited ]]; then
    pass "ulimit -l = unlimited"
elif [[ "$ml" -ge 49152 ]] 2>/dev/null; then
    pass "ulimit -l = $ml KiB (>= 48 MiB)"
else
    warn "ulimit -l = $ml KiB — fan-out needs >= 49152 KiB. Add 'ulimit -l 49152' to ~/.zprofile."
fi

ml_sys=$(launchctl limit memlock 2>&1 | awk '/memlock/ {print $2}')
if [[ "$ml_sys" == unlimited ]]; then
    pass "system memlock unlimited"
else
    info "system memlock: $ml_sys (agent plist SoftResourceLimits will override)"
fi

# ---- 6. Scan infra ----
section "Scan infrastructure"
tmpd=$(mktemp -d /tmp/devcheck-XXXXXX)
touch "$tmpd/O'Brien's.kdbx"
found=$(find "$tmpd" -type f -name '*.kdbx' -print0 2>/dev/null | xargs -0 ls 2>/dev/null | wc -l | tr -d ' ')
[[ "$found" -eq 1 ]] && pass "find -print0 handles apostrophes" || fail "find -print0 apostrophe test"
rm -rf "$tmpd"

command -v bats >/dev/null \
    && pass "bats-core $(bats --version 2>&1 | head -1)" \
    || warn "bats-core missing — needed only for src/tests/shell/ (brew install bats-core)"

# ---- 7. Existing install state ----
section "Existing install (cleanup targets)"
stale=()
for b in fs-gorilla llm-gorilla firewall-gorilla; do
    [[ -e "/usr/local/bin/$b" ]] && stale+=("/usr/local/bin/$b")
done
[[ -e "$HOME/.config/s3c-gorilla/master.blob" ]] && stale+=("$HOME/.config/s3c-gorilla/master.blob")
for decor in colorize.sh godfather.sh; do
    [[ -e "/usr/local/share/s3c-gorilla/$decor" ]] && stale+=("/usr/local/share/s3c-gorilla/$decor")
done
[[ -d "/usr/local/share/s3c-gorilla/fs_gorilla" ]] && stale+=("/usr/local/share/s3c-gorilla/fs_gorilla/")

if [[ ${#stale[@]} -eq 0 ]]; then
    pass "no out-of-scope / legacy artifacts lingering"
else
    warn "out-of-scope artifacts from older install (remove before re-install):"
    for s in "${stale[@]}"; do info "  - $s"; done
fi

# ---- 8. Phase 0 — keepassxc-cli XML export behaviour ----
section "Phase 0 — keepassxc-cli XML export probes"
if ! command -v keepassxc-cli >/dev/null; then
    warn "keepassxc-cli unavailable — skipping Phase 0 probes"
else
    TESTDB=$(mktemp -u /tmp/devcheck-probe-XXXX.kdbx)
    KEY=$(mktemp /tmp/devcheck-probe-key-XXXX)
    WRONG=$(mktemp /tmp/devcheck-probe-wrong-XXXX)
    ATTACH=$(mktemp /tmp/devcheck-probe-attach-XXXX)
    OUT=$(mktemp /tmp/devcheck-probe-out-XXXX.xml)
    WRONG_OUT=$(mktemp /tmp/devcheck-probe-wrong-XXXX.xml)
    trap 'rm -f "$TESTDB" "$KEY" "$WRONG" "$ATTACH" "$OUT" "$WRONG_OUT"' EXIT

    head -c 128 /dev/urandom > "$KEY"
    head -c 128 /dev/urandom > "$WRONG"
    printf 'FAKE-SSH-KEY-BYTES\n' > "$ATTACH"

    if keepassxc-cli db-create --set-key-file "$KEY" "$TESTDB" >/dev/null 2>&1; then
        keepassxc-cli mkdir -q --no-password --key-file "$KEY" "$TESTDB" SSH >/dev/null 2>&1
        keepassxc-cli add -q --no-password --key-file "$KEY" "$TESTDB" SSH/test >/dev/null 2>&1
        keepassxc-cli attachment-import -q --no-password --key-file "$KEY" \
            "$TESTDB" SSH/test id_rsa "$ATTACH" >/dev/null 2>&1

        # A: stdout export
        keepassxc-cli export --no-password --key-file "$KEY" --format xml "$TESTDB" \
            > "$OUT" 2>/dev/null
        ex=$?
        if [[ "$ex" -eq 0 && -s "$OUT" ]]; then
            pass "XML stdout export (exit 0, $(wc -c <"$OUT") bytes)"
        else
            fail "XML stdout export failed (exit=$ex, size=$(wc -c <"$OUT" 2>/dev/null || echo 0))"
        fi

        # B: attachment encoding
        if grep -qE '<Binary ID=' "$OUT" && grep -qE 'Value Ref=' "$OUT"; then
            pass "Meta/Binaries + Value Ref= format confirmed (parser spec matches)"
        else
            fail "attachment encoding NOT in expected Meta/Binaries + Ref format — PLAN.md §2a parser needs revision"
        fi

        # C: Compressed attr
        comp=$(grep -oE 'Compressed="[^"]*"' "$OUT" | sort -u)
        case "$comp" in
            'Compressed="True"') pass "attachments gzip-compressed (needs Foundation.Compression)" ;;
            '') warn "no Compressed attr — attachment may be below keepassxc-cli's compression threshold; verify on real vault" ;;
            *)  info "Compressed values: $comp" ;;
        esac

        # D: wrong key fail-closed
        keepassxc-cli export --no-password --key-file "$WRONG" --format xml "$TESTDB" \
            > "$WRONG_OUT" 2>/dev/null
        wex=$?
        wsize=$(wc -c <"$WRONG_OUT")
        if [[ "$wex" -ne 0 && "$wsize" -eq 0 ]]; then
            pass "wrong credential → exit=$wex, zero stdout bytes (fail-closed)"
        else
            fail "wrong credential NOT fail-closed (exit=$wex, stdout=$wsize bytes) — §2b integrity check needs revision"
        fi
    else
        fail "keepassxc-cli db-create failed — can't run Phase 0 probes"
    fi
fi

# ---- 9. User vault size (if config present) ----
section "User vault sanity (optional)"
if [[ -f "$HOME/.config/s3c-gorilla/config" ]]; then
    # shellcheck disable=SC1090
    GORILLA_DB=""
    source "$HOME/.config/s3c-gorilla/config" 2>/dev/null || true
    if [[ -n "${GORILLA_DB:-}" && -f "$GORILLA_DB" ]]; then
        sz=$(stat -f %z "$GORILLA_DB" 2>/dev/null || echo 0)
        mib=$(( sz / 1048576 ))
        if [[ "$mib" -le 24 ]]; then
            pass "kdbx $mib MiB (within default 32 MiB mlock budget)"
        else
            warn "kdbx $mib MiB > 24 MiB. XML export likely over the 32 MiB budget. Bump GORILLA_MLOCK_BUDGET in ~/.config/s3c-gorilla/config."
        fi
    else
        info "GORILLA_DB not set or file missing — skipped"
    fi
else
    info "no ~/.config/s3c-gorilla/config yet — skipped"
fi

# ---- summary ----
printf '\n=== SUMMARY ===\n'
printf '  pass: %d\n  warn: %d\n  fail: %d\n' "$PASS" "$WARN" "$FAIL"
if (( FAIL > 0 )); then
    printf '\nFAILED:\n'
    for f in "${FAILED[@]}"; do printf '  - %s\n' "$f"; done
    exit 1
fi
exit 0
