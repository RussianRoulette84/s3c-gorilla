# s3c-gorilla — Documentation

A macOS security suite that puts every SSH key, `.env`, and TOTP
seed behind KeePassXC. It runs in **two modes**, picked automatically
at install time:

- **Chip mode** (Macs with Touch ID / Secure Enclave) — secrets are
  locked by a Secure Enclave key; Touch ID gates every decrypt.
- **Password mode** (no Secure Enclave, e.g. Intel / Hackintosh) —
  no hardware gate; the master password is typed once per terminal
  tab and held in a memory-only helper.

You type your KeePass master password once per session either way.

---

## The tools

| Binary | Role |
|---|---|
| `s3c-gorilla` | Umbrella CLI — status, doctor, list, wipe/lock, scan, keychain, setup, uninstall. |
| `env-gorilla` | Injects a project's `.env` from the kdbx into a child process (memory only). |
| `otp-gorilla` | TOTP code viewer + clipboard copy (computed locally). |
| `ssh-gorilla.sh` | `ssh` wrapper with hostname shortcuts; points SSH at our agent. |
| `touchid-gorilla` | Secure Enclave primitive: wrap/unwrap, SE-born SSH keys, local TOTP, secure prompt. **Chip mode only** (not installed without an SE). |
| `s3c-ssh-agent` | SSH signing agent (LaunchAgent): `chip-wrap` / `se-born` / `password` modes + KeePassXC GUI push. |
| `s3c-session-agent` | Per-tab master-password holder for password mode (type it once per terminal). |

All live in `/usr/local/bin/`, root-owned, mode `0755`.

---

## How a session works

### Chip mode (Touch ID)

1. **You type the KeePass master password once** — the first `ssh`,
   `env-gorilla`, or `otp-gorilla` call after boot / logout / 2h idle
   triggers the prompt (secure keyboard entry via
   `touchid-gorilla master-prompt`).
2. **Fan-out extracts every secret from the vault.** The
   `fan_out_all` helper opens the kdbx once (using
   `keepassxc-cli export --format xml` piped to `s3c-kdbx-parse` when
   possible, otherwise per-secret), walks `SSH/`, `ENV/`, `2FA/`, and
   chip-wraps each into its own `/tmp/s3c-gorilla/<name>.blob` via the
   single Secure Enclave wrap key. The master password is never
   written to disk.
3. **Every later tool call = one Touch ID.** Each tool unwraps only
   the one blob it needs.
4. **Sessions expire.** Cached blobs are trusted only if newer than
   the last boot; reboot / logout / 2h idle all force a fresh master
   password prompt.

### Password mode (no chip)

