# s3c-gorilla — Documentation

A macOS security suite that puts every SSH key, `.env`, and TOTP
seed behind KeePassXC + the Secure Enclave + Touch ID. You type
your KeePass master password once per session, and Touch ID gates
every secret access after that.

---

## The tools

| Binary | Role |
|---|---|
| `s3c-gorilla` | Umbrella CLI — status, doctor, scan, keychain migration. |
| `touchid-gorilla` | SE wrap/unwrap primitive + fan-out session bootstrap. |
| `env-gorilla` | Injects `.env` secrets from the kdbx into a child process. |
| `otp-gorilla` | TOTP code viewer + clipboard copy. |
| `s3c-ssh-agent` | SSH agent (LaunchAgent) backed by the Secure Enclave. |
| `ssh-gorilla.sh` | SSH wrapper with hostname shortcuts. |

All live in `/usr/local/bin/`, root-owned mode `0555`.

---

## How a session works

1. **You type the KeePass master password once.** First `ssh`,
   `env-gorilla`, or `otp-gorilla` call after boot / logout /
   screen-lock / 2h idle triggers the prompt.
2. **Fan-out extracts every secret from the vault.**
   `touchid-gorilla fan-out` runs under a flock, opens the kdbx
   once, walks every entry under `SSH/`, `ENV/`, `2FA/`, and
   chip-wraps each into its own `.s3c` file in
   `/tmp/s3c-gorilla/`. The master password never hits disk and
   is zeroed from memory before fan-out returns.
3. **Every subsequent tool call = one Touch ID.** Each tool
   unwraps exactly the one blob it needs. Per-secret coercion
   scope: a coerced fingerprint reveals one secret, not the vault.
4. **Sessions expire.** Configurable TTL (`GORILLA_UNLOCK_TTL`,
   default 2 hours). Screen-lock wipes by default. Logout wipes.
   Reboot wipes.

---

## `s3c-gorilla` CLI reference

```
s3c-gorilla                         # same as `status`
s3c-gorilla status                  # agent state, TTL, paths, kdbx reachability
s3c-gorilla doctor                  # full health check — codesign, modes, deps, hw
s3c-gorilla setup                   # re-run install.sh
s3c-gorilla wipe                    # force session kill (wipe blobs, restart agent)

s3c-gorilla ssh list                # names of SSH keys currently in the vault
s3c-gorilla env list                # names of .env projects
s3c-gorilla otp list                # names of TOTP services

s3c-gorilla scan                    # default = --env
s3c-gorilla scan --env              # plaintext .env files under project roots
s3c-gorilla scan --ssh              # ~/.ssh/ audit (plaintext keys, modes)
s3c-gorilla scan --git              # secret-shaped strings in git history
s3c-gorilla scan --shell-history    # zsh/bash/fish history grep
s3c-gorilla scan --all              # all four

s3c-gorilla keychain check          # what's in macOS Keychain that should be in kdbx?
s3c-gorilla keychain import         # copy Keychain items into kdbx (non-destructive)
s3c-gorilla keychain fix            # verify in kdbx, then remove from Keychain

s3c-gorilla -h                      # global help
s3c-gorilla <cmd> -h                # per-subcommand help
```

All `scan` subcommands **redact** matched values — they report
"pattern N at `<file>:<line>`", never the secret bytes themselves.

---

## Individual tool usage

### env-gorilla
```
env-gorilla <project> -- <cmd> [args...]
env-gorilla --paranoid <project> -- <cmd>       # skip cache, prompt master pw
env-gorilla --pw-terminal <project> -- <cmd>    # terminal prompt instead of dialog
env-gorilla --pw-dialog <project> -- <cmd>      # force dialog prompt
```
`<project>` matches the KeePassXC entry under `ENV/<project>`.
The `.env` is injected into the child process's environment only
— never written to disk, never exported to the parent shell.

