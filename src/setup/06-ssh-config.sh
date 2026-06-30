# 06-ssh-config.sh — sanity-check ~/.ssh/config.
section "[6/10] SSH config"

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
true
