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
2. Save to: `~/Library/Mobile Documents/com~apple~CloudDocs/db.kdbx`
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
DB="$HOME/Library/Mobile Documents/com~apple~CloudDocs/db.kdbx"

keepassxc-cli mkdir "$DB" "ENV"
keepassxc-cli add "$DB" "ENV/project_x"
keepassxc-cli attachment-import "$DB" "ENV/project_x" .env ~/Projects/project_x/.env
```

### 6. Store Touch ID password (MacBook only)

```bash
env-gorilla --setup
```

### 7. Auto-start KeePassXC

System Settings → General → Login Items → add KeePassXC

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
            "command": "env-gorilla project_x -- python -m debugpy --listen 5678 --wait-for-client -m uvicorn src.api.app:app --reload --port 8000",
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

## Hackintosh notes

- No Touch ID — all tools fall back to master password prompt
- `gorilla-touchid` binary is skipped during install
- KeePassXC Quick Unlock not available — password after each screen lock
- Use a shorter (but strong) master password for convenience
- Everything else works identically

## Updating secrets

When a project's `.env` changes:

```bash
DB="$HOME/Library/Mobile Documents/com~apple~CloudDocs/db.kdbx"
keepassxc-cli attachment-rm "$DB" "ENV/project_x" .env
keepassxc-cli attachment-import "$DB" "ENV/project_x" .env ~/Projects/project_x/.env
```

Or via KeePassXC GUI: open entry → Advanced → Attachments → remove old → add new.

## Uninstall

```bash
# Remove tools
trash ~/bin/env-gorilla ~/bin/ssh-gorilla.sh
trash ~/bin/gorilla-touchid ~/bin/gorilla-touchid.swift

# Remove Touch ID stored password
~/bin/gorilla-touchid delete

# Remove shell integration from .zprofile
# Delete the line: source "$HOME/bin/ssh-gorilla.sh"
```

## Troubleshooting

| Problem | Fix |
|---|---|
| "Agent has no identities" | Lock/unlock KeePassXC. Check SSH entry settings. |
| "Failed to store: -34018" | Sign gorilla-touchid with a developer identity, not ad-hoc |
| env-gorilla "Failed to extract" | Check: `keepassxc-cli ls "$DB" "ENV/"` — entry must have `.env` attachment |
| SSH asks for passphrase | KeePassXC not running or locked. Check `ssh-add -l` |
| Touch ID not prompting | Enable in KeePassXC Settings → Security → Quick Unlock |
| SSH uses file instead of agent | Move `~/.ssh/id_rsa` to `~/.ssh/id_rsa.offline` — key should be attachment only |
