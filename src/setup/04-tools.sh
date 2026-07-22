# 04-tools.sh — install the shell CLIs + helper libs + compile s3c-session-agent.
section "[4/11] Installing tools"

# CLIs → /usr/local/bin (owned by root, world-executable). Only ship the CLIs
# that actually exist in src/ (a missing source under `set -e` would abort the
# installer).
for tool in env-gorilla otp-gorilla ssh-gorilla.sh s3c-gorilla; do
 if [[ -f "$SRC_DIR/$tool" ]]; then
 sudo install -m 0555 -o root -g wheel "$SRC_DIR/$tool" "$BIN_DIR/$tool"
 success "$tool → $BIN_DIR/$tool"
 else
 skip "$tool not in src/ — not installed"
 fi
done

# Record where we were installed from so `s3c-gorilla setup` can re-run the installer.
echo "$SCRIPT_DIR" | sudo tee "$SHARE_DIR/install-source" >/dev/null 2>&1 || true

# Sourced helpers → /usr/local/share/s3c-gorilla (readable libs, not $PATH)
sudo install -m 0644 -o root -g wheel "$SCRIPT_DIR/src/lib/godfather.sh" "$SHARE_DIR/godfather.sh"
sudo install -m 0644 -o root -g wheel "$SCRIPT_DIR/src/lib/banners.sh" "$SHARE_DIR/banners.sh"
sudo install -m 0644 -o root -g wheel "$SCRIPT_DIR/src/lib/drunken-bishop.sh" "$SHARE_DIR/drunken-bishop.sh"
sudo install -m 0644 -o root -g wheel "$SCRIPT_DIR/src/lib/ywizz/colorize.sh" "$SHARE_DIR/colorize.sh"
[[ -f "$SCRIPT_DIR/src/lib/s3c-scan.sh" ]] && sudo install -m 0644 -o root -g wheel "$SCRIPT_DIR/src/lib/s3c-scan.sh" "$SHARE_DIR/s3c-scan.sh"
[[ -f "$SCRIPT_DIR/src/lib/s3c-keychain.sh" ]] && sudo install -m 0644 -o root -g wheel "$SCRIPT_DIR/src/lib/s3c-keychain.sh" "$SHARE_DIR/s3c-keychain.sh"
[[ -f "$SCRIPT_DIR/src/lib/s3c-infisical.sh" ]] && sudo install -m 0644 -o root -g wheel "$SCRIPT_DIR/src/lib/s3c-infisical.sh" "$SHARE_DIR/s3c-infisical.sh"
success "godfather.sh → $SHARE_DIR/godfather.sh"
success "banners.sh → $SHARE_DIR/banners.sh"
success "drunken-bishop.sh → $SHARE_DIR/drunken-bishop.sh"
success "colorize.sh → $SHARE_DIR/colorize.sh"
[[ -f "$SHARE_DIR/s3c-scan.sh" ]] && success "s3c-scan.sh → $SHARE_DIR/s3c-scan.sh"
[[ -f "$SHARE_DIR/s3c-keychain.sh" ]] && success "s3c-keychain.sh → $SHARE_DIR/s3c-keychain.sh"
[[ -f "$SHARE_DIR/s3c-infisical.sh" ]] && success "s3c-infisical.sh → $SHARE_DIR/s3c-infisical.sh"

