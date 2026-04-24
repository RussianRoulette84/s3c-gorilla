#!/bin/bash
##########################################################################################
## s3c-gorilla — Installer
## Detects Touch ID hardware and offers to install touchid-gorilla; can be
## skipped interactively to fall back to master-password prompts.
## Installs: env-gorilla, ssh-gorilla, touchid-gorilla
##########################################################################################

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC_DIR="$SCRIPT_DIR/src" # tool sources live here since the reorg
BIN_DIR="/usr/local/bin" # CLIs (needs sudo to write)
SHARE_DIR="/usr/local/share/s3c-gorilla" # sourced helpers: colorize.sh, godfather.sh
CONFIG_DIR="$HOME/.config/s3c-gorilla" # user config (keep)
CONFIG_FILE="$CONFIG_DIR/config"
BUILD_DIR="$(mktemp -d -t s3c-gorilla-build)" # scratch for swiftc output
trap 'rm -rf "$BUILD_DIR"' EXIT

# Mirror all install output to ./logs/s3c-gorilla.log for post-mortem.
# /dev/tty preserved for read prompts, so interactivity is unaffected.
mkdir -p "$SCRIPT_DIR/logs"
LOG_FILE="$SCRIPT_DIR/logs/s3c-gorilla.log"
exec > >(tee -a "$LOG_FILE") 2> >(tee -a "$LOG_FILE" >&2)
echo "===== install.sh run: $(date) =====" >> "$LOG_FILE"

# ywizz TUI helpers — purple accent for status lines
source "$SCRIPT_DIR/lib/ywizz/ywizz.sh"
accent_color="$C7"

# Section header with blank-line separator and ywizz tree/diamond prefix.
section() { echo ""; header_tui "$1"; }

# Body-text line with the purple │ tree prefix (no status tag).
item() { style_item "$1"; }

# Skipped-step line (neutral dim, purple prefix).
skip() { printf "%b%s %b[SKIP]%b %s\n" "$C7" "$TREE_MID" "$DIM" "$RESET" "$1" >&2; }

# Source either the live user config (if already installed) or config.example
# so step 8's DB-existence check reflects what the tools will actually use.
if [[ -f "$CONFIG_FILE" ]]; then
 source "$CONFIG_FILE"
elif [[ -f "$SCRIPT_DIR/config.example" ]]; then
 source "$SCRIPT_DIR/config.example"
fi
DB_PATH="${GORILLA_DB:-$HOME/Library/Mobile Documents/com~apple~CloudDocs/KeePassKeePassDB.kdbx}"

cat << 'EOF' | zsh "$SCRIPT_DIR/lib/ywizz/colorize.sh" -s 1 -e 20
    ⢀⣠⣴⠶⠚⠛⢶⣄
    ⢸⣿⣿⣿⡆  ⠙⢷⣄
   ⣰⣿⣿⣿⣿⣿⣿⣷⣶⣶⣿⣦⡀
  ⣴⣿⠿⠿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣷⣤⣤⣄⣀⡀
 ⠘⣥⣤⠶⣶⣼⣿⣿⠟⠁ ⠉⠛⠿⣿⣿⣿⡟⠛⠻⢷⡄
 ⢠⡞⠛⠒⣿⣿⣿⠏     ⣠⣾⣿⣿⣿⡄  ⠻⣦⡀
