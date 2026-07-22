# v0.17 (2026-07-22)

Macs without Touch ID get the unlock window too.

## SSH
- [NEW] **Unlock window on Macs without Touch ID.** Was a plain text prompt with no choice. Now: just once, until lock, or a timer.
- [CHANGE] Your pick sets how long the helper keeps the password. "Just once" lets go ~30s after the work stops — `ssh` needs a live connection, so it can't be zero. Tune with `GORILLA_UNLOCK_ONCE_TTL`.
- [CHANGE] Falls back to the text prompt when the window isn't installed, you're on the Mac remotely, or `GORILLA_UNLOCK_WINDOW=""`.

### Dev logs
- [CHANGE] `ScopeTimerSwitch` is table-driven now (`ScopeSeg`), so `--password-mode` drops the `app`/`askpw` states cleanly.
- [CHANGE] `s3c-session-agent start <tty> <ppid> [ttlSec]`; `session_unlock` maps the window's `scope=`/`ttl=` to seconds (`0` = config default).
- [CHANGE] Split for the 400-line cap: `s3c-ssh-agent.swift` 1301 → 6 files, `s3c-session-agent.swift` 627 → 3. Pure moves.

# v0.16 (2026-07-22)

One fingerprint per deploy instead of one per signature, a proper unlock window that tells you which app is asking, and your `~/.ssh/config` can now live in the vault.

## SSH
- [NEW] **One fingerprint per deploy.** SSH used to ask for your fingerprint on *every single* signature, so one `fab deploy` or `git fetch` could ask dozens of times. Now the first unlock asks how long the key should stay ready: just this once, for this app only (re-locks when that app or terminal window closes), until the vault closes, or for a set number of minutes.
- [NEW] **A proper unlock window.** A wide dark panel instead of a plain password box: the gorilla floating and glowing on the left, your password shown as circles that spin as you type, the "how long" switch, and an Unlock button. It shows **which app is asking** — name and icon, linked to the gorilla by a padlock that clicks open when you get in. Wrong password shakes the window, flashes red and plays Homer's "D'oh"; get it right after that and you get the "Woo-hoo".
- [NEW] Your own `~/.ssh/config` can live in the vault — `s3c-gorilla ssh-config show | edit | install`. One config that follows you between Macs, edited in place, written to disk with a backup.
- [NEW] A project can keep its SSH config in the vault too. Run the project and the config is handed to whatever you launched — a Docker container just copies it into place. Hostnames and usernames only; the keys stay locked inside.
- [CHANGE] ⚠️ **The `ssh` wrapper no longer rewrites the username.** It used to stick `root@` on any bare hostname, which quietly overrode your own config — `ssh github.com` became `root@github.com` and ignored your `User git`. If you relied on that, add a `Host *` block with `User root` and put it at the **bottom** of the file (SSH keeps the first value it finds, so specific hosts must come first).
- [BUG] **The first connection with an RSA key took a minute or two** — often long enough for the server to give up and hang up on you ("Connection closed by …"). Preparing an RSA key for Apple's crypto needs one particular number and we were working it out the slow way. Minutes became milliseconds.
- [BUG] The agent could get stuck forever if a fingerprint prompt was left unanswered, silently blocking every later connection. It gives up after two minutes now.
- [BUG] Everything cached is wiped the moment the screen locks, you log out, the lid closes, or you reboot — sleep and lid-close were missing before.

## Secrets
- [NEW] **Edit secrets from the command line.** Add, append, remove, or open a project's secrets in your editor without opening the vault app — `env-gorilla set / append / unset / edit`.
- [NEW] **Optional sync with your own Infisical server.** Push secrets up, pull them down, or reconcile both ways, with a prompt whenever the two sides disagree. Each project's server details live inside that project's own secrets, so nothing sensitive sits in a config file. Off by default; the installer asks.
- [NEW] `s3c-gorilla backup` — a dated copy of the vault file before you change anything. Manual, never deletes old copies.
- [NEW] Unlocking from the SSH window also opens your project secrets and 2FA codes, so the terminal stops asking too.

## Setup & Install
- [BUG] **The installer could leave you with a dead SSH agent and say nothing.** It now checks that the background service really registered with macOS and that its socket appeared, and fails loudly with the exact commands to fix it.
- [NEW] A spinner while the installer opens your vault for the SSH test, instead of sitting silent for half a minute.
- [CHANGE] "Stay unlocked for this terminal tab" is now only offered on Macs without Touch ID. On Touch ID Macs it was pointless — you already get one password per boot plus a fingerprint — and turning it on actually made new windows ask again.
- [CHANGE] Re-running the SSH key import no longer piles up a new copy of your `~/.ssh` folder each time.

