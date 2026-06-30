# import-ssh-keys.sh — shared SSH key-import helper (NOT a numbered step; sourced by
# 10-ssh-mode.sh). Chip-wrap + password modes differ only in the keys.json "mode" field and
# what happens after import, so the loop itself lives here once (HR #16).
#
# _import_ssh_keys <json_mode>: find ~/.ssh/id_* → pick → back up ~/.ssh → import each into
# the kdbx → write keys.json with the given mode → optionally delete the plaintext.
# Returns 1 only on a wrong-passphrase abort. Uses SCRIPT_DIR/DB_PATH/PUB_DIR/KEYS_JSON.
_import_ssh_keys() {
 local json_mode="$1"
 info "Importing existing SSH keys into kdbx (mode: $json_mode)."
 local -a KEYS=()
 local f
 for f in "$HOME/.ssh/id_"*; do
 [[ -f "$f" ]] || continue
 [[ "$f" == *.pub ]] && continue
 KEYS+=("$f")
 done
 if [[ ${#KEYS[@]} -eq 0 ]]; then
 skip "No SSH private keys in ~/.ssh/ — generate one with: ssh-keygen -t ed25519"
 return 0
 fi
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
 skip "SSH key import skipped"; return 0
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
 [[ ${#SELECTED[@]} -eq 0 ]] && return 0

 # Prompt master pw interactively (no blob-retrieve anymore).
 source "$SCRIPT_DIR/src/lib/godfather.sh" 2>/dev/null
 command -v show_godfather &>/dev/null && show_godfather master
 local GORILLA_PW
 printf "%b%s %b🔐 KeePass master password: " "$C7" "$TREE_MID" "$RESET"
 read -rs GORILLA_PW
 echo ""

 echo "$GORILLA_PW" | keepassxc-cli mkdir "$DB_PATH" "SSH" -q &>/dev/null || true

 local BACKUP_DIR="$HOME/.ssh.bak-$(date +%Y%m%d-%H%M%S)"
 # 2>/dev/null: ~/.ssh often holds agent sockets that cp can't copy — the warning would
 # break the tree, and we don't need the sockets in the backup anyway (keys still copy).
 cp -R "$HOME/.ssh" "$BACKUP_DIR" 2>/dev/null
 chmod -R go-rwx "$BACKUP_DIR"
 success "Backed up ~/.ssh/ → $BACKUP_DIR"

 local entries_for_json=""
 local key name entry key_type _up newkey
 local -a UPGRADED_PUBS=()
 for key in "${SELECTED[@]}"; do
 name=$(basename "$key")
 # RSA keep-or-upgrade (#RSA). The agent signs RSA fine now, but Ed25519 is smaller +
 # faster, so offer a one-shot in-place upgrade. Upgrade = generate a fresh Ed25519 and
 # import THAT instead; you then ssh-copy-id its pubkey (printed at the end) to each server.
 if [[ "$(awk '{print $1}' "${key}.pub" 2>/dev/null)" == "ssh-rsa" ]]; then
 warn "'$name' is an RSA key. It works as-is (the agent signs RSA), but Ed25519 is smaller + faster."
 printf "%b%s %b" "$C7" "$TREE_MID" "$RESET"
 read -rp "Keep RSA (k) or upgrade to a new Ed25519 (u)? [k/u, Enter=k] " _up
 if [[ "$_up" =~ ^[Uu]$ ]]; then
 newkey="$HOME/.ssh/id_s3c_ed25519"
 [[ -e "$newkey" ]] && newkey="$HOME/.ssh/id_s3c_ed25519_$(date +%s)"
 if ssh-keygen -t ed25519 -N '' -C "s3c-gorilla upgrade from $name" -f "$newkey" &>/dev/null; then
 key="$newkey"; name=$(basename "$newkey")
 UPGRADED_PUBS+=("$newkey.pub")
 success "Generated $name — add its pubkey to each server (printed at the end)."
 else
 warn "ssh-keygen failed — keeping the RSA key."
 fi
 fi
 fi
 entry="SSH/$name"
 # Strip passphrase if any
 if ! ssh-keygen -y -P '' -f "$key" &>/dev/null; then
 warn "Key '$name' has a passphrase — strip it now (kdbx is the new guard)?"
 printf "%b%s %b" "$C7" "$TREE_MID" "$RESET"
 read -rp "Strip? [Y/n] " REPLY
 if [[ -z "$REPLY" || $REPLY =~ ^[Yy]$ ]]; then
 # >/dev/null hides ssh-keygen's "Your identification has been saved" chatter; the
 # interactive "Enter old passphrase:" still shows (it has to — you type into it).
 ssh-keygen -p -N '' -f "$key" >/dev/null || { error "wrong passphrase"; unset GORILLA_PW; return 1; }
 fi
 fi
 cp "${key}.pub" "$PUB_DIR/$name.pub" 2>/dev/null || true
 key_type=$(awk '{print $1}' "${key}.pub" 2>/dev/null)
 [[ -z "$key_type" ]] && key_type="ssh-rsa"
 echo "$GORILLA_PW" | keepassxc-cli add "$DB_PATH" "$entry" -q &>/dev/null || true
 if echo "$GORILLA_PW" | keepassxc-cli attachment-import "$DB_PATH" "$entry" "$name" "$key" -q -f &>/dev/null; then
 success "Imported $name → $entry"
 entries_for_json+="  {\"name\": \"$name\", \"mode\": \"$json_mode\", \"keyType\": \"$key_type\"},"
 else
 error "Failed to import $name"
 fi
 done
 unset GORILLA_PW

 entries_for_json="${entries_for_json%,}"
 printf '[\n%s\n]\n' "$entries_for_json" > "$KEYS_JSON"
 chmod 600 "$KEYS_JSON"
 success "Registry: $KEYS_JSON (mode: $json_mode)"

 printf "%b%s %b" "$C7" "$TREE_MID" "$RESET"
 read -rp "Delete plaintext private keys from ~/.ssh/? Backup at $BACKUP_DIR [y/N] " REPLY
 if [[ $REPLY =~ ^[Yy]$ ]]; then
 for key in "${SELECTED[@]}"; do
 trash "$key" &>/dev/null || mv "$key" "$HOME/.ssh/.$(basename "$key").removed.$(date +%s)"
 done
 info "Plaintext keys removed. Backup: $BACKUP_DIR"
 fi

 # Upgraded RSA → Ed25519: the new pubkey must be added to every server's authorized_keys.
 if (( ${#UPGRADED_PUBS[@]} > 0 )); then
 warn "You upgraded ${#UPGRADED_PUBS[@]} key(s) to Ed25519. Add the new pubkey to each server:"
 local pub
 for pub in "${UPGRADED_PUBS[@]}"; do
 item "  ssh-copy-id -i $pub user@yourhost   # repeat per server"
 done
 item "Until you do, those servers still expect the old RSA key."
 fi
 return 0
}

# _verify_vault_ssh_keys — confirm the vault actually holds a USABLE SSH private key the agent
# can serve. Catches the trap the user hit: a dead/half-deleted key on disk while the vault has
# nothing loadable, so `ssh` silently falls back and gets Permission denied. Prints each key's
# fingerprint so it can be matched against the server's authorized_keys.
_verify_vault_ssh_keys() {
 local pw n line fp ok=0 names=()
 printf "%b%s %b🔐 KeePass master password (verify SSH keys): " "$C7" "$TREE_MID" "$RESET"
 read -rs pw; echo ""
 [[ -z "$pw" ]] && { warn "Skipped SSH key verification (no password)."; return 0; }
 while IFS= read -r n; do [[ -n "$n" ]] && names+=("$n"); done \
 < <(echo "$pw" | keepassxc-cli ls "$DB_PATH" "SSH/" -q 2>/dev/null | grep -v '/$')
 if (( ${#names[@]} == 0 )); then
 unset pw
 warn "Vault group SSH/ is EMPTY — 'ssh' has no key to serve and will be denied."
 item "Import a real private key:  keepassxc-cli attachment-import \"\$DB\" SSH/id_rsa id_rsa ~/.ssh/id_rsa"
 return 1
 fi
 local tmp
 for n in "${names[@]}"; do
 # ssh-keygen -y refuses a world-readable stdin, so stage the key in a 0600 temp file.
 tmp="$(mktemp)"; chmod 600 "$tmp"
 echo "$pw" | keepassxc-cli attachment-export "$DB_PATH" "SSH/$n" "$n" --stdout -q 2>/dev/null > "$tmp"
 if line=$(ssh-keygen -yf "$tmp" 2>/dev/null) && [[ -n "$line" ]]; then
 fp=$(ssh-keygen -lf "$tmp" 2>/dev/null | awk '{print $2}')
 success "vault SSH/$n → usable private key ($fp)"
 ok=$((ok+1))
 else
 error "vault SSH/$n is NOT a usable private key (empty / public-only / corrupt) — ssh will fail."
 fi
 trash "$tmp" 2>/dev/null || rm -f "$tmp"
 done
 unset pw
 if (( ok == 0 )); then
 warn "No usable SSH private key in the vault — fix this or 'ssh' won't authenticate."
 return 1
 fi
 item "Confirm each fingerprint above matches a line in the server's ~/.ssh/authorized_keys."
 return 0
}
