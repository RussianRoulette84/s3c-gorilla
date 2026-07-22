# 11-infisical.sh — optional Infisical secret-sync support (opt-in, default OFF).
section "[11/11] Infisical secret sync (optional)"

item "Infisical is an open-source secrets manager: a server that stores your app secrets and"
item "hands them to your services over an authenticated API. s3c-gorilla can SYNC each project's"
item ".env with an Infisical project — push local → server, pull server → local, or reconcile both."
item "Learn more: https://infisical.com"
printf "%b%s %b" "$C7" "$TREE_MID" "$RESET"
read -rp "Enable Infisical secret sync? [y/N] " _inf
if [[ "$_inf" =~ ^[Yy]$ ]]; then
 if command -v infisical &>/dev/null; then
 success "Infisical CLI present: $(infisical --version 2>/dev/null | head -1)"
 elif command -v brew &>/dev/null; then
 printf "%b%s %b" "$C7" "$TREE_MID" "$RESET"
 read -rp "Infisical CLI not found — install it now via Homebrew? [Y/n] " _ib
 if [[ -z "$_ib" || "$_ib" =~ ^[Yy]$ ]]; then
 brew install infisical/get-cli/infisical && success "Infisical CLI installed" \
 || warn "Homebrew install failed — get it from https://infisical.com/docs/cli/overview"
 fi
 else
 warn "Infisical CLI not found — install later: https://infisical.com/docs/cli/overview"
 fi
 set_config GORILLA_INFISICAL_ENABLED true
 success "Infisical sync enabled (per-project connection lives in each .env)"
 item "Add each project's connection with:  env-gorilla edit <project>"
 item "  # Infisical"
 item "  INFISICAL_API_URL=https://your-instance"
 item "  INFISICAL_CLIENT_ID=…   INFISICAL_CLIENT_SECRET=…   INFISICAL_PROJECT_ID=…"
 item "Then sync:  env-gorilla push|pull|sync <project>   (--force-infisical to auto-resolve)"
else
 set_config GORILLA_INFISICAL_ENABLED false
 skip "Infisical sync: off (enable later by re-running the installer)"
fi
true
