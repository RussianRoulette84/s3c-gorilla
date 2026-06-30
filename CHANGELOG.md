# Changelog

## [0.15] - 2026-06-30

### Security
- The master password is scrambled in memory and locked there, so it's never written to disk or caught in a crash dump. We're upfront that this is hardening, not magic: a debugger running as you can still read it.
- Only our own tools can talk to the background agent — a random program running under your account can't.
- Anything left over in `/tmp` from before a reboot is ignored (for both the env/otp and SSH paths), so a reboot really does start you clean.
- Fixed a bug where several commands running at once could corrupt the agent's memory.

### Added
- **Type the master password once per terminal tab.** A small memory-only helper (`s3c-session-agent`) holds it — scrambled and locked in RAM, never on disk — so `env-gorilla`, `otp-gorilla`, and `ssh` stop asking again in that tab. It's wiped when you close the tab, log out, lock the screen, go idle, or reboot. Turn it on with `GORILLA_SESSION_UNLOCK`.
- **One master password per session on Touch ID Macs.** The first tool you run unlocks the whole vault in a single prompt and locks each secret behind the chip, so the rest of the session is just a fingerprint. It runs in the background so your first command doesn't hang, and a wrong password no longer leaves the session half-broken.
- **Faster unlock.** That first unlock now reads the whole database in one shot — one password check — instead of re-opening it once per secret, which is seconds faster on a big vault. Falls back to the slower way if anything goes wrong.
- **RSA SSH keys work everywhere now.** Both password-mode SSH and the KeePassXC app push can sign with RSA keys, not just Ed25519/ECDSA. The installer spots an RSA key and lets you keep it or swap in a fresh, smaller Ed25519 — and tells you which servers to update if you do.
- **`s3c-gorilla` — one command for everything:** `status`, `doctor` (health check), `wipe` (end every session before you hand off the laptop), `lock` (end just this tab), `list`, `setup`, `uninstall`, plus the two below.
- **`s3c-gorilla scan`** — find your exposed secrets: plaintext `.env` files (including `.env.local`/`.env.prod`), unencrypted `~/.ssh` keys, and secrets sitting in your git or shell history. The output is redacted — it tells you *where* and *what kind*, never the secret itself. Skips `node_modules` and examples.
- **`s3c-gorilla keychain`** — find the Apple Keychain logins that belong in your vault (git, SSH, cloud) and move them across (`check` / `import` / `fix`). It only deletes the Keychain copy after confirming the entry is safely in your vault.
- **KeePassXC app push** — unlock the KeePassXC app and it hands your SSH keys to our agent; `ssh` then works in the terminal *and* in GUI apps (SourceTree, VS Code) with no Touch ID until you lock the database again.
- **`--paranoid`** for `env-gorilla`/`otp-gorilla` — grab the one secret you need, use it, and cache nothing.
- **Secure typing** on the master-password prompt — stops other apps from reading your keystrokes (Touch ID mode).
- **2FA codes work offline** after the first use (no repeat trips to KeePassXC), and each one is double-checked against KeePassXC so a wrong code can never be shown.

### Changed
- **The installer is now a set of small, readable steps** run by a tiny launcher; if a step fails it names exactly which one instead of dying silently.
- **Password-mode SSH** is served by the per-tab helper now (no always-on background service), so a single prompt per tab covers env, otp, and ssh together.
- A brand-new shell stays fast — the `ssh` helper only loads its extras the first time you actually run `ssh`.
- The installer now checks that the SSH key in your vault is real and usable and prints its fingerprint, so a dead or missing key is caught during setup instead of failing later with "Permission denied".

### Tests
- macOS + Linux CI; shell test suites for the CLI, scan, keychain, and the one-prompt unlock; a full end-to-end agent round-trip; and pinned 2FA / socket-name test vectors.

### Fixed
- `ssh` could fail right after unlocking because the agent's socket wasn't ready yet — the agent now has its socket live *before* it reports itself unlocked.
- Two rounds of self-review (40 items) — among them: a wrong password no longer marks a session "done", Keychain cleanup can't delete a login that isn't safely in the vault yet, and importing creates its vault folder first.

## [0.14] - 2026-06-28

### Added
- **Dual-mode (Touch ID *and* password) end to end.** Tools auto-detect via the presence of the `touchid-gorilla` binary (`have_chip`). On no-Secure-Enclave machines (e.g. Intel/Hackintosh) `env-gorilla` injects `.env`s straight from the kdbx each run (no chip-wrap), and `otp-gorilla` computes codes via `keepassxc-cli show -t`.
- **Concurrent unlock animation.** `drunken-bishop.sh` gained a background `db_start` / `db_stop` API so the bishop walk runs *during* the Touch ID scan and auto-stops on return, with a 🔒→🔓 unlock flourish. Wired into `env-gorilla` / `otp-gorilla` unwrap paths.