### otp-gorilla
```
otp-gorilla <service>            # fuzzy-match; e.g. `otp-gorilla atlas` → Atlassian
otp-gorilla --paranoid <service> # skip cache, prompt master pw
```
Prints the 6-digit (or 8-digit) code, copies to clipboard, fires
a macOS notification.

### ssh-gorilla.sh (wrapper)
```
ssh <host>                        # normal ssh, agent handles auth
ssh bare-hostname                 # root@bare-hostname prepend if no user given
```

### touchid-gorilla (primitive)
```
touchid-gorilla wrap <name>              # encrypt stdin → /tmp/s3c-gorilla/<name>.s3c
touchid-gorilla unwrap <name>            # Touch ID → decrypt → stdout
touchid-gorilla wrap-list                # list blob names
touchid-gorilla wrap-clear [name]        # wipe one or all blobs
touchid-gorilla fan-out                  # session bootstrap (usually auto-invoked)
touchid-gorilla master-prompt --label X  # secure master-pw prompt (internal)
```

---

## Configuration

File: `~/.config/s3c-gorilla/config` (copied from
`src/setup/config.example` at install time).

| Knob | Default | Meaning |
|---|---|---|
| `GORILLA_DB` | `~/Library/Mobile Documents/com~apple~CloudDocs/KeePassDB.kdbx` | Path to your kdbx. |
| `GORILLA_ENV_GROUP` | `ENV` | KeePassXC group for `.env` attachments. |
| `GORILLA_OTP_GROUP` | `2FA` | KeePassXC group for TOTP entries. |
| `GORILLA_SSH_MODE` | `chip-wrap` | `chip-wrap` (keep existing key) or `se-born` (chip-generated). |
| `GORILLA_UNLOCK_TTL` | `7200` | Seconds of inactivity before session expires. |
| `GORILLA_MASTER_PW_PROMPT` | `dialog` | `dialog` (secure input) or `terminal` (`read -s`). |
| `GORILLA_WIPE_ON_SCREEN_LOCK` | `1` | `1` wipes blobs on screen lock; `0` keeps sessions. |
| `GORILLA_PUSHER_ALLOWLIST` | `org.keepassxc.keepassxc` | Bundle IDs allowed to push SSH keys into our agent. |
| `GORILLA_SCAN_ROOTS` | `~/Projects:~/Code:~/Workspaces:~/src` | Colon-separated scan paths. |

---

## File layout

```
/usr/local/bin/
├── s3c-gorilla              (0555 root:wheel)
├── s3c-ssh-agent            (0555 root:wheel)
├── touchid-gorilla          (0555 root:wheel)
├── env-gorilla              (0555 root:wheel)
├── otp-gorilla              (0555 root:wheel)
└── ssh-gorilla.sh           (0555 root:wheel)

/usr/local/share/s3c-gorilla/
├── agent.cdhash             (root-owned pin, Concern #43)
├── touchid-gorilla.cdhash   (root-owned pin, Concern #43)
└── install-source           (path to the repo install was run from)

~/.config/s3c-gorilla/
└── config                   (your local overrides)

~/.s3c-gorilla/                        (mode 0700)
├── agent.sock                          (mode 0600)
├── keys.json.s3c                       (mode 0600, chip-wrapped registry)
└── pubkeys/
    └── <name>.pub                      (public halves, plaintext)

/tmp/s3c-gorilla/                       (mode 0700, wiped at session end)
├── .bootstrap.lock                     (flock)
├── .session-valid                      (sentinel — present = fan-out completed)
├── ssh-<name>.s3c                      (mode 0600, chip-wrapped SSH key)
├── env-<project>.s3c                   (mode 0600, chip-wrapped .env)
└── otp-<service>.s3c                   (mode 0600, chip-wrapped TOTP URI)
```

---

## Security model

### What's protected

- **KeePass master password** never stored on disk, never in any
  persistent cache, zeroed from memory as soon as fan-out finishes.
