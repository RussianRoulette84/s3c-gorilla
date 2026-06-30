# 07-shell-integration.sh — add the ssh-gorilla wrapper (+ SSH_AUTH_SOCK in chip mode) to .zprofile.
section "[7/10] Shell integration"

SSH_GORILLA_LINE='source /usr/local/bin/ssh-gorilla.sh'
SSH_AUTH_SOCK_LINE='export SSH_AUTH_SOCK="$HOME/.s3c-gorilla/agent.sock"'
# SSH_AUTH_SOCK only matters when the SE-backed agent actually runs — i.e. Touch
# ID mode. In password mode there's no agent, so exporting a dead socket path
# just makes `ssh-add`/`ssh` complain. Only require/add it when $HAS_TOUCHID.
if grep -qF "$SSH_GORILLA_LINE" "$HOME/.zprofile" 2>/dev/null \
 && { ! $HAS_TOUCHID || grep -qF "$SSH_AUTH_SOCK_LINE" "$HOME/.zprofile" 2>/dev/null; }; then
 success "Shell integration already in .zprofile"
else
 printf "%b%s %b" "$C7" "$TREE_MID" "$RESET"
 read -p "Add ssh-gorilla wrapper to .zprofile? [Y/n] " -n 1 -r
 echo ""
 if [[ -z "$REPLY" || $REPLY =~ ^[Yy]$ ]]; then
 grep -qF "$SSH_GORILLA_LINE" "$HOME/.zprofile" 2>/dev/null || {
 echo "" >> "$HOME/.zprofile"
 echo "# s3c-gorilla: root@ prepend for bare hostnames" >> "$HOME/.zprofile"
 echo "$SSH_GORILLA_LINE" >> "$HOME/.zprofile"
 }
 if $HAS_TOUCHID; then
 grep -qF "$SSH_AUTH_SOCK_LINE" "$HOME/.zprofile" 2>/dev/null || {
 echo "# s3c-gorilla: point ssh at our agent (s3c-ssh-agent LaunchAgent)" >> "$HOME/.zprofile"
 echo "$SSH_AUTH_SOCK_LINE" >> "$HOME/.zprofile"
 }
 fi
 success "Added (restart terminal or: source ~/.zprofile)"
 else
 skip "(not added)"
 fi
fi
true
