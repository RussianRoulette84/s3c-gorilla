# 🦍 s3c-gorilla — Installation Guide

## Prerequisites

- macOS 12+ (Monterey or later)
- [Homebrew](https://brew.sh/)
- Xcode Command Line Tools: `xcode-select --install`
- `~/bin` in your PATH

## Quick Install

```bash
chmod +x install.sh
./install.sh
```

The installer handles everything: KeePassXC, compilation, signing, shell integration.

## Post-Install Setup

### 1. KeePassXC database

If you don't have one yet:

1. Open KeePassXC → Create New Database
2. Save to: `~/Library/Mobile Documents/com~apple~CloudDocs/KeePassDB.kdbx`
3. Set a strong master password

### 2. KeePassXC settings

- Settings → Security → Enable Touch ID Quick Unlock (MacBook only)
- Settings → SSH Agent → Enable SSH Agent integration

### 3. Add SSH key

1. New entry → title: "My Private SSH"
2. Password field: your SSH key passphrase
3. Advanced → Attachments → Add → `~/.ssh/id_rsa`
4. SSH Agent tab → Private Key: Attachment `id_rsa`
5. Check: Add key to agent when database is opened
6. Check: Remove key from agent when database is closed
7. Save
8. Move your key off disk: `mv ~/.ssh/id_rsa ~/.ssh/id_rsa.offline`
9. Test: `ssh-add -l` should show your key loaded via KeePassXC
10. Store `id_rsa.offline` somewhere safe (USB stick, pwSafe) as emergency backup

### 4. SSH config

`~/.ssh/config`:
```
Host *
  IdentitiesOnly yes
  HashKnownHosts yes
  ServerAliveInterval 60
  ServerAliveCountMax 3
```

Remove any `AddKeysToAgent`, `UseKeychain`, or `IdentityFile` lines — KeePassXC handles all of that now.

### 5. Add project .env files

```bash
DB="$HOME/Library/Mobile Documents/com~apple~CloudDocs/KeePassDB.kdbx"

keepassxc-cli mkdir "$DB" "ENV"
keepassxc-cli add "$DB" "ENV/project_x"
keepassxc-cli attachment-import "$DB" "ENV/project_x" .env ~/Projects/project_x/.env
```

### 6. (Nothing to do — master password is no longer stored)

Since the compartmentalization rewrite, `env-gorilla --setup` is gone. The
first `env-gorilla <project>` / `otp-gorilla` / `ssh` per boot will ask for
your master password in terminal (or native Mac dialog if launched from
a GUI app), chip-wrap the narrow secret into `/tmp/s3c-gorilla/`, and then
Touch ID handles reruns until reboot / logout.

### 7. Auto-start KeePassXC

System Settings → General → Login Items → add KeePassXC

### 8. fs-gorilla filesystem tripwire (optional)

`install.sh` step `[9/9]` prompts for this. To install manually:

```bash
brew install terminal-notifier

sudo install -m 0755 -o root -g wheel fs-gorilla /usr/local/bin/fs-gorilla
sudo install -m 0644 -o root -g wheel \
    com.slav-it.s3c-gorilla.plist \
    /Library/LaunchDaemons/com.slav-it.s3c-gorilla.plist

sudo fs-gorilla start
```

**One-time TCC grant** — without this `eslogger` exits immediately:

System Settings → Privacy & Security → **Full Disk Access** → add `/usr/local/bin/fs-gorilla` → then `sudo fs-gorilla restart`.

Inspect state:

```bash
fs-gorilla               # status (plist / binary / daemon / log dir)
fs-gorilla logs -f       # tail today's log live (daemon mode)
sudo fs-gorilla test     # foreground, prints DENY-MATCH to stdout, no notifications
```

Only processes whose executable basename matches `claude` / `opencode` / `com.anthropic` (or a shell/interpreter they spawn) are watched — a plain `cat ~/.ssh/id_rsa` from your own zsh will *not* fire, by design.

#### Self-test

You can't trigger fs-gorilla from your shell directly — the actor has to look like Claude. On **Apple Silicon you can't just `cp $(which cat) /tmp/claude`** either, because AMFI kills re-signed copies of system binaries at exec time (SIGKILL, exit 137). Compile a fresh binary instead:

```bash
cat > /tmp/claude.c <<'C'
#include <fcntl.h>
#include <unistd.h>
int main(int argc, char **argv) {
    if (argc < 2) return 1;
    int fd = open(argv[1], O_RDONLY);
    if (fd < 0) return 1;
    char buf[64];
    read(fd, buf, sizeof(buf));
    close(fd);
    return 0;
}
C
cc /tmp/claude.c -o /tmp/claude

# Trigger deny-matches (run in one pane while `fs-gorilla logs -f` tails in another)
touch ~/.env
/tmp/claude ~/.ssh/config     # → R match on ~/.ssh/**
/tmp/claude ~/.env            # → R match on /**/.env

# Cleanup
trash /tmp/claude /tmp/claude.c
```

Expected: two `DENY-MATCH` lines in the log plus two `🦍 fs-gorilla: claude → R` notifications. The daemon also fires a `🦍 fs-gorilla armed` notification on startup (from `sudo fs-gorilla restart`) so you know it's alive.

If nothing fires, check in order:

```bash
fs-gorilla                                 # daemon : loaded ?
sudo tail -30 /var/log/fs-gorilla.err.log  # eslogger TCC errors?
pgrep -fl eslogger                         # eslogger process alive?
```

The usual culprit is stale TCC — remove `/usr/local/bin/fs-gorilla` from Full Disk Access, re-add it, toggle on, then `sudo fs-gorilla restart`.

## VSCodium / VS Code integration

env-gorilla works with VSCodium using the attach debugger pattern — secrets stay in memory, zero files on disk.

`.vscode/tasks.json`:
```json
{
    "version": "2.0.0",
    "tasks": [
        {
            "label": "🦍 FastAPI",
            "type": "shell",
            "command": "env-gorilla project_x -- bash -c '(sleep 3 && open -a \"Google Chrome\" \"http://127.0.0.1:8000\") & python -m debugpy --listen 5678 --wait-for-client -m uvicorn src.api.app:app'",
            "isBackground": true,
            "problemMatcher": {
                "owner": "uvicorn",
                "pattern": { "regexp": "^$" },
                "background": {
                    "activeOnStart": true,
                    "beginsPattern": ".",
                    "endsPattern": "Application startup complete"
                }
            },
            "presentation": {
                "reveal": "always",
                "panel": "dedicated"
            }
        }
    ]
}
```

`.vscode/launch.json`:
```json
{
    "version": "0.2.0",
    "configurations": [
        {
            "name": "Debug: FastAPI",
            "type": "debugpy",
            "request": "attach",
            "connect": {
                "host": "localhost",
                "port": 5678
            },
            "justMyCode": true,
            "preLaunchTask": "🦍 FastAPI"
        }
    ]
}
```

F5 → env-gorilla injects secrets in memory → debugpy starts → debugger attaches. Zero files on disk. Requires `debugpy` in your venv: `pip install debugpy`

## Verify

```bash
ssh-add -l                              # SSH key loaded?
env-gorilla --list                      # Projects visible?
env-gorilla project_x -- env | head     # Secrets injecting?
ssh myserver.com                        # SSH working?
```

## No TouchID Mode

For Macs without Touch ID hardware, or if you opt out of Touch ID at install time:

- All tools fall back to master password prompt
- `touchid-gorilla` binary is skipped during install
- KeePassXC Quick Unlock not available — password after each screen lock
- Use a shorter (but strong) master password for convenience
- Everything else works identically

## Updating secrets

When a project's `.env` changes:

```bash
DB="$HOME/Library/Mobile Documents/com~apple~CloudDocs/KeePassDB.kdbx"
keepassxc-cli attachment-rm "$DB" "ENV/project_x" .env
keepassxc-cli attachment-import "$DB" "ENV/project_x" .env ~/Projects/project_x/.env
```

Or via KeePassXC GUI: open entry → Advanced → Attachments → remove old → add new.

## Uninstall

```bash
# Remove tools
trash ~/bin/env-gorilla ~/bin/ssh-gorilla.sh
trash ~/bin/touchid-gorilla ~/bin/touchid-gorilla.swift

# Remove Touch ID stored password
~/bin/touchid-gorilla delete

# Remove fs-gorilla daemon (if installed)
sudo fs-gorilla stop
sudo trash /Library/LaunchDaemons/com.slav-it.s3c-gorilla.plist
sudo trash /usr/local/bin/fs-gorilla

# Remove shell integration from .zprofile
# Delete the line: source "$HOME/bin/ssh-gorilla.sh"
```

## Troubleshooting

| Problem | Fix |
|---|---|
| "Agent has no identities" | Lock/unlock KeePassXC. Check SSH entry settings. |
| "Failed to store: -34018" | Ad-hoc signing can't access Secure Enclave reliably. Re-run `./install.sh` and pick an Apple Development or Distribution identity (not `0) ad-hoc`) at the prompt. |
| "Failed to create Secure Enclave key" | Same fix — needs a Developer identity + `touchid-gorilla.entitlements`. If your Mac lacks Secure Enclave hardware, Touch ID / SE mode isn't available. |
| env-gorilla "Failed to extract" | Check: `keepassxc-cli ls "$DB" "ENV/"` — entry must have `.env` attachment |
| SSH asks for passphrase | KeePassXC not running or locked. Check `ssh-add -l` |
| Touch ID not prompting | Enable in KeePassXC Settings → Security → Quick Unlock |
| SSH uses file instead of agent | Move `~/.ssh/id_rsa` to `~/.ssh/id_rsa.offline` — key should be attachment only |
| fs-gorilla: no events logged | Grant Full Disk Access to `/usr/local/bin/fs-gorilla`, then `sudo fs-gorilla restart`. Check `/var/log/fs-gorilla.err.log` — eslogger dies on missing FDA. |
| fs-gorilla: nothing fires from my shell | By design — only `claude` / `opencode` (and their child shells/interpreters) are watched. Trigger the path from inside a Claude session. |