- **Per-secret blobs** in `/tmp/s3c-gorilla/` are encrypted with a
  biometry-gated Secure Enclave key (`.biometryCurrentSet`). Touch
  ID hardware-enforced at every decrypt.
- **Session boundaries**: fresh master-pw prompt after reboot,
  logout, screen-lock (configurable), and `GORILLA_UNLOCK_TTL`
  idle expiry.
- **Binaries** are signed with hardened runtime + timestamp, mode
  `0555` root-owned, and self-verify their own codesign + cdhash
  against a pinned hash at every launch.
- **Agent socket** accepts `SSH_AGENTC_ADD_IDENTITY` only from a
  bundle-ID allowlist (default: KeePassXC).
- **Core dumps disabled** (`RLIMIT_CORE=0`) on every binary that
  touches secrets.
- **Bulk XML export buffer** during fan-out is `mlock()`'d —
  pinned in physical memory, never paged to swap.

### What's NOT protected

Honest threat model. This tool raises the bar, it doesn't make
you invincible.

- **Same-uid code execution during the fan-out window.** For
  ~100-500ms every session start, every vault secret is
  simultaneously live in the `touchid-gorilla fan-out` process's
  locked memory. An attacker with code execution as your uid AND
  the right entitlements (debugger attach, `vm_read`) can read
  everything during that window. Hardened runtime raises the bar
  but isn't absolute.
- **Agent socket admission** is uid-based, same as any mainstream
  ssh-agent. The bundle-ID whitelist is defense-in-depth, not
  cryptographic peer authentication.
- **`--paranoid` narrows extraction, not execution.** Env vars
  injected into a child process remain readable via `ps eww <pid>`
  to any same-uid process for the child's lifetime.
- **Keychain migration is one-way.** `s3c-gorilla keychain fix`
  deletes from Keychain after verifying in kdbx — but once the
  Keychain entry is gone, restoration means re-entering the
  secret.

---

## Troubleshooting

### "Master password prompt keeps appearing"

Likely your `GORILLA_UNLOCK_TTL` is tight, your screen locks often
with `GORILLA_WIPE_ON_SCREEN_LOCK=1`, or the agent is dying. Run
`s3c-gorilla doctor` — if agent state is not `running`, kick it:

```bash
launchctl kickstart -k gui/$UID/com.slav-it.s3c-ssh-agent
```

### "Touch ID not available" error

SE key was invalidated by a fingerprint enrollment change (Touch
ID re-enrolled). Tool auto-detects and offers to re-seed — next
call will re-prompt master pw and rebuild blobs. Manual force:

```bash
s3c-gorilla wipe
```

### "codesign check failed" on agent startup

Binary integrity (Concern #43 Layer 2) failed. Either the binary
on disk is tampered, or a re-install is mid-flight without a
completed cdhash pin refresh. Re-run install:

```bash
s3c-gorilla setup
```

### KeePassXC kdbx not found / evicted

If the kdbx lives in iCloud Drive with "Optimize Mac Storage" on,
the file may be evicted locally. Open KeePassXC once in Finder
(this materializes the file) then retry. Or disable
"Optimize Mac Storage" in System Settings → Apple Account →
iCloud Drive.

### "waiting for initial secret extraction (N/M)" stalls

Fan-out is in progress on a large vault. Expected on first call
after a fresh session. Wait — progress counter updates every 5
entries. If it hangs past 120 seconds, the holder process has
stalled; `touchid-gorilla wrap-clear` then retry.

---

## Related docs

- [01-SETUP_GUIDE.md](01-SETUP_GUIDE.md) — installation + first-time KeePassXC setup.
- [03-SETUP_KEYBOARD_MAESTRO.md](03-SETUP_KEYBOARD_MAESTRO.md) — optional Keyboard Maestro macros for global OTP paste.
- [plan/PLAN.md](../plan/PLAN.md) — internal implementation spec, 43 resolved concerns, architecture detail.