⢠⡎ ⣴⣶⣿⣿⡟    ⢠⣾⣿⣿⣿⣿⣿⣷   ⠈⠻⣷⣄⡀⢀⣀⣠⣤⣤⣤⣤⣄⣀
⢮⣉⣹⣿⣿⣿⣿⡇ ⢠⣀⣴⣿⣿⣿⣿⣿⣿⣿⣿     ⠈⠛⠟⠛⠛⠋⠉⠉⠉⠉⠉⠻⣷⣄
 ⠹⣿⣿⣿⡟⢸ ⢀⣾⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⡄              ⠈⢿⣧⡀
  ⠘⠿⠟⠃⢸ ⣼⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣷  ⡴      ⢀⣠⣤⣄⡀  ⢻⣿⣆
      ⢸⣷⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣧⣴⡇   ⣀⣴⣾⣿⣿⣿⣿⣿⣶⣄ ⢻⣿⣷⡀
      ⢸⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⡟⣿⣿⣿⣿⣿⣿⢁⣠⣶⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣾⣿⣿⣿⣆         /$$$$$$   /$$$$$$   /$$$$$$         /$$$$$$   /$$$$$$  /$$$$$$$  /$$$$$$ /$$       /$$        /$$$$$$
     ⢠⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⠟⣰⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⡀       /$$__  $$ /$$__  $$ /$$__  $$       /$$__  $$ /$$__  $$| $$__  $$|_  $$_/| $$      | $$       /$$__  $$
    ⢀⡿⠁⣿⣿⣿⣿⣿⣿⣿⣿⠟⠁⣰⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⡇      | $$  \__/|__/  \ $$| $$  \__/      | $$  \__/| $$  \ $$| $$  \ $$  | $$  | $$      | $$      | $$  \ $$
    ⣸⠃ ⣿⣿⣿⣿⣿⣿⣿⠃ ⠈⠛⠛⢻⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣇⡀     |  $$$$$$    /$$$$$/| $$            | $$ /$$$$| $$  | $$| $$$$$$$/  | $$  | $$      | $$      | $$$$$$$$
    ⣿  ⣿⣿⣿⣿⣿⣿⣿ ⣾⣿⣿⣷⡀⠙⢿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⡿⠛⣡⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⡅⠙⠳⢦⡀   \____  $$  |___  $$| $$            | $$|_  $$| $$  | $$| $$__  $$  | $$  | $$      | $$      | $$__  $$
   ⢰⡏  ⣿⣿⣿⣿⣿⣿⡇ ⣿⣿⣿⣿⣿⣶⣄⠈⠛⠿⢿⣿⡿⠿⠟⠋⣁⣴⣾⣿⡟⠁⠸⣿⣿⣿⣿⣿⣿⣿⣇  ⠈⣷   /$$  \ $$ /$$  \ $$| $$    $$      | $$  \ $$| $$  | $$| $$  \ $$  | $$  | $$      | $$      | $$  | $$
   ⢸⡇  ⣿⣿⣿⣿⣿⣿⠃ ⢿⣿⣿⣿⣿⣿⣿     ⣠⣴⣶⣿⣿⣿⣿⡏   ⠈⠙⢿⣿⣿⣿⣿⣿⣆  ⢸⡆  |  $$$$$$/|  $$$$$$/|  $$$$$$/      |  $$$$$$/|  $$$$$$/| $$  | $$ /$$$$$$| $$$$$$$$| $$$$$$$$| $$  | $$
   ⣼⠇ ⢀⣿⣿⣿⣿⣿⠃  ⠸⣿⣿⣿⣿⣿⣿⡀    ⣿⣿⣿⣿⣿⣿⡿       ⠈⢿⣿⣿⣿⣿⣷⣦⣄⣷   \______/  \______/  \______/        \______/  \______/ |__/  |__/|______/|________/|________/|__/  |__/
   ⢻⣷⣶⣼⣿⣿⣿⣿⣧⡀   ⢿⣿⣿⣿⣿⣿⣿⣦ ⢀⣴⣿⣿⣿⣿⣿⣿⡇        ⣠⣿⣿⣿⣿⣿⣿⣿⣿⠆
    ⠻⠿⠿⢿⣿⣿⣿⣿⡿   ⠘⢿⣿⣿⣿⣿⣿⠇ ⢸⣿⣿⣿⣿⣿⣿⣿⠁       ⠸⠿⠿⢿⣿⣿⣿⣿⡿⠋  secrets from the vault into memory, not the disk

EOF

printf "%b%s%s%b%b%b\n\n" "$C7" "$TREE_TOP" "$DIAMOND_FILLED" "$BOLD$C7" "s3c-gorilla INSTALLER" "$RESET"

# ----------------------------------------------------------
# Step 1: Check/install KeePassXC
# ----------------------------------------------------------
section "[1/11] KeePassXC"
info "KeePassXC DB: $DB_PATH"
if ! command -v keepassxc-cli &>/dev/null; then
 info "Installing KeePassXC via Homebrew..."
 if ! command -v brew &>/dev/null; then
 error "Homebrew not found. Install it first: https://brew.sh"
 exit 1
 fi
 brew install --cask keepassxc
 success "KeePassXC installed"
else
 success "KeePassXC $(keepassxc-cli --version)"
fi

# ----------------------------------------------------------
# Step 2: Privileged install prep
# ----------------------------------------------------------
section "[2/11] Install targets"
info "CLIs → $BIN_DIR"
info "Helpers → $SHARE_DIR"
info "Logs → ~/Library/Logs/s3c-gorilla/"
info "Cache → ~/Library/Caches/s3c-gorilla/"