## Security
- [NEW] The SSH background service **pins its own fingerprint at install time and refuses to start if the file has been swapped or tampered with**.
- [NEW] The decrypted vault contents are held in locked memory and wiped straight after use, and crash dumps are switched off wherever secrets are handled — a crash can't spill them to disk.
- [BUG] Secure typing could get stuck if the password prompt was killed mid-typing, leaving the keyboard dead in other apps until you logged out. It always releases now, with a two-minute safety timeout.
- [CHANGE] Every tool is installed read-only and signed the same way through one shared routine, so the settings can't drift between them.

### Dev logs
- [CHANGE] `s3c-ssh-agent.swift` — scope-gated warm-key cache (`once`/`app`/`session` + TTL cap), owning-app resolved by walking the peer PID up to the first child of launchd, sleep/lid wipe via `NSWorkspace.willSleepNotification`, watchdogs on the unlock window (180s) and `touchid-gorilla unwrap` (120s).
- [NEW] `s3c-unlock-window.swift` + `unlock-theme/controls/vault/guard.swift` — standalone AppKit panel spawned as a subprocess, prints `password / scope= / askpw= / ttl=` on stdout. Palette sampled from `icon.png`.
- [BUG] `ssh-rsa.swift` — `qinv` was computed via Fermat (`q^(p-2) mod p`) on a bignum whose `mod` is bit-serial long division: ~1,500 divisions of 1024-bit numbers per cold unlock. Replaced with binary extended GCD; result verified (`qinv·q mod p == 1`) with the old path as fallback.
- [BUG] `sign()` now accepts an `ssh-*` blob in either PKCS#1 DER (written by `bootstrapBlob`) or raw OpenSSH form (written by the bash fan-out) — the mismatch silently produced no signature for RSA keys.
- [NEW] `s3c-gorilla _fanout` — internal verb, reads the master pw on stdin and calls the existing `fan_out_all`, so a vault opened by the agent's window also warms env/otp.
- [CHANGE] `10-ssh-mode.sh` keeps `launchctl bootstrap`'s stderr and polls for the socket instead of discarding both; `00-common.sh` gained `spin_until` / `run_spinner` (drawn to `/dev/tty`, no-ops without a terminal).
- [CHANGE] Installer renumbered to 11 steps; `swift-targets.sh` gained the `s3c-unlock-window` target (Cocoa + QuartzCore + LocalAuthentication + Carbon).

# v0.15 (2026-06-30)

## Unlock
- [NEW] **Type the master password once per terminal tab.** A small memory-only helper holds it — scrambled and locked in RAM, never on disk — so `env-gorilla`, `otp-gorilla` and `ssh` stop asking again in that tab. Wiped when you close the tab, log out, lock the screen, go idle, or reboot. Turn it on with `GORILLA_SESSION_UNLOCK`.
- [NEW] **One master password per session on Touch ID Macs.** The first tool you run unlocks the whole vault in a single prompt and locks each secret behind the chip, so the rest of the session is just a fingerprint. Runs in the background so your first command doesn't hang, and a wrong password no longer leaves the session half-broken.
- [TWEAK] That first unlock reads the whole database in one shot instead of re-opening it once per secret — seconds faster on a big vault.
- [BUG] `ssh` could fail right after unlocking because the agent's socket wasn't ready yet. The socket is live *before* the agent reports itself unlocked.

## Tools
- [NEW] **`s3c-gorilla` — one command for everything:** `status`, `doctor` (health check), `wipe` (end every session before you hand off the laptop), `lock` (end just this tab), `list`, `setup`, `uninstall`.
- [NEW] **`s3c-gorilla scan`** — find your exposed secrets: plaintext `.env` files, unencrypted `~/.ssh` keys, and secrets sitting in your git or shell history. Output is redacted — it tells you *where* and *what kind*, never the secret itself.
- [NEW] **`s3c-gorilla keychain`** — find the Apple Keychain logins that belong in your vault (git, SSH, cloud) and move them across. It only deletes the Keychain copy after confirming the entry is safely in your vault.
- [NEW] **`--paranoid`** for `env-gorilla` / `otp-gorilla` — grab the one secret you need, use it, cache nothing.
- [NEW] 2FA codes work offline after the first use, and each one is double-checked so a wrong code can never be shown.

