![Version](https://img.shields.io/badge/version-0.9-green.svg)
![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)
![macOS](https://img.shields.io/badge/macOS-12%2B-black?logo=apple&logoColor=white)
![KeePassXC](https://img.shields.io/badge/KeePassXC-2.7%2B-69A626?logo=keepassxc&logoColor=white)
![Swift](https://img.shields.io/badge/Swift-5.9%2B-FA7343?logo=swift&logoColor=white)
![Bash](https://img.shields.io/badge/Bash-5.0%2B-4EAA25?logo=gnubash&logoColor=white)
![Touch ID](https://img.shields.io/badge/Touch%20ID-supported-black?logo=apple&logoColor=white)

![Icon](icon.png)

# s3c-gorilla

These days coding with LLMs is increasingly dangerous. Mostly when you have tons of `.env` files, SSH credentials stored on your hard drive to run things locally.

So the Germans started writing a password manager back in 2017. Even the French approved it. 10 guys keep supporting it till this day.

It's called `KeePassXC` where you can attach files into DB and it has SSH Agent Mode.

**What it means for you:** no more sensitive files stored on your hard drive openly. One encrypted file stores secrets. Great!

-- 

## So whats `s3c-gorilla` then?

It's built on top of `KeePassXC` and it includes 4 things to solve this problem securely and effortlessly!

With the help of `osascript` + `Apple TouchID` here is the setup you will have:

```
You boot macOS
  → SSH or run a project that needs secrets
    → KeePassXC opens → type master password once
      → SSH works, env-gorilla injects secrets
        → lock screen / close lid → Touch ID to resume
          → repeat until reboot or quit KeePassXC
```

- **Is is convenient?** Yes, using `TouchID` + `osascripts` makes everything effortless. 
  - Drop the password DB file into iCloud folder and `sync` is solved by Apple. 
- **Is it still secure?** Yes, since entering password once needed. 

Nothing is stored on disk. Keys and secrets exist in memory only while
KeePassXC is unlocked. Lock your screen, close the lid, or log off
— everything is wiped from memory instantly.

--

## Tools

- **ssh-gorilla** — secure SSH via KeePassXC Agent, auto-unlock with Touch ID
- **env-gorilla** — run any command with secrets injected from KeePassXC, pure memory
- **gorilla-touchid** — Touch ID gate for your master password (Swift binary)
- **VSCodium / VS Code** — debugpy attach pattern, secrets in memory, zero files

> **TODO:** Migrate gorilla-touchid from Keychain to `Secure Enclave` storage.
> Requires wrapping in a proper `.app` bundle with provisioning profile —
> Apple blocks Secure Enclave access from standalone CLI binaries.

---

### ssh-gorilla

Wraps your `ssh` command — if KeePassXC is locked, it triggers unlock (Touch ID or manual), waits, then connects. Your private key never touches disk, only lives in memory when unlocked. Also prepends `root@` to bare hostnames.

```bash
ssh myserver.com
# KeePassXC locked? → Touch ID prompt → unlock → connected
```

### env-gorilla

Runs any command with secrets injected from KeePassXC. No `.env` files written anywhere — secrets exist in process memory only and vanish when the process exits.

```bash
env-gorilla project_x -- python main.py
env-gorilla project_y -- npm run dev
```

### gorilla-touchid

Compiled Swift binary that gates your KeePassXC master password behind Touch ID. Type it once, tap your finger after. Password stays local to the device, never synced or exported.

```bash
gorilla-touchid store    # one-time setup
gorilla-touchid          # retrieves password via Touch ID
gorilla-touchid delete   # remove stored password
```

### VSCodium / VS Code

env-gorilla runs as a pre-launch task using the `debugpy` attach pattern — secrets are injected into the running process, debugger attaches after. Zero files, pure memory.

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
            },
            "options": {
                "env": {
                    "PYTHONPATH": "${workspaceFolder}",
                    "DEBUG": "True",
                    "VERBOSE": "True"
                }
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

F5 → env-gorilla injects secrets in memory → debugpy starts → debugger attaches. Zero files. Requires `debugpy` in your venv: `pip install debugpy`

## Adding projects

```bash
DB="$HOME/Library/Mobile Documents/com~apple~CloudDocs/db.kdbx"

keepassxc-cli mkdir "$DB" "ENV"
keepassxc-cli add "$DB" "ENV/project_x"
keepassxc-cli attachment-import "$DB" "ENV/project_x" .env ~/Projects/project_x/.env
```

## Updating .env files

```bash
keepassxc-cli attachment-rm "$DB" "ENV/project_x" .env
keepassxc-cli attachment-import "$DB" "ENV/project_x" .env ~/Projects/project_x/.env
```

Or via KeePassXC GUI: entry → Advanced → Attachments → replace.

## Security model

- SSH private key: encrypted attachment inside `.kdbx`, not a file on disk
- `.env` secrets: encrypted attachments, injected into process memory at runtime
- No temp files, no cache files, no plaintext on disk — ever
- Master password: stored in macOS Keychain, guarded by Touch ID (MacBook only)
- Screen lock: SSH keys removed from agent automatically
- Terminal close: `$GORILLA_PW` env var dies with the shell session

### What this protects against
- Malware scanning disk for SSH keys or `.env` files
- Accidental `.env` commits to git
- Backup/disk theft — secrets are encrypted at rest
- Shoulder surfing — Touch ID replaces visible password typing

### What this does NOT protect against
- Physical coercion (forced Touch ID)
- Compromised machine with active KeePassXC session
- Memory forensics on a running process

## Files
s3c-gorilla/
├── env-gorilla              # .env injection tool (pure memory)
├── ssh-gorilla.sh           # SSH wrapper (source in .zprofile)
├── gorilla-touchid.swift    # Touch ID helper (compiled on install)
├── install.sh               # Installer
├── .vscode/
│   ├── tasks.example.json   # VSCodium task example
│   └── launch.example.json  # VSCodium launch example
├── README.md
└── INSTALL.md

## License
MIT
