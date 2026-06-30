![Version](https://img.shields.io/badge/version-0.14-green.svg)
![macOS](https://img.shields.io/badge/macOS-12%2B-black?logo=apple&logoColor=white)
![KeePassXC](https://img.shields.io/badge/KeePassXC-2.7%2B-69A626?logo=keepassxc&logoColor=white)
![Swift](https://img.shields.io/badge/Swift-5.9%2B-FA7343?logo=swift&logoColor=white)
![TouchID](https://img.shields.io/badge/TouchID-Secure%20Enclave-black?logo=apple&logoColor=white)
![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)

![Icon](icon.png)

---

# s3c-gorilla

[![Demo](docs/screenshots.thumnail.png)](https://example.com/videos/s3c-gorilla-demo.mp4)

A `macOS only toolkit` built for developers and security freaks who don't like their secrets sitting on their disk.

It wires everything together using `best practices` in a `secure` but still `convenient` way.

I stores `SSH key`, `.env`, and `2FA` behind a well known encrypted vault called `KeePassXC` made by the lovely French people. Even the Germans approved it. 
And when those secrets needed then `s3c-gorilla` injects them into memory with TouchID (after entering master password at least once) locked by an encryption key that lives inside `Apple Secure Enclave` chip :D

Where did the secrets go??? Not on your disk for sure ;)

---

## Install

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/RussianRoulette84/s3c-gorilla/master/install.sh)
```

### Requirements

- **macOS 12 (Monterey) or later.** 
- **TouchID strongly recommended.** 
  - Without TouchID we can do Master password only because no chip to lean on. 
    You can optionally have it remembered for each terminal tab, so you only type it once there.
  - PLAN: voice activated unlock instead of TouchID (voice-gorilla)
- **Homebrew.** `brew` is assumed for `keepassxc-cli` and `terminal-notifier`.
- **KeePassXC 2.7+.** `brew install --cask keepassxc`, installing macOS KeePaasXC app recommended
- **A signing identity for the Swift binaries.** Developer ID Application cert recommended; the installer walks you through picking one.


---

## How it works

```
Let's say you wake up, you are 42 and you say aaaaawh and then you login into macOS.
  → You SSH into a server OR run a project that needs secrets
    → You enter KeePassXC master password "once" in terminal
      → ssh-gorilla OR env-gorilla injects the secret into memory, locked by a key that lives inside Apple's Secure Enclave chip :D 
        → Time passes. You SSH or RUN project again
          → this time "only" TouchID is enough to inject secrets (sweeeet)
            → You log off OR reboot OR even close laptop
              → Your secrets from memory are wiped
              → You need to password again to SSH or RUN things
```

Both GUI tools and terminal `ssh` go through our background agent.

> **No TouchID?** 
- Master password only — no chip to lean on. You can optionally have it remembered for each terminal tab, so you only type it once there.
- PLAN: voice activated unlock instead of TouchID (voice-gorilla project)

---

## The suite

- **s3c-gorilla** — umbrella CLI: status, health, scan for leaks, migrate Keychain creds, wipe sessions
- **env-gorilla** — run a command with a project's `.env` injected into memory only
- **ssh-gorilla** — thin `ssh` wrapper that points SSH at our agent (keys stay in the vault)
- **otp-gorilla** — show/copy 2FA codes from the vault

Middleware:
- **touchid-gorilla** — Secure Enclave primitive: wrap/unwrap secrets, SE-born keys, local TOTP, secure prompt
- **ssh-gorilla.sh** - Thin `ssh` wrapper (hostname shortcut from `ssh example.com` to `ssh root@example.com`) 
- **s3c-kdbx-parse** — reads the whole vault (XML) in one unlock and hands back each secret, so first-run fan-out is fast
- **ssh-wire.swift** — shared code for packing/unpacking SSH's byte formats, built into both SSH agents (not a program)
- **ssh-agent-core.swift** — shared ssh-agent protocol logic the session agent links against (not a program)

Background Agents:
- **s3c-ssh-agent** — Drop-in SSH agent (LaunchAgent) for SSH signing `chip-wrap` / `se-born` / `password` modes + KeePassXC GUI push (zero Touch ID). Works with SourceTree, VS Code, IntelliJ, plain `ssh`. 
- **s3c-session-agent** — per-tab master-password holder (type it once per terminal)

Extra:
- **VSCodium / VS Code** — sample config file to build with injected ENV variables

---

### Encryption Keys? Chips? Chip-born SSH keys?

Two keys live inside the chip (Apple's Secure Enclave), and neither can ever leave it:

- A **wrap key** that locks every secret you pull from the vault —
  each `.env`, each 2FA code, each SSH key — into its own encrypted
  blob. One secret per blob, each opened by its own fingerprint.
- An optional **chip-born SSH key**: instead of importing your old
  `id_rsa`, the chip can mint a brand-new SSH key that signs your
  logins without the private half ever existing outside the chip.

Both are tied to your current fingerprints and die on logout.

---

## Security model — what we guarantee

- **Two locks, not one.** Every secret needs Apple's security chip
  **and** a master password you keep in your head — unlike Apple
  Keychain, which opens with just your finger. A stolen unlocked
  Mac, or a forced fingerprint alone, still can't crack the vault.
- **The chip holds the keys.** Raw keys never leave the Secure
  Enclave and never sit readable on disk; your master password is
  never saved anywhere.
- **A fingerprint per secret.** Once unlocked, each secret takes
  its own Touch ID touch to use — and if anyone enrolls a new
  fingerprint, every existing secret dies instead of opening.
- **No-chip Mac — typed once per tab.** Without the chip, the
  password is held scrambled in locked memory and wiped when the
  tab closes.
- **Sessions really end.** Wiped on reboot, logout, screen lock,
  or 2 hours idle — and logout switches the Touch ID unlock off
  entirely.
- **A crash can't leak,** and the password box blocks keyloggers
  while you type.
- **Our key agent only trusts KeePassXC** — anything else is
  turned away.

---

## What it does in details

- **SSH keys live in your KeePassXC database.** No `id_rsa` on
  disk. Our signed SSH agent (runs as a background service, so GUI
  tools like SourceTree and VS Code work natively) signs with the
  key only at the moment you `ssh somehost`. On a chip Mac that's
  one TouchID per sign; on a no-chip Mac the key is unlocked once
  per session.
- **Per-project `.env` injection at runtime.** `env-gorilla proj
  -- npm run dev` pulls the `.env` out of kdbx straight into the
  child process's memory. Never writes to disk. Never exports to
  the parent shell. Can't be read by `cat`, `grep`, or a
  compromised editor.
- **TOTP codes from the same vault.** `otp-gorilla github` prints
  the 6-digit code, copies to clipboard, fires a native notification.
  Replaces Google Authenticator on a phone you might lose.
- **Session-bound.** Reboot, logout, screen lock, or 2 hours idle
  — secrets are wiped, next tool call re-prompts the master password.
- **Type the master password once, then forget it.**
  - **Chip Mac:** the first tool call unlocks every vault secret
    into its own chip-locked blob; after that each one needs just a
    TouchID.
  - **No-chip Mac:** a per-tab helper holds the password (scrambled
    in locked memory) so env/otp/ssh stop asking again in that tab.
  - Typing the master password ten times a day is the friction that
    makes people turn security off — we type it once.
- **Two SSH modes.** Keep your existing key (imported and locked in
  the vault), or have the chip mint a brand-new key that can never
  leave it. If KeePassXC's GUI is unlocked it can hand keys straight
  to our agent — no TouchID at all.
- **Paranoid mode.** `env-gorilla --paranoid` / `otp-gorilla
  --paranoid` grabs the one secret you asked for, uses it, and
  caches nothing — master password every run, nothing left behind.
- **One umbrella CLI (`s3c-gorilla`) runs the whole thing.** Check
  status and health (`status` / `doctor`), see what's loaded
  (`list`), end a session (`wipe` / `lock`), and audit your exposure
  (`scan`) — plaintext `.env` files, unencrypted `~/.ssh/` keys,
  secrets leaked in git or shell history — or pull leftover
  credentials out of the Apple Keychain into the vault (`keychain`).

---


## And what we honestly do **not** protect against

Security-washing is worse than weak security. Here's what this
tool **cannot** save you from:

- **Physical coercion.** Someone holding your hand against the
  sensor gets what TouchID gates. Per-secret scope limits the
  blast radius; it doesn't eliminate it.
- **Same-uid code execution during the ~500ms fan-out window.**
  An attacker already running as your uid with debugger-attach
  entitlements can read the vault during the brief window when
  every secret is simultaneously live in the extraction process's
  memory. Hardened runtime raises the bar; it is not absolute.
- **A compromised host with an unlocked session.** If an attacker
  owns your account and the session is active, they can trigger
  TouchID prompts that you might reflexively approve. We narrow
  the blast radius per-secret, but we cannot stop you from
  approving a malicious prompt.
- **A compromised KeePassXC master password.** This tool is a
  better front door — it is not an entire threat model. Your
  kdbx still needs a strong master password and Argon2 KDF.
- **A privileged same-uid peer while a password-mode session is
  unlocked.** The session agent holds your master password in
  `mlock`'d, AEAD-sealed memory — but the sealing key sits in the
  same process, so an attacker who can read our address space
  (debugger / `task_for_pid`) recovers it. The sealing buys
  no-core-dump / no-swap / no-`strings` hygiene, **not** a
  cryptographic boundary against root or a debugger. Lock the
  session (`s3c-gorilla wipe`) when you step away.
- **Keylogging outside the master-password prompt.** Secure
  keyboard entry shields the `env`/`otp`/`ssh` master-password
  prompt only — it does **not** cover the KeePassXC app's own
  unlock dialog or the SSH agent's GUI prompt. Don't assume
  blanket protection.

---

## At a glance

```bash
# SSH: your key is in the vault. First sign per session prompts
# master pw; every one after is a single TouchID.
ssh example.com

# Run any command with per-project .env secrets injected at runtime.
# Nothing written to disk, nothing exported to your shell.
env-gorilla projectX -- npm run dev

# 2FA codes from the same vault. Copies to clipboard, fires a
# macOS notification. Replaces Google Authenticator on your phone.
otp-gorilla github

# The umbrella CLI — status, health, audits.
s3c-gorilla status              # mode, active sessions, binaries, vault
s3c-gorilla doctor              # health check (deps, codesign, logs)
s3c-gorilla wipe                # drop ALL sessions before handing off the laptop
s3c-gorilla lock                # drop THIS terminal's session
s3c-gorilla list otp            # names only, no secrets
s3c-gorilla uninstall           # remove the suite (kdbx untouched)
s3c-gorilla scan --all          # audit exposure: plaintext .env, ~/.ssh keys,
                                #   git history, shell history (output REDACTED)
s3c-gorilla keychain check      # Apple Keychain creds that belong in the vault
s3c-gorilla keychain fix        # interactively migrate them out of the Keychain
```

Every command has `-h` for full usage; see
[docs/02-DOCUMENTATION.md](docs/02-DOCUMENTATION.md) for the
complete reference.


---


## KeePassXC GUI push (optional, chip mode)

Unlock the KeePassXC **app** and let it push your SSH keys straight into our agent — then
`ssh` works in the terminal *and* GUI apps (SourceTree, VS Code) with **zero Touch ID** for
as long as the database is unlocked. When you lock the DB, KeePassXC tells the agent to drop
the keys and `ssh` falls back to the Touch ID flow.

Setup: KeePassXC → **Settings → SSH Agent → enable**, and make sure your shell exports our
socket (`SSH_AUTH_SOCK` → `~/.s3c-gorilla/agent.sock`, which the installer sets in chip mode).
Mark each SSH entry "Add to agent on database unlock". Ed25519, ECDSA, and RSA keys.

## Going deeper

- [docs/02-DOCUMENTATION.md](docs/02-DOCUMENTATION.md) — full
  command reference, config knobs, file layout, troubleshooting.
- [docs/03-SETUP_KEYBOARD_MAESTRO.md](docs/03-SETUP_KEYBOARD_MAESTRO.md) —
  optional Keyboard Maestro macros for global OTP paste.
- [plans/PLAN.md](plans/PLAN.md) — internal implementation spec,
  threat model detail, 43 resolved security concerns.

---

## Extra

Running `Claude Code`, `OpenCode` LLMs on your local machine is an even crazier thing to do! 
You risk *data loss*, give away your *private data*, you have *zero sandbox* and your *explosion radius* is huge.

That's why I created: 
- ![LLM Docker](https://github.com/RussianRoulette84/llm-docker)

BUT sometimes you are forced to run AI locally to get the latest features that only `Claude.app` can do. Or run a small tasks with OpenCode or VSCodium's Claude Code.

So we are still not 100% AI free locally. That's why I created: 
- ![LLM Snitch](https://github.com/RussianRoulette84/llm-snitch)

Check it out ;)

## Tested on

- **macOS** 15.7.1 (24G231), Apple Silicon (arm64)
- **Swift** 6.2 (swiftlang-6.2.0.19.9, clang-1700.3.19.1)
- **KeePassXC** 2.7.12 (Homebrew, `/opt/homebrew/bin/keepassxc-cli`)
- **terminal-notifier** 2.0.0
- **git** 2.53.0
- **Xcode Command Line Tools** (xcrun 72)

Older macOS (12 Monterey / 13 Ventura / 14 Sonoma) and Intel Macs
should work — the dependencies are all macOS 12+ APIs. If you run
into a version-specific issue, open an issue with the output of
`sw_vers && swift --version && keepassxc-cli --version`.

## License

MIT — Copyright (c) 2026 Slav IT