# Prime sudo so every sudo-install in steps 4/5/10 is prompt-free (and the
# godfather only appears at most once, on the initial prompt).
if ! sudo -n true 2>/dev/null; then
 if [[ -r "$SCRIPT_DIR/lib/godfather.sh" ]]; then
 source "$SCRIPT_DIR/lib/godfather.sh"
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

# ----------------------------------------------------------
# Step 3: Deploy user config (preserve if it already exists)
# ----------------------------------------------------------
section "[3/11] User config"
mkdir -p "$CONFIG_DIR"
if [[ -f "$CONFIG_FILE" ]]; then
 success "Preserved existing: $CONFIG_FILE"
elif [[ -f "$SCRIPT_DIR/config.example" ]]; then
 cp "$SCRIPT_DIR/config.example" "$CONFIG_FILE"
 success "Created from config.example: $CONFIG_FILE"
 item "Edit that file to change the DB path or group names."
else
 warn "config.example missing — tools will use built-in defaults"
fi


# ----------------------------------------------------------
# Step 4: Install tools
# ----------------------------------------------------------
section "[4/11] Installing tools"

# fs-gorilla is now a Python package — copy `src/fs_gorilla/` to a shared
# location BEFORE installing the shim, so the shim can find the package
# under /usr/local/share/s3c-gorilla/fs_gorilla/.
sudo mkdir -p /usr/local/share/s3c-gorilla
sudo rm -rf /usr/local/share/s3c-gorilla/fs_gorilla # purge stale
sudo cp -R "$SRC_DIR/fs_gorilla" /usr/local/share/s3c-gorilla/fs_gorilla
success "fs_gorilla/ package → /usr/local/share/s3c-gorilla/fs_gorilla"

# CLIs → /usr/local/bin (owned by root, world-executable)
for tool in env-gorilla otp-gorilla ssh-gorilla.sh llm-gorilla fs-gorilla; do
 sudo install -m 0755 -o root -g wheel "$SRC_DIR/$tool" "$BIN_DIR/$tool"
 success "$tool → $BIN_DIR/$tool"
done

# Sourced helpers → /usr/local/share/s3c-gorilla (readable libs, not $PATH)
sudo install -m 0644 -o root -g wheel "$SCRIPT_DIR/lib/godfather.sh" "$SHARE_DIR/godfather.sh"
sudo install -m 0644 -o root -g wheel "$SCRIPT_DIR/lib/banners.sh" "$SHARE_DIR/banners.sh"
sudo install -m 0644 -o root -g wheel "$SCRIPT_DIR/lib/drunken-bishop.sh" "$SHARE_DIR/drunken-bishop.sh"
sudo install -m 0644 -o root -g wheel "$SCRIPT_DIR/lib/ywizz/colorize.sh" "$SHARE_DIR/colorize.sh"
success "godfather.sh → $SHARE_DIR/godfather.sh"
success "banners.sh → $SHARE_DIR/banners.sh"
success "drunken-bishop.sh → $SHARE_DIR/drunken-bishop.sh"
success "colorize.sh → $SHARE_DIR/colorize.sh"

# ----------------------------------------------------------
# Step 5: Detect Touch ID and install touchid-gorilla
# ----------------------------------------------------------
section "[5/11] Touch ID"

HAS_TOUCHID=false

# AppleBiometricSensor appears in IOKit on any Mac with Touch ID hardware —
# built-in (MBP/MBA 2016+) or external (Magic Keyboard with Touch ID paired to
# a desktop). Works on both Apple Silicon and Intel T2.
TOUCHID_DETECTED=false
if ioreg -c AppleBiometricSensor 2>/dev/null | grep -q "AppleBiometricSensor"; then
 TOUCHID_DETECTED=true
fi

if $TOUCHID_DETECTED; then
 success "Touch ID hardware detected"
 printf "%b%s %b" "$C7" "$TREE_MID" "$RESET"
 read -p "Enable Touch ID mode? [Y/n] " -n 1 -r
 echo ""
 if [[ -z "$REPLY" || $REPLY =~ ^[Yy]$ ]]; then
 HAS_TOUCHID=true
 else
 skip "Touch ID mode opted out — tools will prompt for master password"
 fi
fi

