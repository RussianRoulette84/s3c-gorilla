# 01-keepassxc.sh — ensure KeePassXC is installed (app first, then report the DB it'll use).
section "[1/10] KeePassXC"

# Check the app/CLI BEFORE the DB — no point reporting a DB path for a vault tool that
# isn't installed yet.
if command -v keepassxc-cli &>/dev/null; then
 success "KeePassXC $(keepassxc-cli --version)"
else
 warn "KeePassXC not found on this Mac."
 item "Download the official macOS app (.dmg):  https://keepassxc.org/download"
 if command -v brew &>/dev/null; then
 printf "%b%s %b" "$C7" "$TREE_MID" "$RESET"
 read -rp "Install KeePassXC now via Homebrew? [Y/n] " _kp
 if [[ -z "$_kp" || "$_kp" =~ ^[Yy]$ ]]; then
 brew install --cask keepassxc && success "KeePassXC installed" \
 || { error "Homebrew install failed — grab the .dmg from the link above, then re-run."; exit 1; }
 else
 error "KeePassXC is required. Install it from the link above, then re-run ./install.sh"
 exit 1
 fi
 else
 error "Homebrew not found. Install KeePassXC from the link above (or get Homebrew at https://brew.sh), then re-run."
 exit 1
 fi
fi

info "Vault DB: $DB_PATH"
true
