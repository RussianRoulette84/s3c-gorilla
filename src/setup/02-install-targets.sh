# 02-install-targets.sh — prime sudo (+ keepalive) and create the share dir.
section "[2/10] Install targets"
info "CLIs → $BIN_DIR   (s3c-gorilla, env-gorilla, otp-gorilla, ssh-gorilla.sh)"
info "Agents → $BIN_DIR   (s3c-session-agent, s3c-kdbx-parse; + touchid-gorilla & s3c-ssh-agent on Touch ID Macs)"
info "Helpers → $SHARE_DIR   (banners, godfather, scan + keychain libs)"
info "Config → ~/.config/s3c-gorilla/config"
info "Logs → ~/Library/Logs/s3c-gorilla/"

# Prime sudo so every sudo-install in steps 4/5/10 is prompt-free (and the
# godfather only appears at most once, on the initial prompt).
if ! sudo -n true 2>/dev/null; then
 if [[ -r "$SCRIPT_DIR/src/lib/godfather.sh" ]]; then
 source "$SCRIPT_DIR/src/lib/godfather.sh"
 show_godfather root
 fi
 sudo -v
fi

# Keep sudo alive for the rest of the installer (macOS's default cache is ~5min;
# this background loop refreshes it so longer steps don't re-prompt).
( while true; do sudo -n true; sleep 45; kill -0 "$$" 2>/dev/null || exit; done ) 2>/dev/null &
SUDO_KEEPALIVE_PID=$!
# disown so bash doesn't print "Terminated: 15" when the trap kills it on exit.
disown "$SUDO_KEEPALIVE_PID" 2>/dev/null || true
trap 'kill "$SUDO_KEEPALIVE_PID" 2>/dev/null; rm -rf "$BUILD_DIR"' EXIT

sudo install -d -m 0755 -o root -g wheel "$SHARE_DIR"
success "Ready"
true