if $HAS_TOUCHID; then

 FRESH_INSTALL=true
 [[ -f "$BIN_DIR/touchid-gorilla" ]] && FRESH_INSTALL=false

 info "Compiling touchid-gorilla..."
 BUILD_SRC="$BUILD_DIR/touchid-gorilla.swift"
 BUILD_BIN="$BUILD_DIR/touchid-gorilla"
 cp "$SRC_DIR/touchid-gorilla.swift" "$BUILD_SRC"

 swiftc "$BUILD_SRC" \
 -o "$BUILD_BIN" \
 -framework Security \
 -framework LocalAuthentication

 # Codesigning identity picker.
 # "Developer ID Application" is the only identity that lets a CLI binary with
 # keychain-access-groups entitlement launch on macOS without an embedded
 # provisioning profile — so we recommend it exclusively.
 ENT_FILE="$SRC_DIR/touchid-gorilla.entitlements"

 IDENT_LINES=()
 while IFS= read -r line; do
 IDENT_LINES+=("$line")
 done < <(security find-identity -v -p codesigning 2>/dev/null | grep -E '^[[:space:]]*[0-9]+\)')

 SIGN_IDENTITY=""
 if [[ ${#IDENT_LINES[@]} -eq 0 ]]; then
 warn "No codesigning identities found — falling back to ad-hoc"
 else
 item "Codesigning identities:"
 DEFAULT_CHOICE=0
 for i in "${!IDENT_LINES[@]}"; do
 ln="${IDENT_LINES[$i]}"
 hash=$(echo "$ln" | awk '{print $2}')
 name=$(echo "$ln" | sed -E 's/^[[:space:]]*[0-9]+\)[[:space:]]+[A-F0-9]+[[:space:]]+//')
 star=""
 if [[ "$name" == *"Developer ID Application"* ]]; then
 star=" [recommended — only cert type that works for CLI binaries]"
 [[ $DEFAULT_CHOICE -eq 0 ]] && DEFAULT_CHOICE=$((i+1))
 fi
 printf "%b%s%b %d) %s%s\n" "$C7" "$TREE_MID" "$RESET" $((i+1)) "$name" "$star"
 done
 printf "%b%s%b 0) ad-hoc (no Developer identity — SE features will be unreliable)\n" "$C7" "$TREE_MID" "$RESET"
 if [[ $DEFAULT_CHOICE -gt 0 ]]; then
 printf "%b%s %b" "$C7" "$TREE_MID" "$RESET"
 read -p "Pick identity [1-${#IDENT_LINES[@]}, 0=ad-hoc, Enter=$DEFAULT_CHOICE]: " CHOICE
 CHOICE="${CHOICE:-$DEFAULT_CHOICE}"
 else
 printf "%b%s %b" "$C7" "$TREE_MID" "$RESET"
 read -p "Pick identity [1-${#IDENT_LINES[@]}, 0=ad-hoc]: " CHOICE
 fi
 if [[ "$CHOICE" =~ ^[0-9]+$ ]] && [[ "$CHOICE" -ge 1 ]] && [[ "$CHOICE" -le ${#IDENT_LINES[@]} ]]; then
 SIGN_IDENTITY=$(echo "${IDENT_LINES[$((CHOICE-1))]}" | awk '{print $2}')
 fi
 fi

 CODESIGN_ARGS=(--force --sign)
 if [[ -n "$SIGN_IDENTITY" ]]; then
 CODESIGN_ARGS+=("$SIGN_IDENTITY")
 [[ -f "$ENT_FILE" ]] && CODESIGN_ARGS+=(--entitlements "$ENT_FILE")
 CODESIGN_ARGS+=("$BUILD_BIN")
 if codesign "${CODESIGN_ARGS[@]}" &>/dev/null; then
 success "Signed with: $SIGN_IDENTITY"
 [[ -f "$ENT_FILE" ]] && item "Entitlements: $(basename "$ENT_FILE")"
 else
 error "codesign failed — retry with a different identity or check keychain access"
 exit 1
 fi
 else
 codesign --force --sign - "$BUILD_BIN" 2>/dev/null
 warn "Ad-hoc signed — Secure Enclave access may be unreliable"
 fi

 # Install the signed binary into $BIN_DIR. `install(1)` on macOS 14+ (Sonoma)
 # stamps the destination with `com.apple.provenance` — an xattr that
 # Gatekeeper/amfid consults at exec time. A binary with temp-dir provenance
 # installed into /usr/local/bin/ gets SIGKILL'd at launch even though
 # `codesign --verify` still passes (xattrs aren't part of the signature).
 # Strip every xattr after install to get a clean, trusted binary.
 sudo install -m 0755 -o root -g wheel "$BUILD_BIN" "$BIN_DIR/touchid-gorilla"
 sudo xattr -cr "$BIN_DIR/touchid-gorilla"
 success "touchid-gorilla → $BIN_DIR/touchid-gorilla"

 # -----------------------------------------------------------------------
 # Compile + sign + install s3c-ssh-agent alongside touchid-gorilla.
 # Same signing identity; no entitlements needed (agent only talks to SE,
 # no keychain-access-groups required).
 # -----------------------------------------------------------------------
 info "Compiling s3c-ssh-agent..."
 AGENT_SRC="$BUILD_DIR/s3c-ssh-agent.swift"
 AGENT_BIN="$BUILD_DIR/s3c-ssh-agent"
 cp "$SRC_DIR/s3c-ssh-agent.swift" "$AGENT_SRC"
 swiftc "$AGENT_SRC" -o "$AGENT_BIN" -framework Security
 AGENT_CODESIGN=(--force --sign)
 if [[ -n "$SIGN_IDENTITY" ]]; then
 AGENT_CODESIGN+=("$SIGN_IDENTITY" "$AGENT_BIN")
 if codesign "${AGENT_CODESIGN[@]}" &>/dev/null; then
 success "Signed s3c-ssh-agent with: $SIGN_IDENTITY"
 else
 warn "codesign s3c-ssh-agent failed — falling back to ad-hoc"
 codesign --force --sign - "$AGENT_BIN" 2>/dev/null
 fi
 else
 codesign --force --sign - "$AGENT_BIN" 2>/dev/null
 fi
 sudo install -m 0755 -o root -g wheel "$AGENT_BIN" "$BIN_DIR/s3c-ssh-agent"
 sudo xattr -cr "$BIN_DIR/s3c-ssh-agent"
 success "s3c-ssh-agent → $BIN_DIR/s3c-ssh-agent"
else
 if ! $TOUCHID_DETECTED; then
 info "No Touch ID detected (desktop Mac without Touch ID keyboard)"
 fi
 item "Tools will prompt for master password"
fi

# ----------------------------------------------------------
# Step 6: SSH config check
# ----------------------------------------------------------
section "[6/11] SSH config"

SSH_CONFIG="$HOME/.ssh/config"
if [[ -f "$SSH_CONFIG" ]]; then
 if grep -q "AddKeysToAgent\|UseKeychain" "$SSH_CONFIG"; then
 warn "Remove AddKeysToAgent/UseKeychain from $SSH_CONFIG"
 item "Recommended:"
 item "Host *"
 item " IdentitiesOnly yes"
 item " HashKnownHosts yes"
 item " ServerAliveInterval 60"
 item " ServerAliveCountMax 3"
 else
 success "Looks good"
 fi
else
 warn "No config found — create ~/.ssh/config"
fi

# ----------------------------------------------------------
# Step 7: Shell integration
# ----------------------------------------------------------
section "[7/11] Shell integration"

SSH_GORILLA_LINE='source /usr/local/bin/ssh-gorilla.sh'
SSH_AUTH_SOCK_LINE='export SSH_AUTH_SOCK="$HOME/.s3c-gorilla/agent.sock"'
if grep -qF "$SSH_GORILLA_LINE" "$HOME/.zprofile" 2>/dev/null && \
 grep -qF "$SSH_AUTH_SOCK_LINE" "$HOME/.zprofile" 2>/dev/null; then
 success "ssh-gorilla + SSH_AUTH_SOCK already in .zprofile"
else
 printf "%b%s %b" "$C7" "$TREE_MID" "$RESET"
 read -p "Add ssh-gorilla wrapper + SSH_AUTH_SOCK export to .zprofile? [Y/n] " -n 1 -r
 echo ""
 if [[ -z "$REPLY" || $REPLY =~ ^[Yy]$ ]]; then
 grep -qF "$SSH_GORILLA_LINE" "$HOME/.zprofile" 2>/dev/null || {
 echo "" >> "$HOME/.zprofile"
 echo "# s3c-gorilla: root@ prepend for bare hostnames" >> "$HOME/.zprofile"
 echo "$SSH_GORILLA_LINE" >> "$HOME/.zprofile"
 }
 grep -qF "$SSH_AUTH_SOCK_LINE" "$HOME/.zprofile" 2>/dev/null || {
 echo "# s3c-gorilla: point ssh at our agent (s3c-ssh-agent LaunchAgent)" >> "$HOME/.zprofile"
 echo "$SSH_AUTH_SOCK_LINE" >> "$HOME/.zprofile"
 }
 success "Added (restart terminal or: source ~/.zprofile)"
 else
 skip "(not added)"
 fi
fi

# ----------------------------------------------------------
# Step 8: PATH check
# ----------------------------------------------------------
section "[8/11] PATH"

if echo ":$PATH:" | grep -q ":/usr/local/bin:"; then
 success "/usr/local/bin in PATH"
else
 warn "/usr/local/bin not in PATH — unusual on macOS"
 item 'Add to .zprofile: export PATH="/usr/local/bin:$PATH"'
fi

# ----------------------------------------------------------
# Step 9: Database check
# ----------------------------------------------------------
section "[9/11] KeePassXC database"

if [[ -f "$DB_PATH" ]]; then
 success "Found: $(basename "$DB_PATH")"
else
 warn "Not found at: $DB_PATH"
 item "Create one in KeePassXC or update GORILLA_DB in $CONFIG_FILE"
fi

# ----------------------------------------------------------
# Step 10: fs-gorilla — filesystem tripwire (LaunchDaemon)
# ----------------------------------------------------------
section "[10/11] fs-gorilla LaunchDaemon"

if [[ ! -x /usr/bin/eslogger ]]; then
 warn "/usr/bin/eslogger missing — requires macOS 13+ (Ventura)"
 skip "Skipping LaunchDaemon load — fs-gorilla CLI still works for ad-hoc runs"
else
 if ! command -v terminal-notifier &>/dev/null; then
 info "Installing terminal-notifier via Homebrew..."
 brew install terminal-notifier
 fi

 printf "%b%s %b" "$C7" "$TREE_MID" "$RESET"
 read -p "Load fs-gorilla as a LaunchDaemon now? [Y/n] " -n 1 -r
 echo ""
 if [[ -z "$REPLY" || $REPLY =~ ^[Yy]$ ]]; then
 # A running daemon means eslogger is live, which means FDA is already
 # granted — we can skip the whole System Settings song-and-dance.
 FDA_ALREADY_GRANTED=false
 if sudo launchctl print "system/com.slav-it.s3c-gorilla" 2>/dev/null \
 | awk '/^[[:space:]]*state =/ {exit !($3 == "running")}'; then
 FDA_ALREADY_GRANTED=true
 fi

 info "Installing LaunchDaemon plist..."
 sudo install -m 0644 -o root -g wheel \
 "$SRC_DIR/com.slav-it.s3c-gorilla.plist" \
 /Library/LaunchDaemons/com.slav-it.s3c-gorilla.plist

 info "Loading daemon..."
 # Bootout via both label-form and plist-path-form — the latter is more
 # reliable when launchd has a stale reference to the old plist inode.
 # Without this, re-running install.sh often fails with
 # "Bootstrap failed: 5: Input/output error".
 sudo launchctl bootout system/com.slav-it.s3c-gorilla 2>/dev/null || true
 sudo launchctl bootout system /Library/LaunchDaemons/com.slav-it.s3c-gorilla.plist 2>/dev/null || true
 sleep 1
 sudo launchctl enable system/com.slav-it.s3c-gorilla
 sudo launchctl bootstrap system /Library/LaunchDaemons/com.slav-it.s3c-gorilla.plist

 success "fs-gorilla loaded (label: com.slav-it.s3c-gorilla)"

 if $FDA_ALREADY_GRANTED; then
 success "Full Disk Access already granted — skipping System Settings flow"
 else
 # macOS has no API to programmatically trigger the FDA consent dialog
 # for a LaunchDaemon — a root daemon that gets TCC-denied just exits
 # silently. Best we can do is deep-link to the FDA pane and reveal
 # the binary in Finder so the user can drag-drop it into the list.
 warn "One-time Full Disk Access grant required for eslogger"
 item "Opening System Settings → Privacy & Security → Full Disk Access..."
 item "Finder will also reveal $BIN_DIR/fs-gorilla — drag it into the list."
 open "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles" 2>/dev/null || \
 open "/System/Library/PreferencePanes/Security.prefPane" 2>/dev/null || true
 sleep 1
 open -R "$BIN_DIR/fs-gorilla" 2>/dev/null || true
 printf "%b%s %b" "$C7" "$TREE_MID" "$RESET"
 read -p "Press Enter once you've toggled fs-gorilla ON in Full Disk Access... " _
 info "Restarting daemon so eslogger picks up the TCC grant..."
 sudo launchctl kickstart -k "system/com.slav-it.s3c-gorilla" 2>/dev/null || \
 sudo "$BIN_DIR/fs-gorilla" restart
 success "fs-gorilla restarted"
 fi
 else
 skip "(run later: sudo fs-gorilla start)"
 fi
fi

# ----------------------------------------------------------
# Step 11: SSH keys + LaunchAgent — LAST STEP
# ----------------------------------------------------------
section "[11/11] SSH mode + agent setup"

AGENT_DIR="$HOME/.s3c-gorilla"
PUB_DIR="$AGENT_DIR/pubkeys"
KEYS_JSON="$AGENT_DIR/keys.json"
LAUNCH_PLIST_SRC="$SRC_DIR/com.slav-it.s3c-ssh-agent.plist"
LAUNCH_PLIST_DST="$HOME/Library/LaunchAgents/com.slav-it.s3c-ssh-agent.plist"

mkdir -p "$AGENT_DIR" "$PUB_DIR"
chmod 700 "$AGENT_DIR" "$PUB_DIR"

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
 info "Chip-wrap mode — will import your existing SSH keys into kdbx."
 local -a KEYS=()
 local f
 for f in "$HOME/.ssh/id_"*; do
 [[ -f "$f" ]] || continue
 [[ "$f" == *.pub ]] && continue
 KEYS+=("$f")
 done

 if [[ ${#KEYS[@]} -eq 0 ]]; then
 skip "No SSH private keys in ~/.ssh/ — generate one with: ssh-keygen -t ed25519"
 # Still install LaunchAgent so future keys can use it.
 else
 item "Found SSH keys:"
 local i
 for i in "${!KEYS[@]}"; do
 printf "%b%s%b   %d) %s\n" "$C7" "$TREE_MID" "$RESET" $((i+1)) "$(basename "${KEYS[$i]}")"
 done
 printf "%b%s %b" "$C7" "$TREE_MID" "$RESET"
 local sel
 read -p "Import which? [comma-sep, 'a'=all, 's'=skip, Enter=1]: " sel
 sel="${sel:-1}"

 local -a SELECTED=()
 if [[ "$sel" == "s" ]]; then
 skip "SSH key import skipped"
 elif [[ "$sel" == "a" ]]; then
 SELECTED=("${KEYS[@]}")
 else
 local idx
 IFS=',' read -ra indices <<< "$sel"
 for idx in "${indices[@]}"; do
 idx="${idx// /}"
 if [[ "$idx" =~ ^[0-9]+$ ]] && (( idx >= 1 && idx <= ${#KEYS[@]} )); then
 SELECTED+=("${KEYS[$((idx-1))]}")
 fi
 done
 fi

 if [[ ${#SELECTED[@]} -gt 0 ]]; then
 # Prompt master pw interactively (no blob-retrieve anymore).
 source "$SCRIPT_DIR/lib/godfather.sh" 2>/dev/null
 command -v show_godfather &>/dev/null && show_godfather master
 local GORILLA_PW
 printf '🔐 KeePass master password: '
 read -rs GORILLA_PW
 echo ""

 echo "$GORILLA_PW" | keepassxc-cli mkdir "$DB_PATH" "SSH" -q &>/dev/null || true

 local BACKUP_DIR="$HOME/.ssh.bak-$(date +%Y%m%d-%H%M%S)"
 cp -R "$HOME/.ssh" "$BACKUP_DIR"
 chmod -R go-rwx "$BACKUP_DIR"
 success "Backed up ~/.ssh/ → $BACKUP_DIR"

 local entries_for_json=""
 local key name entry key_type
 for key in "${SELECTED[@]}"; do
 name=$(basename "$key")
 entry="SSH/$name"
 # Strip passphrase if any
 if ! ssh-keygen -y -P '' -f "$key" &>/dev/null; then
 warn "Key '$name' has a passphrase — strip it now (kdbx is the new guard)?"
 printf "%b%s %b" "$C7" "$TREE_MID" "$RESET"
 read -p "Strip? [Y/n] " -n 1 -r; echo ""
 if [[ -z "$REPLY" || $REPLY =~ ^[Yy]$ ]]; then
 ssh-keygen -p -N '' -f "$key" || { error "wrong passphrase"; unset GORILLA_PW; return 1; }
 fi
 fi
 # Save pub key for agent lookup
 cp "${key}.pub" "$PUB_DIR/$name.pub" 2>/dev/null || true
 # Detect key type from pub
 key_type=$(awk '{print $1}' "${key}.pub" 2>/dev/null)
 [[ -z "$key_type" ]] && key_type="ssh-rsa"
 # Import into kdbx
 echo "$GORILLA_PW" | keepassxc-cli add "$DB_PATH" "$entry" -q &>/dev/null || true
 if echo "$GORILLA_PW" | keepassxc-cli attachment-import "$DB_PATH" "$entry" "$name" "$key" -q -f &>/dev/null; then
 success "Imported $name → $entry"
 entries_for_json+="  {\"name\": \"$name\", \"mode\": \"chip-wrap\", \"keyType\": \"$key_type\"},"
 else
 error "Failed to import $name"
 fi
 done
 unset GORILLA_PW

 # Write keys.json (strip trailing comma)
 entries_for_json="${entries_for_json%,}"
 printf '[\n%s\n]\n' "$entries_for_json" > "$KEYS_JSON"
 chmod 600 "$KEYS_JSON"
 success "Registry: $KEYS_JSON"

 printf "%b%s %b" "$C7" "$TREE_MID" "$RESET"
 read -p "Delete plaintext private keys from ~/.ssh/? Backup kept at $BACKUP_DIR [y/N] " -n 1 -r; echo ""
 if [[ $REPLY =~ ^[Yy]$ ]]; then
 for key in "${SELECTED[@]}"; do
 trash "$key" &>/dev/null || mv "$key" "$HOME/.ssh/.$(basename "$key").removed.$(date +%s)"
 done
 info "Plaintext keys removed. Backup: $BACKUP_DIR"
 fi
 fi
 fi
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
 if SSH_AUTH_SOCK="$AGENT_DIR/agent.sock" \
 ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new "$host_arg" exit 2>&1 | tail -5; then
 success "Connected to $test_host — end-to-end works"
 else
 warn "SSH to $test_host failed — check /tmp/s3c-ssh-agent.err.log"
 warn "Common causes: public key not yet on remote (Mode 2), master pw prompt cancelled (Mode 1)."
 fi
 fi

 return 0
}

if install_ssh_step; then
 success "SSH setup complete (mode: $(grep '^GORILLA_SSH_MODE=' "$CONFIG_FILE" 2>/dev/null | cut -d= -f2 | tr -d '"'))"
else
 warn "SSH setup bailed — env/otp/fs/llm tools still work. Re-run ./install.sh to retry."
fi

# ----------------------------------------------------------
# Done
# ----------------------------------------------------------
echo ""
if $HAS_TOUCHID; then
 MODE_LABEL="Touch ID mode"
else
 MODE_LABEL="No TouchID Mode"
fi
printf "%b%s%s%b%bINSTALLED — %s%b\n\n" "$C7" "$TREE_BOT" "$DIAMOND_FILLED" "$BOLD$C7" "" "$MODE_LABEL" "$RESET"

# Cheatsheet — purple-accented box. Each row is padded to the box's 59-char
# interior so borders line up. Use printf's `%-Ns` for left-pad to N chars.
p()     { printf "%b%s%b\n"       "$C7" "$1"          "$RESET"; }
p_row() { printf "%b│%-59s│%b\n"  "$C7" "$1"          "$RESET"; }

p "┌─────────────────────────────────────────────────────────┐"
p_row ""
p_row "  ssh-gorilla"
p_row "    ssh myserver.com           auto-unlock + connect"
p_row ""
p_row "  env-gorilla"
p_row "    env-gorilla app -- cmd     run with secrets"
p_row "    env-gorilla --setup        setup Touch ID"
p_row "    env-gorilla --list         list projects"
p_row ""
p_row "  otp-gorilla"
p_row "    otp-gorilla                show all 2FA codes"
p_row "    otp-gorilla Atlassian      copy one code"
p_row ""
p_row "  fs-gorilla"
p_row "    fs-gorilla                 status"
p_row "    fs-gorilla report          activity report / dashboard"
p_row "    fs-gorilla dashboard       live tmux dashboard"
p_row "    fs-gorilla logs -f         tail matches live"
p_row "    sudo fs-gorilla restart    reload daemon"
p_row ""
p_row "  llm-gorilla"
p_row "    llm-gorilla                live TUI: cpu/ram/net"
p_row "    llm-gorilla status         one-shot snapshot"
p_row "    llm-gorilla alerts         autonomous-start alerts"
p_row ""
p_row "  Config:"
p_row "    ~/.config/s3c-gorilla/config"
p_row ""
p_row "  Adding .env to KeePassXC:"
p_row '    keepassxc-cli add "$DB" "ENV/project_x"'
p_row '    keepassxc-cli attachment-import "$DB" \'
p_row '      "ENV/project_x" .env /path/to/.env'
p_row ""
p "└─────────────────────────────────────────────────────────┘"
echo ""
