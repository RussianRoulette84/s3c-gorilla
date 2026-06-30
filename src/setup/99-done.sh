# 99-done.sh — completion banner + cheatsheet.
printf "%b%s%b\n" "$C7" "$TREE_MID" "$RESET"   # │ connector before the closing └ (no bare gap)
if $HAS_TOUCHID; then
 MODE_LABEL="Touch ID mode"
else
 MODE_LABEL="No TouchID Mode"
fi
printf "%b%s%s%b%bINSTALLED — %s%b\n\n" "$C7" "$TREE_BOT" "$DIAMOND_FILLED" "$BOLD$C7" "" "$MODE_LABEL" "$RESET"

# Cheatsheet — left-bar style (no right wall, so nothing can misalign). Each
# command gets its own cyan line with a dim description under it — handles any
# length. Theme: purple bar (C7), ORANGE bold tool names, pink section titles
# (C8), cyan commands (C4), dim descriptions.
cs_rule() { printf "%b%s%b\n" "$C7" "$1" "$RESET"; }
cs_bar()  { printf "%b│%b\n" "$C7" "$RESET"; }
cs_tool() { printf "%b│  %b%s%b %b%s%b\n" "$C7" "$BOLD$ORANGE" "$1" "$RESET" "$DIM" "$2" "$RESET"; }
cs_sect() { printf "%b│  %b%s%b\n" "$C7" "$BOLD$C8" "$1" "$RESET"; }
cs_ex()   { printf "%b│    %b%s%b\n" "$C7" "$C4" "$1" "$RESET"; }
cs_desc() { printf "%b│      %b%s%b\n" "$C7" "$DIM" "$1" "$RESET"; }
cs_line() { printf "%b│    %b%s%b\n" "$C7" "$C4" "$1" "$RESET"; }

cs_rule "╭─────────────────────────────────────────────────"
cs_bar
cs_tool "ssh-gorilla" "— encrypted SSH, keys live in the vault (not on disk)"
cs_ex   "ssh prod"
cs_desc "unlock key from kdbx → connect as root@prod"
cs_ex   "ssh deploy@project-host"
cs_desc "explicit user, Touch ID per sign, no id_rsa on disk"
cs_bar
cs_tool "env-gorilla" "— inject .env secrets into a command, in memory"
cs_ex   "env-gorilla project_a -- npm run dev"
cs_desc "run with project_a's .env (never written to disk)"
cs_ex   "env-gorilla project_a,project_b -- bash"
cs_desc "merge several .envs into ONE launch (later wins on dupes)"
cs_ex   "env-gorilla --list"
cs_desc "list available projects in the vault"
cs_ex   "env-gorilla --clear"
cs_desc "wipe all cached env blobs from /tmp"
cs_ex   "env-gorilla --clear project_a,project_b"
cs_desc "wipe one combined blob"
cs_bar
cs_tool "otp-gorilla" "— 2FA / TOTP codes from the vault"
cs_ex   "otp-gorilla"
cs_desc "show all 2FA codes"
cs_ex   "otp-gorilla github"
cs_desc "one code (fuzzy match) → clipboard + macOS notification"
cs_ex   "otp-gorilla --clear"
cs_desc "wipe cached otp blobs from /tmp"
cs_bar
cs_sect "Config"
cs_line "~/.config/s3c-gorilla/config"
cs_desc "GORILLA_DB, ENV/2FA group names, SSH mode"
cs_bar
cs_sect "Add a .env to KeePassXC"
cs_line 'keepassxc-cli add "$DB" "ENV/project_a"'
cs_line 'keepassxc-cli attachment-import "$DB" \'
cs_line '  "ENV/project_a" .env /path/to/.env'
cs_bar
cs_sect "Add a 2FA secret to KeePassXC"
cs_line 'keepassxc-cli add "$DB" "2FA/github"'
cs_desc "then add its TOTP seed in the KeePassXC app"
cs_bar
cs_rule "╰─────────────────────────────────────────────────"
echo ""
true
