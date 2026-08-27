# 03-user-config.sh — deploy user config (preserve if it already exists).
section "[3/11] User config"
mkdir -p "$CONFIG_DIR"
if [[ -f "$CONFIG_FILE" ]]; then
 # A config already exists — keep the user's settings by default, but let them
 # reset to a fresh config.example if they want.
 if [[ -f "$CONFIG_EXAMPLE" ]]; then
 if confirm "Existing config found. Keep it?" y; then
 success "Preserved existing: $CONFIG_FILE"
 else
 cp "$CONFIG_EXAMPLE" "$CONFIG_FILE"
 success "Reset from config.example: $CONFIG_FILE"
 item "Re-check your DB path + group names in that file."
 fi
 else
 success "Preserved existing: $CONFIG_FILE"
 fi
elif [[ -f "$CONFIG_EXAMPLE" ]]; then
 cp "$CONFIG_EXAMPLE" "$CONFIG_FILE"
 success "Created from config.example: $CONFIG_FILE"
 item "Edit that file to change the DB path or group names."
else
 warn "config.example missing — tools will use built-in defaults"
fi
true