## SSH
- [NEW] **RSA keys work everywhere now** — both password-mode SSH and the KeePassXC app push can sign with RSA, not just Ed25519/ECDSA. The installer spots an RSA key and lets you keep it or swap in a fresh, smaller Ed25519 — and tells you which servers to update if you do.
- [NEW] **KeePassXC app push** — unlock the KeePassXC app and it hands your SSH keys to our agent; `ssh` then works in the terminal *and* in GUI apps (SourceTree, VS Code) with no Touch ID until you lock the database again.
- [CHANGE] Password-mode SSH is served by the per-tab helper now (no always-on background service), so a single prompt per tab covers env, otp and ssh together.
- [NEW] The installer checks that the SSH key in your vault is real and usable and prints its fingerprint, so a dead key is caught during setup instead of failing later with "Permission denied".

## Security
- [NEW] The master password is scrambled in memory and locked there, so it's never written to disk or caught in a crash dump. Honest caveat: this is hardening, not magic — a debugger running as you can still read it.
- [NEW] Only our own tools can talk to the background agent — a random program running under your account can't.
- [NEW] Anything left over in `/tmp` from before a reboot is ignored, so a reboot really does start you clean.
- [NEW] Secure typing on the master-password prompt stops other apps reading your keystrokes.
- [BUG] Several commands running at once could corrupt the agent's memory.

## Setup & Install
- [CHANGE] **The installer is now a set of small, readable steps** run by a tiny launcher; if a step fails it names exactly which one instead of dying silently.
- [TWEAK] A brand-new shell stays fast — the `ssh` helper only loads its extras the first time you actually run `ssh`.

### Dev logs
- [NEW] macOS + Linux CI; shell test suites for the CLI, scan, keychain and the one-prompt unlock; a full end-to-end agent round-trip; pinned 2FA / socket-name test vectors.
- [BUG] Two rounds of self-review (40 items) — a wrong password no longer marks a session "done", Keychain cleanup can't delete a login that isn't safely in the vault yet, and importing creates its vault folder first.

# v0.14 (2026-06-28)

## Dual mode
- [NEW] **Works on Macs without Touch ID, end to end.** Tools detect the chip themselves. On a machine with no Secure Enclave (Intel / Hackintosh) secrets are injected straight from the vault on each run, and 2FA codes are computed the same way.
- [NEW] An unlock animation that runs *during* the Touch ID scan and stops on its own when the scan returns.

## Setup & Install
- [CHANGE] **Touch ID detection actually asks macOS now** instead of guessing from hardware, which false-positived on Hackintoshes and VMs. Password-mode machines skip the SSH-agent step and repair a stale setting left behind by an earlier install.
- [CHANGE] Installer trimmed to 10 steps — removed a service that no longer existed and its orphaned config.
- [TWEAK] End-of-install cheatsheet rebuilt: cleaner layout, every real command with a realistic example.
- [BUG] The README's one-line installer pointed at a URL that 404'd.
- [BUG] The install banner never showed its colours — wrong path plus a check for the wrong file permission.

# v0.12 (2026-06-02)

## Secrets
- [NEW] **Several projects in one go** — `env-gorilla a,b,c -- cmd` fetches every listed set of secrets under a single password prompt and merges them (later ones win on duplicates). One fingerprint unlocks the whole set next time.
- [CHANGE] A missing project in the list no longer aborts the whole call — it warns and carries on with the rest.
- [NEW] `env-gorilla --clear a,b` clears the combined set.

# v0.11 (2026-04-24)

Yaro will write this himself.

# v0.10 (2026-04-19)

- [NEW] **otp-gorilla** — 2FA codes from the vault, copied to your clipboard.

# v0.9 (2026-04-18)

First release. Secrets live in KeePassXC; nothing sensitive touches the disk.

## Tools
- [NEW] **ssh-gorilla** — SSH with the key pulled from the vault, unlocked by Touch ID.
- [NEW] **env-gorilla** — project secrets injected straight into a command's memory, never written to disk or exported to your shell.
- [NEW] **otp-gorilla** — 2FA codes from the same vault, replacing an authenticator app on a phone you might lose.
- [NEW] **touchid-gorilla** — the Touch ID gate the others use.
- [NEW] **install.sh** — detects your Mac and sets up either Touch ID mode or password mode.

## Security
- [NEW] SSH keys exist in memory only while the vault is unlocked, and vanish on lock or lid close — no `id_rsa` on disk.
- [NEW] 2FA secrets live in the encrypted vault.
- [NEW] Sensible SSH defaults applied (`IdentitiesOnly`, `HashKnownHosts`, keep-alives).
- [NEW] Leftover Apple Keychain SSH passphrases cleaned up.

## Known limitations
- Touch ID unlocks a key held in the macOS Keychain rather than the Secure Enclave itself — Apple doesn't allow standalone command-line tools to use the Enclave directly.
- The KeePassXC command-line tool has no Touch ID support of its own; ours bridges that gap.
- The Touch ID helper may need re-signing after a macOS update.
