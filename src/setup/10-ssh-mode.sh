# 10-ssh-mode.sh — LAST STEP. SSH keys into the vault + agent setup.
# Chip mode (install_ssh_step) and password mode (install_ssh_password_mode) share the
# key-import loop via _import_ssh_keys (HR #16); they differ only in the keys.json "mode"
# value and what happens AFTER import (LaunchAgent vs per-tty session agent).
section "[10/10] SSH mode + agent setup"

AGENT_DIR="$HOME/.s3c-gorilla"
PUB_DIR="$AGENT_DIR/pubkeys"
KEYS_JSON="$AGENT_DIR/keys.json"
LAUNCH_PLIST_SRC="$SRC_DIR/com.slav-it.s3c-ssh-agent.plist"
LAUNCH_PLIST_DST="$HOME/Library/LaunchAgents/com.slav-it.s3c-ssh-agent.plist"

mkdir -p "$AGENT_DIR" "$PUB_DIR"
chmod 700 "$AGENT_DIR" "$PUB_DIR"

# Shared key-import loop (HR #16) — its own file to keep this step under the 250-line cap.
source "$SETUP_DIR/import-ssh-keys.sh"

install_ssh_step() {
 # ---------- Pre-flight ----------
 info "This is the LAST step. Failure will NOT break the other tools just installed."
 item "Two SSH modes available:"
 item ""
 item "  1) chip-wrap (default, recommended) — works with your existing SSH key."
 item "     Boot-time: type master pw once → key chip-wraps into /tmp → Touch ID per sign."
 item "     Zero server-side changes. Works across multiple Macs (kdbx syncs)."
 item ""
 item "  2) se-born — key generated INSIDE the chip, cannot be exfiltrated."
 item "     Strongest coercion resistance. Requires updating authorized_keys on every server."
 item "     Per-Mac setup (chip keys don't roam)."
 item ""

 printf "%b%s %b" "$C7" "$TREE_MID" "$RESET"
 local mode_choice
 read -p "Which mode? [1/2, Enter=1]: " mode_choice
 mode_choice="${mode_choice:-1}"

 local GORILLA_SSH_MODE
 if [[ "$mode_choice" == "2" ]]; then
 GORILLA_SSH_MODE="se-born"
 else
 GORILLA_SSH_MODE="chip-wrap"
 fi

 # Persist the mode into user config so agent + tools read the same source.
 if [[ -f "$CONFIG_FILE" ]]; then
 if grep -q '^GORILLA_SSH_MODE=' "$CONFIG_FILE"; then
 sed -i '' "s/^GORILLA_SSH_MODE=.*/GORILLA_SSH_MODE=\"$GORILLA_SSH_MODE\"/" "$CONFIG_FILE"
 else
 echo "GORILLA_SSH_MODE=\"$GORILLA_SSH_MODE\"" >> "$CONFIG_FILE"
 fi
 fi

 # ---------- Mode 2: SE-born ----------
 if [[ "$GORILLA_SSH_MODE" == "se-born" ]]; then
 info "Generating SE-born ECDSA-P256 key (requires Touch ID)..."
 local key_name="main"
 local pub_line
 if ! pub_line=$("$BIN_DIR/touchid-gorilla" ssh-generate "$key_name" 2>&1); then
 error "ssh-generate failed: $pub_line"
 return 1
 fi
 echo "$pub_line" > "$PUB_DIR/$key_name.pub"
 echo "$pub_line" > "$HOME/.ssh/id_s3c-gorilla.pub"
 chmod 644 "$HOME/.ssh/id_s3c-gorilla.pub" 2>/dev/null || true
 success "Generated chip-born key '$key_name'"
 item "Public key saved to: $HOME/.ssh/id_s3c-gorilla.pub"
 echo ""
 echo "$pub_line"
 echo ""
 warn "Copy the line above to authorized_keys on every server you want to ssh into."
 warn "Example: ssh-copy-id -i ~/.ssh/id_s3c-gorilla.pub user@host"
 printf "%b%s %b" "$C7" "$TREE_MID" "$RESET"
 read -p "Press Enter once you've pushed the public key to your servers... " _

 # Write keys.json registry
 cat > "$KEYS_JSON" <<EOF
[
  {"name": "$key_name", "mode": "se-born", "keyType": "ecdsa-sha2-nistp256"}
]
EOF
 chmod 600 "$KEYS_JSON"
 success "Registry: $KEYS_JSON"

 # ---------- Mode 1: chip-wrap ----------
 else
 _import_ssh_keys "chip-wrap" || return 1
 fi

 # ---------- Install LaunchAgent (both modes) ----------
 info "Installing s3c-ssh-agent LaunchAgent..."
 mkdir -p "$HOME/Library/LaunchAgents"
 cp "$LAUNCH_PLIST_SRC" "$LAUNCH_PLIST_DST"
 launchctl bootout "gui/$UID/com.slav-it.s3c-ssh-agent" 2>/dev/null || true
 launchctl bootstrap "gui/$UID" "$LAUNCH_PLIST_DST" 2>/dev/null || {
 warn "launchctl bootstrap failed — agent will start on next login"
 }
 # Export SSH_AUTH_SOCK into launchd's environment so GUI apps launched
 # from Dock / Finder / Spotlight (which don't read .zprofile) inherit it.
 launchctl setenv SSH_AUTH_SOCK "$AGENT_DIR/agent.sock" 2>/dev/null || true
 success "LaunchAgent installed: $LAUNCH_PLIST_DST"
 item "SSH_AUTH_SOCK (shells + GUI apps) → $AGENT_DIR/agent.sock"

 # ---------- Smoke tests ----------
 info "Smoke test: verifying agent socket is responsive..."
 sleep 1
 if SSH_AUTH_SOCK="$AGENT_DIR/agent.sock" ssh-add -L &>/dev/null; then
 success "Agent responds to ssh-add -L"
 else
 # ssh-add -L returns non-zero if no keys yet — but the agent is still "up" if the socket exists.
 if [[ -S "$AGENT_DIR/agent.sock" ]]; then
 success "Agent socket present (no keys loaded yet — first ssh will bootstrap)"
 else
 warn "Agent socket not present — check /tmp/s3c-ssh-agent.err.log"
 fi
 fi

 printf "%b%s %b" "$C7" "$TREE_MID" "$RESET"
 local test_host
 read -p "Test a real SSH host? (hostname or Enter=skip): " test_host
 if [[ -n "$test_host" ]]; then
 local host_arg="$test_host"
 [[ "$test_host" != *@* ]] && host_arg="root@$test_host"
 # Capture ssh's OWN exit status — piping into `tail` would make the `if`
 # test tail's status (always 0) and falsely report success on auth failure.
 local ssh_out ssh_rc
 ssh_out="$(SSH_AUTH_SOCK="$AGENT_DIR/agent.sock" \
 ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new "$host_arg" exit 2>&1)"
 ssh_rc=$?
 printf '%s\n' "$ssh_out" | tail -5
 if [[ $ssh_rc -eq 0 ]]; then
 success "Connected to $test_host — end-to-end works"
 else
 warn "SSH to $test_host failed — check /tmp/s3c-ssh-agent.err.log"
 warn "Common causes: public key not yet on remote (Mode 2), master pw prompt cancelled (Mode 1)."
 fi
 fi

 return 0
}