### Changed
- **Installer Touch ID detection** now uses a real LocalAuthentication `canEvaluatePolicy` probe (IOKit `AppleBiometricSensor` alone false-positives on Hackintoshes/VMs). Password-mode machines skip the SSH-agent step and self-heal a stale chip-only `GORILLA_SSH_MODE` in user config.
- **Installer trimmed to 10 steps** — removed the `fs-gorilla` LaunchDaemon step and its orphaned plist; step 4 now installs only the CLIs that exist (`env-gorilla`, `otp-gorilla`, `ssh-gorilla.sh`).
- **End-of-install cheatsheet** rebuilt: left-bar layout (no misaligning right wall), orange tool names, every real command with a realistic example.
- `config.example` ships `GORILLA_SSH_MODE` commented out (set by the installer only in Touch ID mode); fixed the example path (`src/setup/`) and default DB name (`KeePassDB.kdbx`).

### Docs
- **PLAN.md reconciled with v0.14 reality** — retitled to dual-mode (chip + password), added a §0 reconciliation (build-status table, what changed, dual-mode model, a B1–B17 / I-a–I-f follow-up backlog), a §8 password-mode + session-unlock architecture section, hardening H5 (AES-GCM session-agent pw) + H6 (zeroable ssh-agent buffer), the `GORILLA_SESSION_UNLOCK` config knob, and password-mode validation rows. Stale fs-gorilla / `gorilla_tunnel` references swept.
- **PLAN.md restructured** — added a top **Progress tracker** (overall % + P0–P7 phase table with ✅/🟡/⬜ checkmarks); reorganized the implementation checklist **by phase** with a BUILT/PARTIAL/PLANNED status on every row; realigned the "Implementation phases" ordering to P0–P7; **removed the develop-branch / branch-per-phase requirement** (work on the current branch).

### Fixed
- README install one-liner pointed at `master/src/install.sh` (404) — corrected to `master/install.sh`.
- `godfather.sh` never colorized: wrong relative path + an `[[ -x ]]` guard on a `0644` (readable, not executable) `colorize.sh`; now resolves correctly and guards on `[[ -r ]]`.
- Installer success labels and the SSH-bail warning no longer print wrong paths or reference removed tools.

## [0.12] - 2026-06-02

### Added
- **env-gorilla multi-project mode** — `env-gorilla a,b,c -- cmd` fetches every listed `.env` under a single master-password prompt, merges them in caller-supplied order (later projects override earlier ones for duplicate keys), and wraps the merged result as ONE chip-blob keyed by the sorted joined name. One Touch ID unlocks the whole set on subsequent runs. Single-project syntax unchanged.
- `normalize_project_list` and `iter_project_list` helpers — sort+dedupe for the cache key, original-order iteration for kdbx fetches.
- `--clear` now accepts the same comma syntax (`env-gorilla --clear llm-docker,slav-ai` clears the combined blob).

### Changed
- A missing kdbx entry in a multi-project list no longer aborts the whole call — emits a stderr warning and continues with the rest. Single-project mode behavior is unchanged (missing entry still fails).

### Security
- One master-password prompt + one Touch ID per merged-blob set, regardless of how many projects are combined. Same per-decrypt biometry-gated SE semantics as before.

## [0.11] - 2026-04-24

I will write myself thanks.


## [0.10] - 2026-04-19

### Added
- **otp-gorilla** — 2FA/TOTP code viewer and clipboard copy from KeePassXC `2FA/` group

## [0.9] - 2026-04-18

### Added
- **ssh-gorilla** — SSH wrapper with KeePassXC auto-unlock, Touch ID support, root@ prepend for bare hostnames
- **env-gorilla** — .env secret injection from KeePassXC into any process, pure memory, zero files on disk
- **otp-gorilla** — 2FA/TOTP code viewer and clipboard copy from KeePassXC `2FA/` group
- **touchid-gorilla** — Swift binary for Touch ID gated master password retrieval via macOS Keychain
- **install.sh** — auto-detecting installer with Touch ID Mode and No TouchID Mode setups
- VSCodium/VS Code integration via debugpy attach pattern with env-gorilla as pre-launch task
- ASCII art banners with colorize.sh gradient support for all tools
- Platform support table for Touch ID vs manual password workflows
- KeePassXC database structure: `ENV/` group for .env attachments, `2FA/` group for TOTP entries
- SSH config hardening: IdentitiesOnly, HashKnownHosts, ServerAliveInterval
- SSH private key stored as KeePassXC attachment — no `id_rsa` file on disk needed
- Apple Keychain cleanup — removed legacy SSH passphrase entries
- README.md, INSTALL.md, LICENSE (MIT)

### Security
- SSH keys exist in memory only while KeePassXC is unlocked, removed on lock/lid close
- .env secrets injected into process memory only, never written to disk or temp files
- TOTP secrets stored in encrypted .kdbx, replaces phone-based authenticator apps
- Master password stored in macOS Keychain guarded by Touch ID (MacBook only)
- Fallback to manual password entry on machines without Touch ID

### Known limitations
- touchid-gorilla uses macOS Keychain instead of Secure Enclave (Apple blocks Secure Enclave from standalone CLI binaries — needs provisioning profile)
- keepassxc-cli does not support Touch ID — touchid-gorilla bridges this gap
- VSCodium debugger requires debugpy attach pattern since envFile would need a file on disk
- touchid-gorilla binary may need re-signing after macOS updates
