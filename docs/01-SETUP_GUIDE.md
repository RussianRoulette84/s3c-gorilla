# 🦍 s3c-gorilla — Installation Guide

## Prerequisites

- macOS 12+ (Monterey or later)
- [Homebrew](https://brew.sh/)
- Xcode Command Line Tools: `xcode-select --install`

The installer puts binaries in `/usr/local/bin` (root-owned) and
wires up your shell PATH for you.

## Quick Install

```bash
chmod +x install.sh
./install.sh
```

The installer handles everything: pulls `keepassxc-cli` (and
`terminal-notifier`) via Homebrew if missing, auto-detects Touch ID /
Secure Enclave hardware, compiles + signs the Swift binaries, picks
your KeePassXC database, sets the SSH mode, and adds shell
integration. On a Mac **without** a Secure Enclave it installs in
password mode (no `touchid-gorilla`, no chip wrapping).

## Post-Install Setup

### 1. KeePassXC database

If you don't have one yet:

1. Open KeePassXC → Create New Database
2. Save to: `~/Library/Mobile Documents/com~apple~CloudDocs/KeePassDB.kdbx`
   (or wherever you like — the installer asks, and stores it as
   `GORILLA_DB` in `~/.config/s3c-gorilla/config`)
3. Set a strong master password

### 2. KeePassXC settings

- Settings → Security → Enable Touch ID Quick Unlock (Touch ID Macs)
- Settings → SSH Agent → Enable SSH Agent integration (lets KeePassXC
  push keys straight into our agent with no Touch ID)

### 3. Add an SSH key

The installer's SSH step can import `~/.ssh/id_rsa` into the kdbx for
you. To do it by hand:

1. New entry → title: "My Private SSH"
2. Password field: your SSH key passphrase
3. Advanced → Attachments → Add → `~/.ssh/id_rsa`
4. SSH Agent tab → Private Key: Attachment `id_rsa`
5. Check: Add key to agent when database is opened
6. Check: Remove key from agent when database is closed
7. Save
8. Move your key off disk: `mv ~/.ssh/id_rsa ~/.ssh/id_rsa.offline`
9. Test: `ssh-add -l` should show your key
10. Store `id_rsa.offline` somewhere safe (USB stick, pwSafe) as an
    emergency backup

### 4. SSH config

`~/.ssh/config`:
```
Host *
  IdentitiesOnly yes
  HashKnownHosts yes
  ServerAliveInterval 60
  ServerAliveCountMax 3
```

Remove any `AddKeysToAgent`, `UseKeychain`, or `IdentityFile` lines —
the agent handles all of that now.

### 5. Add project .env files

```bash
DB="$HOME/Library/Mobile Documents/com~apple~CloudDocs/KeePassDB.kdbx"

keepassxc-cli mkdir "$DB" "ENV"
keepassxc-cli add "$DB" "ENV/project_x"
keepassxc-cli attachment-import "$DB" "ENV/project_x" .env ~/Projects/project_x/.env
```

### 6. First run (nothing to configure)

There's no `--setup` step and no stored master password. The first
`env-gorilla <project>` / `otp-gorilla` / `ssh` per session asks for
your KeePass master password in the terminal (or a native Mac dialog
when launched from a GUI app):

- **Touch ID Mac:** it chip-wraps your secrets into
  `/tmp/s3c-gorilla/` and Touch ID handles reruns until reboot /
  logout / idle.
- **No-chip Mac:** every call re-prompts, unless you turned on
  `GORILLA_SESSION_UNLOCK` — then a per-tab helper remembers the
  password for that terminal tab.

### 7. Auto-start KeePassXC

System Settings → General → Login Items → add KeePassXC

## VSCodium / VS Code integration

env-gorilla works with VSCodium using the attach-debugger pattern —
secrets stay in memory, zero files on disk.

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

F5 → env-gorilla injects secrets in memory → debugpy starts →
debugger attaches. Zero files on disk. Requires `debugpy` in your
venv: `pip install debugpy`

## Verify

```bash
ssh-add -l                              # SSH key loaded?
env-gorilla --list                      # projects visible?
env-gorilla project_x -- env | head     # secrets injecting?
ssh myserver.com                        # SSH working?
s3c-gorilla status                      # mode, sessions, vault, paths
s3c-gorilla doctor                      # full health check
```

## No Touch ID mode

For Macs without Touch ID hardware (Intel / Hackintosh), or if you
opt out at install time:

- All tools fall back to the master-password prompt.
- `touchid-gorilla` is skipped during install; nothing is chip-wrapped.
- Optionally set `GORILLA_SESSION_UNLOCK=true` to have a per-tab
  helper (`s3c-session-agent`) remember the password for that terminal
  tab — wiped on tab close, logout, screen lock, or TTL.
- Everything else works identically.

## Updating secrets

When a project's `.env` changes:

```bash
DB="$HOME/Library/Mobile Documents/com~apple~CloudDocs/KeePassDB.kdbx"
keepassxc-cli attachment-rm "$DB" "ENV/project_x" .env
keepassxc-cli attachment-import "$DB" "ENV/project_x" .env ~/Projects/project_x/.env
```

Or via the KeePassXC GUI: open entry → Advanced → Attachments →
remove old → add new. New secrets show up on the next session (or
after `s3c-gorilla wipe`).

## Uninstall

```bash
s3c-gorilla uninstall
```

Removes the binaries and agents. Your kdbx is left untouched; config
and shell-integration removal are opt-in during the prompt.

## Troubleshooting

| Problem | Fix |
|---|---|
| "Agent has no identities" | Lock/unlock KeePassXC. Check the SSH entry's SSH Agent settings. |
| "Failed to store: -34018" | Ad-hoc signing can't reach the Secure Enclave reliably. Re-run `./install.sh` and pick an Apple Development/Distribution identity (not `0) ad-hoc`) at the prompt. |
| "Failed to create Secure Enclave key" | Same fix — needs a Developer identity + `touchid-gorilla.entitlements`. If your Mac has no Secure Enclave, chip mode isn't available; it runs password mode. |
| env-gorilla "Failed to extract" | Check `keepassxc-cli ls "$DB" "ENV/"` — the entry must have a `.env` attachment. |
| SSH asks for a passphrase | KeePassXC not running or locked. Check `ssh-add -l`. |
| Touch ID not prompting | Enable KeePassXC Settings → Security → Quick Unlock. |
| SSH uses a file instead of the agent | Move `~/.ssh/id_rsa` to `~/.ssh/id_rsa.offline` — the key should live only as a kdbx attachment. |
| Master password keeps re-prompting | Tight `GORILLA_UNLOCK_TTL`, or (password mode) the session agent died — run `s3c-gorilla doctor`. |