# s3c-session-agent — memory-only per-tty master-password holder for the optional
# "keep unlocked for this terminal session" feature. No Secure Enclave needed, so
# it builds (ad-hoc signed) on any Mac including Intel / Hackintosh.
if command -v swiftc &>/dev/null; then
 info "Compiling s3c-session-agent..."
 SESS_SRC="$BUILD_DIR/s3c-session-agent.swift"
 SESS_BIN="$BUILD_DIR/s3c-session-agent"
 cp "$SRC_DIR/s3c-session-agent.swift" "$SESS_SRC"
 cp "$SRC_DIR/ssh-agent-core.swift" "$BUILD_DIR/ssh-agent-core.swift"   # ssh protocol (B3)
 cp "$SRC_DIR/ssh-wire.swift" "$BUILD_DIR/ssh-wire.swift"               # shared wire helpers (#13)
 cp "$SRC_DIR/ssh-rsa.swift" "$BUILD_DIR/ssh-rsa.swift"                 # shared RSA signing (#RSA)
 if swiftc "$SESS_SRC" "$BUILD_DIR/ssh-agent-core.swift" "$BUILD_DIR/ssh-wire.swift" "$BUILD_DIR/ssh-rsa.swift" $(swift_frameworks s3c-session-agent) -o "$SESS_BIN" 2>/dev/null; then
 sign_binary "$SESS_BIN" || true
 sudo install -m 0555 -o root -g wheel "$SESS_BIN" "$BIN_DIR/s3c-session-agent"
 sudo xattr -cr "$BIN_DIR/s3c-session-agent" 2>/dev/null || true
 success "s3c-session-agent → $BIN_DIR/s3c-session-agent"
 # Old agents are still running the PREVIOUS binary and squatting on per-tty sockets —
 # kill them and clear stale sockets so the next unlock spawns the freshly-installed agent
 # on a clean socket (no EADDRINUSE, no duplicate processes). Open tabs simply re-unlock.
 if pkill -f "s3c-session-agent __serve" 2>/dev/null; then
 info "Stopped running session agents (they'll re-spawn fresh on next use)"
 fi
 [[ -d "$HOME/.s3c-gorilla/session" ]] && find "$HOME/.s3c-gorilla/session" -type s -delete 2>/dev/null || true
 else
 warn "s3c-session-agent failed to compile — session-unlock falls back to per-call prompts"
 fi
else
 skip "swiftc not found — skipping s3c-session-agent (session-unlock needs it)"
fi

# s3c-kdbx-parse — Foundation-only XML parser for the one-unlock fan-out fast path (#X).
if command -v swiftc &>/dev/null && [[ -f "$SRC_DIR/s3c-kdbx-parse.swift" ]]; then
 KP_BIN="$BUILD_DIR/s3c-kdbx-parse"
 if swiftc "$SRC_DIR/s3c-kdbx-parse.swift" -o "$KP_BIN" 2>/dev/null; then
 sign_binary "$KP_BIN" || true
 sudo install -m 0555 -o root -g wheel "$KP_BIN" "$BIN_DIR/s3c-kdbx-parse"
 sudo xattr -cr "$BIN_DIR/s3c-kdbx-parse" 2>/dev/null || true
 success "s3c-kdbx-parse → $BIN_DIR/s3c-kdbx-parse"
 else
 warn "s3c-kdbx-parse failed to compile — fan-out uses the per-secret path"
 fi
fi

# App icon → share dir so the unlock window can load + glow it.
if [[ -f "$SCRIPT_DIR/icon.png" ]]; then
 sudo install -m 0644 -o root -g wheel "$SCRIPT_DIR/icon.png" "$SHARE_DIR/icon.png"
 success "icon.png → $SHARE_DIR/icon.png"
fi

# Homer sounds → share dir (unlock window: D'oh on a wrong pw, Woohoo when you finally get in).
if [[ -d "$SRC_DIR/sounds" ]]; then
 sudo mkdir -p "$SHARE_DIR/sounds"
 sudo install -m 0644 -o root -g wheel "$SRC_DIR"/sounds/*.mp3 "$SHARE_DIR/sounds/" 2>/dev/null \
   && success "sounds → $SHARE_DIR/sounds/"
fi

# s3c-unlock-window — native AppKit vault-unlock window the SSH agent spawns on a cold unlock.
# Optional: if it fails to build, the agent falls back to the plain osascript prompt.
if command -v swiftc &>/dev/null && [[ -f "$SRC_DIR/s3c-unlock-window.swift" ]]; then
 UW_BIN="$BUILD_DIR/s3c-unlock-window"
 UW_SRCS=""; for _s in $(swift_sources s3c-unlock-window); do UW_SRCS="$UW_SRCS $SRC_DIR/$_s"; done
 if swiftc $UW_SRCS $(swift_frameworks s3c-unlock-window) -o "$UW_BIN" 2>/dev/null; then
 sign_binary "$UW_BIN" || true
 sudo install -m 0555 -o root -g wheel "$UW_BIN" "$BIN_DIR/s3c-unlock-window"
 sudo xattr -cr "$BIN_DIR/s3c-unlock-window" 2>/dev/null || true
 success "s3c-unlock-window → $BIN_DIR/s3c-unlock-window"
 else
 warn "s3c-unlock-window failed to compile — SSH unlock falls back to the plain prompt"
 fi
fi
true