# Password-mode SSH: vault keys served by the per-tty s3c-session-agent (no Secure Enclave).
# keys.json entries carry mode "password"; ssh-gorilla.sh wires SSH_AUTH_SOCK per-tab.
install_ssh_password_mode() {
 if [[ ! -x "$BIN_DIR/s3c-session-agent" ]]; then
 warn "s3c-session-agent not installed — SSH needs it; skipping."; return 1
 fi
 _import_ssh_keys "password" || return 1
 # Verify the vault actually has a usable key — don't claim "SSH ready" on a dead vault.
 _verify_vault_ssh_keys || warn "SSH key check FAILED — 'ssh' will not authenticate until the vault has a real private key."
 # No LaunchAgent in password mode — ssh-gorilla.sh points SSH_AUTH_SOCK at the
 # per-tty s3c-session-agent socket and unlocks it on first `ssh` (one prompt/tab).
 item "SSH served by the per-tty session agent — first 'ssh' in a tab prompts once,"
 item "then env/otp/ssh share that unlock. (GUI SSH clients need chip mode.)"
 return 0
}

if ! $HAS_TOUCHID; then
 if install_ssh_password_mode; then
 success "Password-mode SSH ready — vault keys via s3c-session-agent (master pw per session)"
 else
 warn "Password-mode SSH skipped — env-gorilla / otp-gorilla still work. Re-run to retry."
 fi
 # chip-wrap/se-born config value is irrelevant in password mode (keys.json uses
 # mode "password"); comment any inherited GORILLA_SSH_MODE to avoid confusion.
 if [[ -f "$CONFIG_FILE" ]] && grep -q '^GORILLA_SSH_MODE=' "$CONFIG_FILE"; then
 sed -i '' 's/^GORILLA_SSH_MODE=/#GORILLA_SSH_MODE=/' "$CONFIG_FILE"
 fi
elif install_ssh_step; then
 success "SSH setup complete (mode: $(grep '^GORILLA_SSH_MODE=' "$CONFIG_FILE" 2>/dev/null | cut -d= -f2 | tr -d '"'))"
else
 warn "SSH setup bailed — env-gorilla / otp-gorilla still work. Re-run ./install.sh to retry."
fi
true