There is no Secure Enclave, so nothing is chip-wrapped. By default
every call re-prompts the master password. If `GORILLA_SESSION_UNLOCK`
is on, a per-tab `s3c-session-agent` holds the password (AES-GCM
sealed, `mlock`'d, memory only) and serves env/otp/ssh so they stop
re-prompting **in that terminal tab**. It is wiped on tab close,
logout, screen lock, or TTL expiry.

---

## `s3c-gorilla` CLI reference

```
s3c-gorilla                         # same as `status`
s3c-gorilla status                  # mode, active per-tty sessions, binaries, vault, paths
s3c-gorilla doctor                  # health check — deps, codesign, config, agent logs, mode
s3c-gorilla wipe                    # kill all sessions (chip: wrap-clear + restart agent)
s3c-gorilla lock                    # end THIS terminal's session only

s3c-gorilla list ssh                # names of SSH keys currently loaded
s3c-gorilla list env                # names of .env projects
s3c-gorilla list otp                # names of TOTP services

s3c-gorilla scan                    # default = --env
s3c-gorilla scan --env              # plaintext .env files under your scan roots
s3c-gorilla scan --ssh              # ~/.ssh/ audit (unencrypted keys, bad modes)
s3c-gorilla scan --git              # secret-shaped strings in git history
s3c-gorilla scan --shell-history    # zsh/bash/fish history grep
s3c-gorilla scan --all              # all four

s3c-gorilla keychain check          # macOS Keychain creds that belong in the kdbx
s3c-gorilla keychain import         # copy Keychain items into kdbx (non-destructive)
s3c-gorilla keychain fix            # verify in kdbx, then remove from Keychain (per-item y/N)

s3c-gorilla setup                   # re-run the installer from the recorded source path
s3c-gorilla uninstall               # remove binaries/agents; kdbx left untouched
```

All `scan` output is **redacted** — it reports "pattern N at
`<file>:<line>`", never the secret bytes.

---

## Individual tool usage

### env-gorilla
```
env-gorilla <project> -- <cmd> [args...]
env-gorilla <p1>,<p2> -- <cmd>         # merge several .envs into one session
env-gorilla --list                     # list available projects
env-gorilla --clear [project]          # wipe one (or all) cached env blobs
env-gorilla --paranoid <project> -- <cmd>   # no cache/fan-out; master pw this run only
```
The `.env` is injected into the child process's environment only —
never written to disk, never exported to the parent shell.

### otp-gorilla
```
otp-gorilla <service>              # fuzzy match; e.g. `otp-gorilla atlas` → Atlassian
otp-gorilla --paranoid <service>   # no cache; master pw this run only
```
Prints the code, copies it to the clipboard, fires a macOS
notification.

### ssh-gorilla.sh (wrapper)
```
ssh <host>                         # normal ssh; our agent handles auth
ssh bare-hostname                  # prepends root@ when no user is given
```

### touchid-gorilla (chip-mode primitive)
```
touchid-gorilla wrap <name>              # encrypt stdin → /tmp/s3c-gorilla/<name>.blob
touchid-gorilla unwrap <name>            # Touch ID → decrypt → stdout
touchid-gorilla wrap-list                # list blob names
touchid-gorilla wrap-clear [name]        # wipe one or all blobs
touchid-gorilla ssh-generate             # mint an SE-born SSH key
touchid-gorilla ssh-pub                  # print the SE-born public key
touchid-gorilla ssh-delete               # remove the SE-born key
touchid-gorilla totp <secret>            # compute a TOTP code locally
touchid-gorilla master-prompt <label>    # secure master-pw prompt (internal)
```

---

## Configuration

File: `~/.config/s3c-gorilla/config` (copied from
`src/setup/config.example` on first install; re-running the installer
won't overwrite it).

| Knob | Default | Meaning |
|---|---|---|
| `GORILLA_DB` | `~/Library/Mobile Documents/com~apple~CloudDocs/KeePassDB.kdbx` | Path to your kdbx. |
| `GORILLA_ENV_GROUP` | `ENV` | KeePassXC group for `.env` attachments. |
| `GORILLA_OTP_GROUP` | `2FA` | KeePassXC group for TOTP entries. |
| `GORILLA_SSH_MODE` | `chip-wrap` | `chip-wrap` (keep existing key) or `se-born` (chip-generated). Set only on Touch ID machines. |
| `GORILLA_SESSION_UNLOCK` | `false` | Hold the master password in a per-tab memory agent so env/otp/ssh stop re-prompting. Defaults OFF; on Touch ID machines it bypasses the per-decrypt fingerprint gate. |
| `GORILLA_UNLOCK_TTL` | `7200` | Seconds the session agent holds the password before it self-expires (activity resets it). |
| `GORILLA_SCAN_ROOTS` | `~/Projects:~/Code:~/Workspaces:~/src` | Extra colon-separated roots for `s3c-gorilla scan`. |
| `GORILLA_PARANOID` | `false` | Global paranoid mode — never cache or fan out; extract the one requested secret and discard. |

---

## File layout

```
/usr/local/bin/                        (binaries, 0755 root:wheel)
├── s3c-gorilla
├── env-gorilla
├── otp-gorilla
├── ssh-gorilla.sh
├── touchid-gorilla                    (chip machines only)
├── s3c-ssh-agent
├── s3c-session-agent
└── s3c-kdbx-parse                     (XML fan-out fast path)

/usr/local/share/s3c-gorilla/
├── banners.sh, godfather.sh, …        (sourced helper libs)
├── s3c-scan.sh, s3c-keychain.sh       (scan + keychain logic)
└── install-source                     (path the installer was run from)

~/.config/s3c-gorilla/config           (your local overrides)

/tmp/s3c-gorilla/                       (mode 0700, wiped at session end — chip mode)
├── .session-valid                      (sentinel — present = fan-out completed)
├── env-<project>.blob                  (chip-wrapped .env)
├── ssh-<name>.blob                     (chip-wrapped SSH key)
└── otp-<service>.blob                  (chip-wrapped TOTP)
```

---

## Security model

### What's protected (built today)

- **Master password never stored** on disk or in any persistent
  cache. In chip mode it's zeroed after fan-out; in password mode the
  session agent holds it AES-GCM-sealed and `mlock`'d, memory only.
- **Per-secret blobs** (chip mode) are encrypted with a
  biometry-gated Secure Enclave key (`.biometryCurrentSet`), so a new
  fingerprint enrollment invalidates them. Touch ID is hardware-
  enforced at every decrypt.
- **Sessions end** on reboot, logout, and idle (`GORILLA_UNLOCK_TTL`);
  the password-mode session agent also wipes on tab close and screen
  lock.
- **No core dumps** — `RLIMIT_CORE = 0` on the agents that hold
  secrets, so a crash can't spill the heap.
- **Secure keyboard entry** on the master-password prompt
  (`EnableSecureEventInput`) shields it from user-level keyloggers.
- **Agent peer check** — `s3c-ssh-agent` reads the connecting
  process's identity (`getpeereid`) and rejects/logs key pushes that
  aren't from a trusted peer (KeePassXC).
- Binaries are root-owned, mode `0755`, ad-hoc signed.

### What's NOT protected (honest — some of it not built yet)

- **Tamper-detection on the binaries is _not_ implemented.** There is
  no hardened-runtime + timestamp signing, no `SecCodeCheckValidity`
  self-check, and no `cdhash` pin. Swapping a binary on disk will
  **not** stop it from launching. (Planned, not shipped.)
- **The bulk fan-out buffer is not `mlock`'d yet.** The agents' pw
  caches are pinned; the one-shot extraction buffer is not.
- **Same-uid code execution.** An attacker already running as your
  uid (with debugger / `task_for_pid`) can read secrets from a live
  process — including the master password out of the session agent,
  whose sealing key sits in the same address space. The sealing buys
  hygiene, not a boundary against root.
- **`--paranoid` narrows extraction, not execution.** Env vars
  injected into a child stay readable via `ps eww <pid>` to any
  same-uid process for the child's lifetime.
- **Keychain migration is one-way.** `keychain fix` deletes from
  Keychain only after verifying the item is in the kdbx, but
  restoring it means re-entering the secret.

---

## Troubleshooting

### "Master password prompt keeps appearing"

Your `GORILLA_UNLOCK_TTL` may be tight, or (password mode) the
session agent died. Run `s3c-gorilla doctor`; if the agent isn't
running, kick it:

```bash
launchctl kickstart -k gui/$UID/com.slav-it.s3c-ssh-agent
```

### "Touch ID not available" / decrypt fails

The Secure Enclave key was invalidated by a fingerprint enrollment
change. Force a clean re-seed — the next call re-prompts the master
password and rebuilds the blobs:

```bash
s3c-gorilla wipe
```

### KeePassXC kdbx not found / evicted

If the kdbx lives in iCloud Drive with "Optimize Mac Storage" on, the
file may be evicted locally. Open KeePassXC once in Finder to
materialize it, then retry — or turn off "Optimize Mac Storage" in
System Settings → Apple Account → iCloud Drive.

---

## Related docs

- [01-SETUP_GUIDE.md](01-SETUP_GUIDE.md) — installation + first-time KeePassXC setup.
- [03-SETUP_KEYBOARD_MAESTRO.md](03-SETUP_KEYBOARD_MAESTRO.md) — optional Keyboard Maestro macros for global OTP paste.
- [plans/PLAN.md](../plans/PLAN.md) — internal implementation spec + architecture detail.
