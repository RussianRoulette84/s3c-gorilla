# s3c-gorilla: eager-unified unlock (1 prompt per session, fan-out extraction, per-secret chip-wrap, per-secret Touch ID coercion scope)

> **File location:** this file lives at `./plan/PLAN.md`. Updated live as work progresses.

> **Before you start coding:** read
> [plan/BUILD_STRATEGY.md](BUILD_STRATEGY.md) for the 7-point
> rule set (branch-per-phase, red-first, parallel subagents,
> dogfood early, keep this file alive). Execution happens inside
> `cld --tmux-team` — see §Build strategy + execution model.

## 1. Implementation checklist (Claude updates)

| Done | Success | Name | Description |
|:---:|:---:|---|---|
| [ ] | 0% | Refactor install.sh | Rename old monolith to .bak, new lean orchestrator lives at `src/install.sh` (NOT repo root) + modular `src/setup/*.sh` (≤200 line main); self-bootstrap for curl-bash one-liner (Step 0.e) |
| [ ] | 0% | install.sh: 09-database.sh iCloud scan + size warning | find + picker; `stat -f %z` probe → warn if kdbx > 24 MiB (default 32 MiB budget covers ~24 MiB kdbx — Phase 0 finding) |
| [ ] | 0% | install.sh: 11-pw-prompt.sh | dialog/terminal prompt |
| [ ] | 0% | install.sh: 12-screen-lock.sh | Paranoid Screen Lock toggle → `GORILLA_WIPE_ON_SCREEN_LOCK` |
| [ ] | 0% | install.sh: 13-ssh-mode.sh | chip-wrap/se-born + key import + rotate/upgrade |
| [ ] | 0% | install.sh: 14-launchagent.sh | `sudo install -m 0555 -o root -g wheel` agent binary; plist embeds `SoftResourceLimits`/`HardResourceLimits` MemoryLock = 48 MiB (Concern #23 / N2); record cdhash to `/usr/local/share/s3c-gorilla/agent.cdhash` (Concern #43); bootout+bootstrap |
| [ ] | 0% | install.sh: 15-permissions.sh | guide Notifications + Full Disk Access (Accessibility/Automation no longer needed after Phase 3 drop) |
| [ ] | 0% | install.sh: 16-s3c-gorilla.sh | install `/usr/local/bin/s3c-gorilla` (mode 0555), record install-source path, auto-run `keychain check` at end |
| [ ] | 0% | s3c-gorilla CLI — dispatcher + `status` (default) | Agent state, TTL remaining, cdhash-vs-pin check, config/tool paths, KDBX status — all in one command |
| [ ] | 0% | s3c-gorilla CLI — `setup` | Re-invokes install.sh from recorded install-source; clear error if repo missing |
| [ ] | 0% | s3c-gorilla CLI — `keychain check` | Enumerate Keychain items matching git/ssh/cloud patterns; table output; exit 1 on hits |
| [ ] | 0% | s3c-gorilla CLI — `keychain fix` | Interactive per-item: verify in kdbx → offer delete from Keychain; reuses fan-out session |
| [ ] | 0% | s3c-gorilla CLI — `scan --env` (default) | Filesystem scan for plaintext `.env` under project roots; flag git-committed or un-.gitignored hits |
| [ ] | 0% | s3c-gorilla CLI — `doctor` | Aggregated health: codesign verify, runtime+timestamp flags, dir/file modes, deps, Touch ID hw, kdbx reachable, agent cache health, memlock budget |
| [ ] | 0% | s3c-gorilla CLI — `wipe` | Take bootstrap flock → `touchid-gorilla wrap-clear` → `launchctl kickstart -k` → report count wiped |
| [ ] | 0% | s3c-gorilla CLI — `ssh list` / `env list` / `otp list` | Filename-strip enumeration from `/tmp/s3c-gorilla/<prefix>-*.s3c`; no Touch ID; fall-back hint when no session |
| [ ] | 0% | s3c-gorilla CLI — `scan --ssh` | Audit `~/.ssh/` modes + detect plaintext private keys (OpenSSH v1 + PEM header patterns) + hashed known_hosts check |
| [ ] | 0% | s3c-gorilla CLI — `scan --git` | Search git history in scan-roots for secret-shaped strings (AWS/GitHub/Slack/JWT/PEM); REDACTED output only |
| [ ] | 0% | s3c-gorilla CLI — `scan --shell-history` | Grep zsh/bash/fish history for long assignments + secret-shape patterns; REDACTED output only |
| [ ] | 0% | s3c-gorilla CLI — `scan --all` | Runs --env + --ssh + --git + --shell-history; aggregate exit code |
| [ ] | 0% | s3c-gorilla CLI — `keychain import` | Per-hit interactive: extract from Keychain → pipe into `keepassxc-cli add` (reuses fan-out session); leaves Keychain entry in place |
| [ ] | 0% | Step 0 gate: verify refactor | Run new `src/install.sh` end-to-end on dev Mac, match .bak behaviour |
| [x] | 100% | Phase 0 — keepassxc-cli XML export verification (GATE) | Concern #24: probed stdout/-o, tempfile, attachment encoding, large-attachment behaviour, wrong-credential behaviour on real vault. **Verdict: GREEN** (2026-04-24, keepassxc-cli 2.7.12). Findings folded directly into this plan — budget bumped 10 → 32 MiB, Step 9 size warning added, Compressed="True" confirmed (needs Foundation.Compression), wrong-cred returns exit 1 with zero stdout. Probe 4 (dtruss tempfile trace) deferred to Phase 1 integration. |
| [ ] | 0% | H1 — zero secret buffers in Swift | Inline mmap+mlock+zero on the bulk XML buffer only; per-entry secrets use plain `Data` + `wipe()` helper called via `defer` (Concern #27 90/5 rule) |
| [ ] | 0% | H2 — CommonCrypto primary, BigInt fallback | CCRSACryptorCreateFromData(n,e,p,q) as primary; keep modPow + CRT math as runtime-selected dormant fallback (Concern #22) |
| [ ] | 0% | H3 — hardened runtime + timestamp | Add `--options runtime --timestamp` to all codesign calls |
| [ ] | 0% | H4 — secure input master-pw prompt | `touchid-gorilla master-prompt` with EnableSecureEventInput() |
| [ ] | 0% | Concern #18 — signal handlers around SecureEventInput | Install SIGINT/TERM/SEGV/ABRT/etc, all call DisableSecureEventInput |
| [ ] | 0% | Concern #19 — flock timeout | `-w 30` on bash, fcntl poll loop in Swift; clear error on deadlock |
| [ ] | 0% | Concern #20 — pushed-keys heartbeat + max-age | 10s pgrep timer + 5min per-key age cap (tightened) |
| [ ] | 0% | Concern #23 — RLIMIT_CORE + mlock bulk XML buffer + early-zero | setrlimit to suppress core dumps, mlock the 32 MiB XML buffer only, zero + munlock + munmap before per-entry wrap loop; add honest threat-model paragraph |
| [ ] | 0% | Concern #25 — only fan-out mutates /tmp/s3c-gorilla/ | tools never wipe/recover; tool-side "sentinel absent" path invokes `touchid-gorilla fan-out`; wipe subcommands take bootstrap flock |
| [ ] | 0% | Concern #26 — unconditional RunAtLoad wipe + tool-side inline mtime-vs-boottime | agent `rm -rf` on login under flock; tools `fstat`+compare to kern.boottime before trusting any blob |
| [ ] | 0% | Concern #27 — 90/5 `Data` + `wipe()` helper | No SecretBuf type; mlock only the XML buffer (see #23); per-entry secrets are plain `Data` + `defer { wipe(&d) }`; no lint, no annotations |
| [ ] | 0% | Concern #28 — idempotent lockfile+dir creation | Agent re-creates dir+lockfile on every wipe; CLI tools ensure path before flock |
| [ ] | 0% | Concern #29 — unwrap retry-via-fanout on race | Classify ENOENT/SecInvalidKey as wipe-under-us; one silent retry before scary error |
| [ ] | 0% | Concern #30 — iCloud evicted kdbx probe | Step 9 xattr+head probe; runtime fan-out surfaces "open KeePassXC in Finder" dialog |
| [ ] | 0% | Concern #31 — full otpauth URI parse | Store full URI in blob; parse digits/period/algorithm/issuer at unwrap time |
| [ ] | 0% | Concern #33 — RSA byte-identical-to-ssh-keygen harness | All three algorithms (ssh-rsa / rsa-sha2-256 / rsa-sha2-512) byte-match before H2 ships |
| [ ] | 0% | Concern #34 — step-file failure-propagation convention | Every step file ends with `true`; orchestrator wraps `source` with explicit error |
| [ ] | 0% | Concern #35 — numeric glob sort + two-digit pad lint | `sort -V` in orchestrator; lint rejects mis-padded filenames |
| [ ] | 0% | Concern #36 — terminal-notifier version pin + alerter fallback | Version-check at install; auto-swap to alerter if self-test fails |
| [ ] | 0% | Concern #37 — NUL-delimited paths + printf %q config write | `find -print0` / `read -d ''`; %q on GORILLA_DB write |
| [ ] | 0% | Concern #39 — one-line agent-health warning per tool call | `launchctl list com.slav-it.s3c-ssh-agent` (stable format, parse PID); stderr warning only, no tool failure |
| [ ] | 0% | Concern #40 — peer-credential whitelist on ADD_IDENTITY | `LOCAL_PEERPID` → `proc_pidpath` → bundle ID; reject non-whitelisted; log PID+path |
| [ ] | 0% | Concern #41 — fan-out progress sentinel | `.fan-out-in-progress` file + waiter-side live progress line instead of silent 120s hang |
| [ ] | 0% | Phase 1 — `touchid-gorilla fan-out` subcommand | Shared bootstrap: flock → master-prompt → extract every SSH/ENV/2FA secret → chip-wrap each → save pubkeys (plain) + keys.json.s3c (chip-wrapped, Concern #42) |
| [ ] | 0% | Concern #42 — chip-wrap keys.json registry | `keys.json.s3c` via SE; agent caches decoded registry in a `Data` + `wipe()`-on-exit; zero on SIGTERM / screen-lock / REMOVE_ALL |
| [ ] | 0% | Concern #43 — binary integrity triple-layer | `sudo install -m 0555 -o root -g wheel` for both binaries; agent + touchid-gorilla call `SecCodeCheckValidity` on startup; install.sh pins cdhash to `/usr/local/share/s3c-gorilla/{agent,touchid-gorilla}.cdhash`, binaries compare at launch |
| [ ] | 0% | Phase 1 — XML bulk export fan-out (§2a) | keepassxc-cli export -f xml + Swift XMLParser two-pass |
| [ ] | 0% | Phase 1 — master-pw probe + integrity checks (§2b) | ls -q pre-loop, XML sanity, per-entry format sniff |
| [ ] | 0% | Phase 1 — session-valid sentinel + rollback (§2c) | .session-valid file + trap + crash-safe tool-side check |
| [ ] | 0% | Phase 1 — per-tool blobs (no master.s3c) | ssh-*, env-*, otp-* blobs in /tmp/s3c-gorilla/, each chip-wrap encrypted |
| [ ] | 0% | Phase 1 — per-blob TTL (7200s) + activity reset | Each blob's mtime touched on unwrap |
| [ ] | 0% | Phase 1 — flock concurrent-create lock | Prevents duplicate master-pw prompts |
| [ ] | 0% | Phase 1 — `--paranoid` flag (env/otp) | Skips chip-wrap cache, extracts one secret, wipes |
| [ ] | 0% | Phase 1 — pw prompt dialog/terminal | `GORILLA_MASTER_PW_PROMPT` + `--pw-dialog` / `--pw-terminal` flags |
| [ ] | 0% | Phase 1 — logout SIGTERM wipe | Agent SIGTERM handler runs wrap-clear |
| [ ] | 0% | Phase 1 — screen-lock wipe (`GORILLA_WIPE_ON_SCREEN_LOCK` honored) | Agent subscribes to com.apple.screenIsLocked; wipes only when config=1 |
| [ ] | 0% | Phase 2 — ADD_IDENTITY handler | Agent accepts KeePassXC SSH-Agent push |
| [ ] | 0% | Phase 2 — REMOVE_IDENTITY + REMOVE_ALL | Cache eviction on KeePassXC lock |

## 2. User TODO / Verify

Short checklist — detailed steps below in section 3.

| Done | Name |
|:---:|---|
| [ ] | Run `src/install.sh` once after refactor (before any feature work) |
| [ ] | During install: grant Notifications permission |
| [ ] | Pick master-pw prompt style (dialog or terminal) |
| [ ] | Pick Paranoid Screen Lock (A wipe on lock / B keep across locks) |
| [ ] | Pick SSH mode (chip-wrap or se-born) |
| [ ] | (If SE-born) `ssh-copy-id` new public key to each server |
| [ ] | (If RSA + chose upgrade) `ssh-copy-id` new Ed25519 public key to each server |
| [ ] | Test `ssh somehost` from terminal |
| [ ] | Test `env-gorilla project -- cmd` from terminal |
| [ ] | Test `otp-gorilla <service>` from terminal |
| [ ] | Verify GUI tool (SourceTree / VSCode) can use ssh |
| [ ] | Reboot → first ssh asks master pw again |
| [ ] | Lock screen → first ssh after unlock asks master pw (only if Paranoid Screen Lock=A) |
| [ ] | Idle for 2+ hours → first tool asks master pw |
| [ ] | (Optional) Test `--paranoid` flag on env-gorilla |
| [ ] | (Optional) Delete `~/.ssh/id_rsa` plaintext after backup |
| [ ] | (Optional) Delete `install.sh.bak` after confident |
| [ ] | (Optional) Delete `~/.ssh.bak-<ts>/` backup after confident |

## 3. User TODO / Verify — detailed steps

### Run `src/install.sh` once after refactor
After Claude finishes the install.sh refactor phase, run the new
installer end-to-end. Purpose: catch regressions before feature work
starts. You should see the same 14-step flow as before (plus the
two new prompts: pw-prompt style, Paranoid Screen Lock).

### Grant macOS permissions at install time
During `15-permissions.sh`, the installer triggers each permission
prompt one by one:
- **Notifications** — macOS pops a prompt asking to allow
  `terminal-notifier`. Click **Allow**.

Each is one-time. Revoking later only degrades optional features
(see post-install cheatsheet).

### Pick master-pw prompt style
- **Dialog (Recommended)** — macOS native password window with
  secure keyboard input.
- **Terminal** — `read -s` in your shell. Simpler but vulnerable
  to user-level keyloggers.

### Pick Paranoid Screen Lock
- **A — Wipe on every screen lock (Recommended)** — every
  Cmd-Ctrl-Q or screensaver event wipes cached secrets; next tool
  call re-prompts master pw.
- **B — Keep sessions across locks** — session only ends on
  logout, reboot, 7200s idle, or explicit wipe. More convenient
  for frequent lockers.

### Pick SSH mode
- **chip-wrap (1, default)** — keeps your existing SSH key.
  Imports it into kdbx, chip-wraps via SE. Zero server changes.
- **se-born (2)** — chip generates a brand-new ECDSA-P256 key.
  Non-exfiltrable. Requires updating `authorized_keys` on every
  server.

### Push new SSH public key (only if SE-born or RSA upgrade)
Installer prints your new public key at the end of Step 13.
Example:
```
ssh-copy-id -i ~/.ssh/id_s3c-gorilla.pub user@yourhost
```
Repeat for every server. Hit Enter in the installer when done.

### Test all three tools
From a fresh terminal after install completes:
```
ssh somehost         # should prompt master pw (first time), then Touch ID
env-gorilla proj -- env | head    # should inject env from kdbx
otp-gorilla atlas    # should show and copy TOTP code with notification
```

### GUI tool test
Open SourceTree (or VSCode) and trigger an ssh action (clone, pull,
push). Should work without prompting you to type anything in the
terminal — goes through our agent.

### Reboot / lock / idle tests
Each is a "session gate" check:
- **Reboot** → master pw prompt on first tool call.
- **Screen lock (Ctrl-Cmd-Q), unlock** → master pw prompt on next
  tool call (only if you picked Paranoid Screen Lock mode A).
- **2+ hours idle** (no tool usage, KeePassXC GUI closed or
  locked) → master pw prompt on next tool call.

### Optional cleanups
- `~/.ssh/id_rsa` plaintext — installer offers to delete during
  Step 13. Confirm after first successful ssh.
- `install.sh.bak` — remove once confident the refactored
  installer is stable.
- `~/.ssh.bak-<ts>/` — migration backup from Step 13. Delete
  once you've verified kdbx has all your keys.

## 4. Validation checks (Claude's security QA — must pass before "done")

| Done | Name |
|:---:|---|
| [ ] | `/tmp/s3c-gorilla/` directory is mode 0700 (`stat -f '%Sp'` → `drwx------`) |
| [ ] | Every `.s3c` file in `/tmp/s3c-gorilla/` is mode 0600 (`-rw-------`) |
| [ ] | `~/.s3c-gorilla/` directory is mode 0700 |
| [ ] | `~/.s3c-gorilla/agent.sock` is mode 0600 (chmod'd after `bind()`) |
| [ ] | `~/.s3c-gorilla/keys.json.s3c` is mode 0600 AND chip-wrapped (`file` reports "data" not "JSON text"; `grep -l '"keyType"' ~/.s3c-gorilla/*.s3c` empty) (Concern #42) |
| [ ] | `touchid-gorilla unwrap keys.json` triggers a Touch ID prompt and emits JSON on stdout (Concern #42) |
| [ ] | Agent caches the decoded registry in a `Data` for process lifetime; `wipe(&registry)` called on SIGTERM / screen-lock wipe / REMOVE_ALL (Concern #42) |
| [ ] | `stat -f '%Sp %Su %Sg' /usr/local/bin/s3c-ssh-agent` → `-r-xr-xr-x root wheel`; same for `/usr/local/bin/touchid-gorilla` (Concern #43 Layer 1) |
| [ ] | Replace agent binary with an unsigned substitute (as root) → next `launchctl kickstart` fails; agent logs "codesign check failed" on stderr (Concern #43 Layer 2) |
| [ ] | Replace agent binary with a different validly-signed binary (same Developer ID, different content) without refreshing `agent.cdhash` → agent logs "cdhash mismatch vs pinned" and exits 99 (Concern #43 Layer 3) |
| [ ] | Delete `/usr/local/share/s3c-gorilla/agent.cdhash` → agent refuses to start on next launch with a clear "pin file missing" error (Concern #43 Layer 3, fail-closed) |
| [ ] | Re-install (`src/install.sh` re-run) rewrites `agent.cdhash` before `launchctl bootstrap` so the new binary boots cleanly (Concern #43 rotation) |
| [ ] | No `master.s3c` exists anywhere (`find ~ /tmp -name 'master.s3c' 2>/dev/null` empty) |
| [ ] | Every `.s3c` in `/tmp/s3c-gorilla/` content is SE-encrypted (non-plaintext on hexdump) |
| [ ] | Any blob decrypt requires Touch ID (e.g. `touchid-gorilla unwrap ssh-id_rsa` triggers prompt) |
| [ ] | Reboot → `/tmp/s3c-gorilla/` empty by the time first tool runs (agent wiped it at login) |
| [ ] | Logout → `/tmp/s3c-gorilla/` empty post logout/login (SIGTERM handler ran) |
| [ ] | `GORILLA_WIPE_ON_SCREEN_LOCK=1` (default): lock/unlock cycle → `/tmp/s3c-gorilla/` empty |
| [ ] | `GORILLA_WIPE_ON_SCREEN_LOCK=0`: lock/unlock cycle → blobs survive, next tool only needs Touch ID |
| [ ] | Bulk XML export path: fan-out of 75 entries completes under 5s |
| [ ] | Wrong master pw → `keepassxc-cli ls` probe fails → 0 `.s3c` files written; clear error |
| [ ] | Mid-fan-out crash → next tool sees missing `.session-valid`, invokes `touchid-gorilla fan-out`, which wipes + re-fans under flock (tool itself never wipes — Concern #25) |
| [ ] | `.session-valid` removed on screen-lock wipe / logout / wrap-clear; all three acquire bootstrap flock before wiping (Concern #25) |
| [ ] | Concurrent tools A+B during mid-fan-out crash state: A's fan-out holds flock, B blocks on flock, no tool-side wipe occurs → consistent final state (Concern #25) |
| [ ] | CommonCrypto dlopen guard: runtime-detect missing symbol → fall back to BigInt path; binary doesn't crash |
| [ ] | `stat -f '%m' <any blob>` after `unwrap <name>` equals `now` (±1s); unchanged after `wrap-list` or other read-only subcommands |
| [ ] | Touch ID re-enrolled → old blobs fail decrypt cleanly with "re-seed" notice, not a crash |
| [ ] | `codesign -d --verbose=4 /usr/local/bin/touchid-gorilla` shows `CodeDirectory ... flags=0x10000(runtime)` |
| [ ] | `codesign -d --verbose=4 /usr/local/bin/s3c-ssh-agent` shows `runtime` flag |
| [ ] | `codesign -d --verbose=4 <binary>` shows `Timestamp=` line (not "none") |
| [ ] | Swift source grep shows no `var pw: String` holding secret; `Data` allowed with `defer`-zero discipline (Concern #27 downgraded) |
| [ ] | Swift source grep shows `memset` → `munlock` → `munmap` on the bulk XML buffer's `defer` path; `wipe(&Data)` helper called on every per-entry secret at end-of-scope (Concern #23/#27) |
| [ ] | `grep -r 'CCRSACryptorCreateFromData' src/` returns ≥ 1 match (primary RSA path uses CommonCrypto) |
| [ ] | BigInt / `modPow` code still present but **marked as fallback** with a runtime selection flag (Concern #22); primary path exercised by default |
| [ ] | `flock` acquisition has a 30s timeout; deadlock case prints a clear "bootstrap lock stuck" error (Concern #19) |
| [ ] | Signal handlers for SIGINT / SIGTERM / SIGSEGV / SIGBUS / SIGABRT / SIGPIPE installed in `master-prompt` path; all call `DisableSecureEventInput()` before exit (Concern #18) |
| [ ] | `EnableSecureEventInput()` window is narrow — wraps only the `read()` call, not the whole binary lifetime |
| [ ] | Agent runs a **10s** timer that calls `pgrep -x KeePassXC`; pushed-keys cache cleared if KeePassXC not running (Concern #20) |
| [ ] | Pushed keys older than **5 min** without a fresh ADD_IDENTITY are dropped on the next tick (Concern #20) |
| [ ] | `getrlimit(RLIMIT_CORE)` returns `{0, 0}` on `touchid-gorilla fan-out`, `s3c-ssh-agent`, `env-gorilla`, `otp-gorilla` (Concern #23) |
| [ ] | Simulated `kill -SEGV <pid>` during fan-out produces no `/cores/core.<pid>` file (Concern #23) |
| [ ] | `grep -rn 'mlock(' src/` finds the single bulk-XML-buffer call site in touchid-gorilla fan-out; `grep -rn 'wipe(' src/` finds the helper + its callers (Concern #23/#27) |
| [ ] | Fan-out refuses to start if `RLIMIT_MEMLOCK` current < 32 MiB; over-budget XML stream fails closed with a clear error (Concern #23) |
| [ ] | Synthetic 33 MiB XML export → fan-out aborts with "vault exceeds 32 MiB mlock budget" (Concern #23) |
| [ ] | `09-database.sh` on a > 24 MiB kdbx prints a budget warning naming `GORILLA_MLOCK_BUDGET` + `GORILLA_AGENT_MEMLOCK_BYTES` knobs; ≤ 24 MiB kdbx prints nothing (Phase 0 finding) |
| [ ] | Fresh install on a Mac with `launchctl limit memlock` set low (e.g. 4 MiB) → agent plist `SoftResourceLimits`/`HardResourceLimits` override restores 48 MiB; fan-out succeeds (Concern #23 / N2) |
| [ ] | Tool-side precheck error prints a concrete remedy (`launchctl limit memlock 50331648 ...` + `ulimit -l 49152`), not just "refusing fan-out" (Concern #23 / N2) |
| [ ] | Bulk XML buffer is pre-allocated at 32 MiB via inline `mmap`+`mlock` (no realloc); oversized input → clean abort on first chunk past budget, zero partial writes to disk (Concern #23 / N3) |
| [ ] | Instrumented log line confirms bulk XML buffer is zeroed + `munlock`-ed + `munmap`-ed before the per-entry chip-wrap loop starts (Concern #23) |
| [ ] | `99-done.sh` post-install cheatsheet includes the "~100-500ms all-secrets-in-memory window" threat-model paragraph verbatim (Concern #23) |
| [ ] | During terminal master-pw prompt, the yellow padlock appears in macOS menu bar (Secure Event Input) |
| [ ] | `ssh-add -L` against our socket lists registered keys + KeePassXC-pushed keys (if GUI unlocked) |
| [ ] | `ssh foo` with KeePassXC GUI locked → Touch ID fires every sign |
| [ ] | `ssh foo` with KeePassXC GUI unlocked + SSH Agent enabled → zero prompts |
| [ ] | KeePassXC GUI locks → pushed keys vanish from `ssh-add -L` |
| [ ] | `env-gorilla --paranoid proj` → master-pw prompt even with env-proj.s3c present, and does NOT write/touch any blob |
| [ ] | `env-gorilla --pw-terminal proj` uses terminal read; `--pw-dialog` uses osascript |
| [ ] | Stale mtime (touched to `now - 7300s`) on any blob → next tool invocation invokes `touchid-gorilla fan-out`, which wipes + re-fans under flock (Concern #25 — tools never wipe directly) |
| [ ] | First tool invocation after reboot fans out ALL kdbx secrets at once (ENV/*, SSH/*, 2FA/*); count of blobs matches count of kdbx entries |
| [ ] | `src/install.sh` final line count ≤ 200 |
| [ ] | Curl-bash one-liner clones to `~/.local/share/s3c-gorilla/repo` on first run, `git pull --ff-only` on subsequent runs, then re-execs the local copy (Step 0.e) |
| [ ] | `src/install.sh` invoked from a local clone (i.e. `$SCRIPT_DIR/setup/` exists) skips the bootstrap branch and runs the orchestrator directly |
| [ ] | Every file under `src/setup/` ≤ 250 lines (`wc -l`) |
| [ ] | `git diff README.md` returns empty (untouched) |
| [ ] | CHANGELOG has ≤ 5 new bullet lines (no bloat) |
| [ ] | Phase 0 probe: chosen osascript command returns `true`/`false` correctly for KeePassXC locked vs unlocked |
| [x] | Phase 0 complete (2026-04-24, kxc-cli 2.7.12): verdict GREEN, findings folded into this plan directly; no separate verdict file (trashed as bloat) |
| [ ] | Phase 0: if GREEN — `dtruss -t open keepassxc-cli export ...` shows no tempfile writes to disk; stdout (or `/dev/stdout`) carries the full XML |
| [ ] | Phase 0: if RED — Phase 1 code uses parallel-workers path (§2a step 2) as primary; bulk-XML code is absent or gated off |
| [ ] | Reboot race: simulated "tool invoked 200ms after login, before agent's RunAtLoad ran" → tool's inline `fstat` mtime check vs `kern.boottime` detects pre-boot blob → re-fan-out fires (Concern #26) |
| [ ] | Agent `RunAtLoad` wipe takes bootstrap flock before `rm -rf` (Concern #25+#26) |
| [ ] | Hibernate + clock-touch simulation: blob `mtime > kern.boottime` despite pre-boot origin → agent's unconditional wipe covers it; tool check falls through to fan-out harmlessly (Concern #26) |
| [ ] | Bulk XML buffer: inline `mmap`+`mlock`+zero-on-release; per-entry secrets: plain `Data` + `defer { wipe(&d) }`; no SecretBuf type, no `// SECRET-NECROPSY` annotations, no lint (Concern #27 90/5) |
| [ ] | `rm -rf /tmp/s3c-gorilla/` then run two tools in parallel → both succeed, neither deadlocks, dir ends at mode 0700 with `.bootstrap.lock` present (Concern #28) |
| [ ] | Synthetic race: tool A sleeps 100ms mid-unwrap while tool B triggers screen-lock wipe → A's wrapper performs one transparent retry and succeeds; stderr clean (Concern #29) |
| [ ] | Evicted kdbx (xattr `com.apple.cloud.evict` set) is skipped by Step 9 picker and surfaces a "open KeePassXC in Finder" prompt; runtime fan-out on same path does the same via osascript dialog (Concern #30) |
| [ ] | TOTP with `digits=8`, `period=60`, `algorithm=SHA256`, and `algorithm=SHA512` all produce codes byte-identical to `oathtool` for fixed test vectors (Concern #31) |
| [ ] | CommonCrypto RSA signatures byte-identical to `ssh-keygen -Y sign` output for all three algorithms (ssh-rsa, rsa-sha2-256, rsa-sha2-512) on a fixed RSA test key (Concern #33) |
| [ ] | Live ssh into a test `sshd` negotiating each of the three algorithms succeeds; `sshd -d` logs confirm algorithm selection (Concern #33) |
| [ ] | `./scripts/lint.sh` rejects step files that don't end with `true` or `:` (Concern #34) |
| [ ] | `./scripts/lint.sh` rejects `src/setup/` filenames without a two-digit zero-padded prefix; orchestrator uses `sort -V` explicitly (Concern #35) |
| [ ] | `terminal-notifier -h` version check in `01-keepassxc.sh` refuses to proceed below the pinned minimum; self-test during `15-permissions.sh` falls back to `alerter` on failure (Concern #36) |
| [ ] | Kdbx named `O'Brien's Test Vault.kdbx` in a path containing spaces + apostrophes is scanned, selected in the picker, written to config via `printf %q`, and opened by `touchid-gorilla fan-out` without quoting errors (Concern #37) |
| [ ] | `launchctl bootout gui/$UID/com.slav-it.s3c-ssh-agent`; next `env-gorilla proj -- env` prints a one-line warning on stderr naming the missing agent and the kickstart command; tool still succeeds (Concern #39) |
| [ ] | `s3c-gorilla` (no args) = `s3c-gorilla status`; shows agent state, TTL remaining, cdhash match/mismatch, config paths, KDBX status; exits 0 clean / 1 on any mismatch |
| [ ] | `s3c-gorilla setup` re-runs the installer from the recorded `/usr/local/share/s3c-gorilla/install-source` path; missing repo → clear error |
| [ ] | `s3c-gorilla keychain check` on a Mac with git creds in Keychain → flags the github.com / gitlab.com / ssh-passphrase / cloud-provider entries; exit 1; no secret values printed |
| [ ] | `s3c-gorilla keychain fix` only removes a Keychain item AFTER verifying it exists in kdbx (mocked kdbx lookup) and user confirms per-item y/N |
| [ ] | `s3c-gorilla keychain check` runs automatically at the end of `install.sh` on first install |
| [ ] | `s3c-gorilla scan` in a fixture tree with one `.env` in a git repo (not gitignored) + one `.env` outside any repo → both reported; first flagged red (git-visible), second yellow (no repo context) |
| [ ] | `src/s3c-gorilla` ≤ 250 lines; installed at `/usr/local/bin/s3c-gorilla` mode 0555 root-owned (Concern #43 consistency) |
| [ ] | `s3c-gorilla doctor` exits 0 on a freshly-installed clean Mac; reports pass for every probe (binary codesign, runtime flag, timestamp, dir/file modes, deps, Touch ID hw, kdbx reachable, memlock budget) |
| [ ] | `s3c-gorilla doctor` after `chmod 0644 /tmp/s3c-gorilla/ssh-test.s3c` reports FAIL on "blob modes 0600"; fixing the mode → doctor passes |
| [ ] | `s3c-gorilla wipe` on an active session → `/tmp/s3c-gorilla/` empty, agent process respawns (new PID), `ssh-add -L` shows no pushed keys |
| [ ] | `s3c-gorilla ssh list` after a fresh fan-out → prints one name per `ssh-*.s3c` blob, no values, no Touch ID prompt |
| [ ] | `s3c-gorilla env list` / `otp list` same behaviour for their prefixes |
| [ ] | `s3c-gorilla {ssh,env,otp} list` with no `.session-valid` → prints the "no active session" hint, exits 0 |
| [ ] | `s3c-gorilla scan --ssh` on a fixture `~/.ssh/` with one plaintext RSA key (no passphrase) + one 0644-mode key → both flagged red; encrypted 0600 key is green |
| [ ] | `s3c-gorilla scan --git` on a repo with a committed private-key PEM → hit reported; output line contains `[REDACTED` and NEVER the actual matched bytes (grep output for the key fingerprint returns nothing) |
| [ ] | `s3c-gorilla scan --shell-history` on a fixture `~/.zsh_history` containing `export AWS_SECRET_ACCESS_KEY=AKIA...` → hit reported, redacted; `grep AKIA` on the tool's stdout returns empty |
| [ ] | `s3c-gorilla scan --all` runs all four scans, non-zero exit if any subscan finds hits |
| [ ] | `s3c-gorilla keychain import` on a fixture Keychain item → creates an entry in the kdbx via `keepassxc-cli add`; Keychain entry still present (import is non-destructive) |
| [ ] | `s3c-gorilla keychain fix` after `keychain import` → finds the same item, verifies it's now in kdbx, prompts y/N for Keychain delete; user declining leaves both intact |
| [ ] | ADD_IDENTITY from a non-whitelisted binary (e.g. `nc -U agent.sock`) is rejected with `SSH_AGENT_FAILURE`; log line names PID + path + reason (Concern #40) |
| [ ] | ADD_IDENTITY from KeePassXC (bundle ID `org.keepassxc.keepassxc`) is accepted; key appears in `ssh-add -L` (Concern #40) |
| [ ] | Fan-out that pauses at 42/75 → waiting `ssh` shows `waiting for initial secret extraction (42/75, otp-GitHub)…` on stderr rewritten with `\r` (Concern #41) |
| [ ] | Fan-out sentinel stale (`started > 120s ago`) OR holder PID dead (`kill -0` returns ESRCH) → waiter surfaces the dead-holder error from Concern #19 instead of displaying progress (Concern #41) |
| [ ] | Signal-handler SIGALRM backstop: `kill -SEGV` the master-prompt process mid-`read()` → handler fires, `DisableSecureEventInput` completes OR SIGALRM force-exits within 1s (Concern #18) |
| [ ] | Agent's ADD_IDENTITY parses KeePassXC's test-key push without error; rejects malformed blobs with log line |
| [ ] | First ssh → master pw (fan-out), env-gorilla / otp-gorilla right after → Touch ID only, no re-prompt (single eager-unified flow) |
| [ ] | `15-permissions.sh` triggers the terminal-notifier prompt on a clean-permissions Mac (Accessibility/Automation no longer requested after Phase 3 drop) |
| [ ] | `touchid-gorilla fan-out` works standalone: 1 Touch ID + master-pw → blobs appear for every kdbx entry under SSH/, ENV/, 2FA/ |
| [ ] | `touchid-gorilla fan-out` under concurrency (2 tools race) prompts master pw exactly ONCE (flock works) |

---

## 5. Plan details

## Context

User wanted one master-password prompt per session but also
compartmentalized coercion scope. Resolution: **eager-unified design**
— type master pw once, we fan-out-extract every secret in the vault
immediately, chip-wrap each into its own biometry-gated `/tmp` blob,
then wipe master pw from memory. Each subsequent tool call Touch-IDs
exactly one secret's blob.

Result:
- **One master-pw prompt per session** (boot / logout / screen-lock /
  7200s idle). Same UX as old Mode A proposal.
- **Master password is never stored** on disk or in any persistent
  in-memory cache.
- **Coerced fingerprint → one secret exposed**, not the vault. Same
  coercion scope as old Mode B proposal.
- No `master.s3c`. No single-coercion-point. Strictly better than
  the earlier A/B design — so old Mode B is gone.

Opt-outs and extras:
- `--paranoid` flag on individual tool calls (env-gorilla, otp-gorilla):
  skips the chip-wrap cache, prompts master pw for that one
  invocation, extracts its one secret, discards everything. Per-call
  escape hatch.
- **KeePassXC GUI SSH-Agent integration**: when the GUI is unlocked
  and its built-in SSH Agent feature is on, KeePassXC **pushes** SSH
  keys into our agent via `SSH_AGENTC_ADD_IDENTITY`. Those pushed
  keys bypass Touch ID entirely (user already authenticated via
  GUI unlock). No browser-integration, no NaCl.
- **KeePassXC unlock → timer refresh**: when the GUI is unlocked,
  each tool invocation touches all per-tool blob mtimes, resetting
  the 7200s TTL. Per-unwrap Touch ID gate preserved.

User has explicitly accepted that eager extraction means:
- New secrets added to kdbx mid-session aren't visible until next
  session start (or explicit `touchid-gorilla wrap-clear`).
- Fan-out extraction takes a few seconds up front on first tool
  call of a session.

### Threat-model note — the fan-out window

For ~100-500ms every session start, every vault secret is
simultaneously live in the `touchid-gorilla fan-out` process's
locked memory. We harden this window (Concern #23):

- **`RLIMIT_CORE = 0`** — no core dump can leak heap contents on
  crash / unhandled signal.
- **`mlock()` on the bulk XML buffer only** — pages are pinned in
  physical memory, never paged to swap. This is the single
  longest-lived aggregate-plaintext region (~500ms during parse)
  and the one worth defending (Concern #27 90/5 rule).
- **Per-entry secrets use plain `Data` + `wipe()` helper** — not
  mlocked, zeroed immediately on end-of-scope via `defer`.
- **Bulk XML buffer is zeroed and released** before the per-entry
  chip-wrap loop — narrows the "all plaintext" window to parse
  time only.

After fan-out returns, only per-secret `.s3c` files remain on
disk; each requires Touch ID to decrypt. The master password
itself is never stored on disk and is zeroed from memory before
fan-out returns.

**What this does NOT protect against:**

- An attacker with code execution as your uid during that ~500ms
  window and the right entitlements to attach a debugger or read
  process memory sees every secret. Hardened runtime (H3) raises
  the bar but isn't absolute.
- **Agent socket admission (S3).** `s3c-ssh-agent` accepts
  `SSH_AGENTC_ADD_IDENTITY` from any process that can `connect()`
  to `~/.s3c-gorilla/agent.sock`. The baseline is standard Unix
  uid isolation — the socket is mode 0600, owned by your user —
  **not** cryptographic peer authentication. This is the same
  baseline as every mainstream ssh-agent implementation
  (OpenSSH's `ssh-agent`, 1Password's agent, etc.). **But**
  unlike vanilla OpenSSH, our agent briefly holds a fan-out's
  worth of secrets and can sign without Touch ID for pushed keys
  — so a rogue same-uid process has more to gain here than it
  does from plain `ssh-agent`. We raise the bar above "anyone who
  can `connect()`" via **peer-credential admission control on
  ADD_IDENTITY** (Concern #40): the agent reads the connecting
  process's PID via `LOCAL_PEERPID` (`getsockopt(SOL_LOCAL,
  LOCAL_PEERPID)`), resolves it to a bundle identifier via
  `proc_pidpath` + `CFBundle`, and only accepts
  `SSH_AGENTC_ADD_IDENTITY` from a whitelist (default:
  `org.keepassxc.keepassxc`). All other pushes are rejected with
  `SSH_AGENT_FAILURE` and logged with the PID + path. This is
  not bulletproof — a malicious binary could bundle-ID-spoof if
  it writes its own Info.plist, but it must then live on disk at
  a path you can notice — but it raises the bar substantially
  above the default ssh-agent model.
- **`--paranoid` narrows extraction, not execution (S1).** The
  flag skips the chip-wrap cache for a single invocation, but the
  injected env vars remain readable to any same-uid process via
  `ps eww <pid>` (and similar) for the entire lifetime of the
  child process `env-gorilla` launched. Same caveat applies to
  any secret that reaches a child's argv/environ.

User-facing honesty: "master pw never stored" is true; "all
secrets in memory briefly every session start" is also true;
"same-uid processes can push keys into our agent or read env vars
from child processes" is also true.

## Architecture

### 1. Per-tool blobs at `/tmp/s3c-gorilla/<tool>-<name>.s3c`

There is **no `master.s3c`**. Every secret lives in its own blob:

- `/tmp/s3c-gorilla/ssh-id_rsa.s3c`       — SSH private key
- `/tmp/s3c-gorilla/env-project_x.s3c`    — .env contents
- `/tmp/s3c-gorilla/otp-Atlassian.s3c`    — TOTP secret
- `/tmp/s3c-gorilla/env-project_y.s3c`    — etc.

Each blob is:
- Chip-wrap-encrypted with the SE wrap key (biometry-gated,
  `.biometryCurrentSet`). Touch ID hardware-enforced at decrypt.
- Mode `0600`. Parent dir `/tmp/s3c-gorilla/` mode `0700`.
- Wiped on any of:
  - **Reboot** — two-layered (Concern #26):
    - Agent `RunAtLoad=true` **unconditionally** wipes
      `/tmp/s3c-gorilla/` on login (no mtime logic).
    - Every CLI tool ALSO checks each blob's mtime vs
      `sysctl -n kern.boottime` inline before trusting it; pre-boot
      blobs are treated as absent → re-fan-out. Belt + suspenders:
      tools can't wait for the agent (Dock+Terminal may race
      ahead of LaunchAgent startup).
  - **Logout** — `s3c-ssh-agent` SIGTERM handler runs
    `touchid-gorilla wrap-clear` (wipes every blob).
  - **Screen lock** — **if `GORILLA_WIPE_ON_SCREEN_LOCK=1`**
    (default, "Paranoid Screen Lock"), agent subscribes to
    `com.apple.screenIsLocked` via `NSDistributedNotificationCenter`
    and wipes every `.s3c` on notification. Set `0` to keep
    sessions across screen locks (TTL / logout / reboot still
    trigger wipes).
  - **7200s of inactivity** — on each tool invocation the file
    mtime of any blob it touches is checked; if stale, the blob is
    wiped and the fan-out re-runs.

The master-password prompt re-appears after: cold boot, logoff, screen
lock, or 7200s idle.

### 2. Fan-out extraction (the "eager" part)

Fan-out is a single shared routine implemented as
**`touchid-gorilla fan-out`** (new Swift subcommand). Both the agent
and the bash CLI tools (env-gorilla, otp-gorilla) invoke it as a
subprocess when they need bootstrap. Putting it in the signed Swift
binary means:
- Master pw is typed securely (H4 SecureEventInput) in the one
  process that handles SE.
- Secret bytes zeroed with `Data` + `memset` (H1) before the
  subprocess exits — no bash-level leakage.
- Bash tools see only "fan-out done" / "fan-out failed" exit codes.

**`touchid-gorilla fan-out` behaviour:**
```
acquire /tmp/s3c-gorilla/.bootstrap.lock  (flock)
if any blob exists in /tmp/s3c-gorilla/:
    release lock, exit 0 (someone else already fanned out)
else:
    prompt master pw (via internal master-prompt → SecureEventInput)
    GORILLA_DB comes from ~/.config/s3c-gorilla/config
    enumerate SSH/, ENV/, 2FA/ groups via keepassxc-cli ls
    for each SSH/<name> : attachment-export <key-file> → chip-wrap ssh-<name>.s3c
    for each ENV/<proj> : attachment-export .env → chip-wrap env-<proj>.s3c
    for each 2FA/<svc>  : show -a otp → chip-wrap otp-<svc>.s3c
    also save SSH pubkey halves to ~/.s3c-gorilla/pubkeys/<name>.pub
       (they're public; no encryption needed; used by ssh-agent for
        REQUEST_IDENTITIES)
    also write ~/.s3c-gorilla/keys.json.s3c registry
       (each entry: {name, keyType, mode} — chip-wrapped like
        any other secret; metadata is a map of your infrastructure
        and leaks what's in the vault even though it's not the
        secrets themselves. Concern #42.)
    zero master pw + every extracted secret from memory
    release lock
    exit 0
```

**First invocation per session**: whichever tool runs first (ssh,
env, or otp) invokes `touchid-gorilla fan-out` and blocks until
it completes. Subsequent tools in the same session: fan-out exits
immediately (an `.s3c` already exists), tool proceeds to its own
per-tool unwrap.

### 2a. Fan-out performance (avoiding 30-60s waits on first boot)

**Problem:** a user with 50 ENV projects + 20 2FA entries + 5 SSH
keys has 75 kdbx entries. A naive implementation calls
`keepassxc-cli` 75 times sequentially, each re-opens the kdbx and
re-runs Argon2 (~100-500ms per open). Worst case: 30-60 seconds
on first boot.

**Resolution — layered, in order of preference:**

1. **Bulk XML export** (primary path, sub-second total — **verified
   viable during planning** against real kdbx).
   Use `keepassxc-cli export <db> --format xml`. One kdbx open,
   one Argon2, one XML stream. Parse in Swift via Foundation's
   `XMLParser` in two passes:

   **Pass 1 — harvest attachments.** Walk `<Meta><Binaries>` which
   stores every attachment as `<Binary ID="N" Compressed="True">BASE64</Binary>`.
   Build an in-memory `id → (decompressed bytes)` map. Decompress
   via Foundation `Compression` when `Compressed="True"`.

   **Pass 2 — walk entries.** For each `<Group>/<Entry>`:
   - Group name (`SSH`/`ENV`/`2FA`) classifies.
   - `<String><Key>Title</Key>…</String>` gives the entry name.
   - **SSH / ENV**: `<Binary><Key>filename</Key><Value Ref="N"/></Binary>`
     → look up N in Pass-1 map → raw bytes.
   - **2FA**: `<String><Key>otp</Key><Value>otpauth://...</Value></String>`
     → store the **entire URI** in the blob (Concern #31 — the
     full URI is needed so `otp-gorilla` can honor non-default
     `digits`, `period`, `algorithm`, and `issuer`). URI parsing
     happens at unwrap time, not at fan-out time.

   Chip-wrap each extracted payload into its own `.s3c`.

   All secrets transit the XML buffer briefly — same data that
   would've gone through 75 pipes anyway. The **bulk XML buffer
   only** uses inline `mmap`+`mlock` with explicit zero →
   `munlock` → `munmap` on release (Concern #23). Per-entry
   secrets (one SSH key / one .env / one TOTP seed at a time)
   use plain `Data` with `defer { wipe(&d) }` at end-of-scope
   (Concern #27 90/5 rule). No raw-pointer wrapper type, no
   `// SECRET-NECROPSY` annotations, no lint script.

2. **Parallel `keepassxc-cli` workers (pool of 4-8)** — fallback
   if bulk export insufficient. 75 sequential calls collapse to
   ~10 sequential-equivalent worst case.

3. **Progress indicator always.** `Fan-out: 42/75 (otp-GitHub)` on
   stderr with `\r` rewrites.

4. **flock timeout 120s for fan-out** (not 30s) to tolerate
   legitimate long fan-outs on slow Macs. Paired with a
   progress-sentinel so waiters don't hang silently (Concern
   #41):
   - Fan-out, after acquiring the bootstrap flock, writes
     `/tmp/s3c-gorilla/.fan-out-in-progress` containing:
     ```
     pid=<owner-pid>
     started=<epoch-seconds>
     progress=<done>/<total>
     current=<entry-name>
     ```
     The file is rewritten (atomic `.tmp` → rename) after every
     N chip-wraps (say every 5 entries; cheap).
   - Every CLI tool, BEFORE blocking on `flock -w 120`, `stat`s
     this sentinel. If present and `started` is within the last
     120s:
     ```
     s3c-gorilla: waiting for initial secret extraction (42/75, otp-GitHub)…
     ```
     rewritten on stderr with `\r` every 500ms by re-reading the
     sentinel. Distinguishes "active fan-out by PID X" from
     "dead holder" (stale sentinel → flock will time out
     naturally and we show the dead-holder error from
     Concern #19).
   - Trap (set in fan-out on entry) removes
     `.fan-out-in-progress` on ERR/EXIT so the sentinel never
     outlives the owner. On SIGKILL (no trap), staleness is
     detected by `stat(sentinel).started > 120s ago` OR
     `kill -0 <pid>` returning ESRCH.
   - Replaces the silent 120s hang with a live progress line.
     Implementation detail of `touchid-gorilla fan-out`; no
     changes to the tool-side API.

### 2b. Master password validation + extraction integrity

**Problem:** piping master pw to `keepassxc-cli` via stdin works
today but is fragile. If keepassxc-cli changes stdin semantics,
adds a confirmation prompt, or silently produces stub output,
fan-out wraps **empty blobs** and every tool appears to work
until unwrap-then-use hits nothing. Silent failure = worst kind.

**Mitigations layered:**

1. **Pre-loop password probe.** After typing master pw:
   ```
   echo "$pw" | keepassxc-cli ls "$DB" / -q
   ```
   Non-zero exit → bad pw or bad kdbx. Clear error, zero pw,
   abort before writing any `.s3c`. Bulk-XML path: check
   `export`'s exit status, not just that we got some output.

2. **Bulk XML sanity checks before committing.**
   - `XMLParser` reports no parse error.
   - Root element is `<KeePassFile>`.
   - ≥ 1 `<Entry>` under `<Root>/<Group>` (empty warns, doesn't
     abort).
   - Parsed entry count matches separate `keepassxc-cli ls` count
     under SSH/, ENV/, 2FA/. Mismatch → abort, print diff.

3. **Per-entry format sniff during extraction.**
   - SSH/ENV: bytes > 0; SSH keys must start with `-----BEGIN `
     or `openssh-key-v1\0`.
   - 2FA: otpauth URI parses + `secret=` base32-decodes non-empty.
   - Any failure → abort fan-out (strict). User sees the specific
     entry that failed, can fix kdbx, retry.

**Recovery UX on failure:**
```
fan-out failed: <reason>
No .s3c files were written. Run `touchid-gorilla wrap-clear` if
you see stale blobs and retry your command.
```

### 2c. Session-valid sentinel + crash-safe rollback

**Problem:** atomic per-rename doesn't cover the rename *set*. If
the process dies after renaming 20 of 75 `.s3c.tmp` files, we have
20 `.s3c` + 55 `.s3c.tmp`. Next tool invocation sees "some `.s3c`
exists" → skips fan-out → fails when its specific blob isn't one
of the 20 that got renamed.

**Resolution — session sentinel file + single-writer wipe rule.**

- Fan-out's FINAL step (after every rename) writes
  `/tmp/s3c-gorilla/.session-valid` (zero-byte, presence is the
  signal).
- Every tool checks `.session-valid` before using any `.s3c`.
- **Only `touchid-gorilla fan-out` ever mutates
  `/tmp/s3c-gorilla/` contents.** Tools never wipe, never
  recover, never `wrap-clear` on their own. Prevents the sentinel
  race (Concern #25): if tool B could wipe concurrently with
  tool A's in-progress fan-out, A's sentinel ends up covering a
  partially-wiped dir → state lies.
- Decision tree on tool invocation:
  ```
  if .session-valid present:
      → session complete, proceed to unwrap
  elif .session-valid absent AND any .s3c or .s3c.tmp exists:
      → previous fan-out crashed mid-way
      → DO NOT WIPE. Invoke `touchid-gorilla fan-out`, which
        acquires the bootstrap flock, THEN wipes + re-fans
        under the lock.
  else (clean state):
      → invoke `touchid-gorilla fan-out` (takes flock, fans out).
  ```
- `touchid-gorilla fan-out` flow (single writer, under flock):
  ```
  flock /tmp/s3c-gorilla/.bootstrap.lock -w 120
  # inside lock:
  #   1. rm -rf /tmp/s3c-gorilla/*.s3c /tmp/s3c-gorilla/*.s3c.tmp
  #      /tmp/s3c-gorilla/.session-valid
  #   2. extract all secrets → write .s3c.tmp files
  #   3. rename all to .s3c
  #   4. write .session-valid
  # release lock
  ```
  Even under concurrent tool invocations, the flock serializes
  wipes/writes; late-arrival tools see `.session-valid` after the
  lock releases and skip their own fan-out.
- Fan-out wraps its work in a signal + exit trap:
  ```
  trap '{ rm -f /tmp/s3c-gorilla/*.s3c.tmp /tmp/s3c-gorilla/.session-valid; }' ERR EXIT
  ```
  Even on SIGKILL (no trap runs), the next tool invocation
  re-invokes fan-out, which re-takes the flock and cleans up.
- Screen-lock wipe / logout SIGTERM / `wrap-clear` subcommand all
  also remove `.session-valid` along with the blobs — keeps state
  consistent. These three ARE allowed to wipe outside of
  fan-out's flock because they wipe everything (no partial-state
  risk); but they MUST acquire the same bootstrap flock to
  serialize against an in-progress fan-out.

Atomic per-rename (§2b) still applies; sentinel signals the
rename **set** completed.

### 3. Activity-based TTL reset

Every **successful blob unwrap** updates that blob's mtime via
`utimes()` to "now". Effect: active tool use on any secret keeps
that secret's TTL fresh. Blobs not touched in >7200s become stale
and are wiped on next invocation, triggering a fresh fan-out.

Read-only subcommands (`wrap-list`, `wrap-clear` without unwrap,
`totp-age`, etc.) do NOT touch mtime.

### 4. Tool runtime flow (no Mode A/B — single unified flow)

```
if --paranoid / S3C_PARANOID=1:
    prompt master pw → extract THIS SPECIFIC secret → use directly → zero everything
    do NOT read or write /tmp/s3c-gorilla/
    proceed

elif per-tool blob exists (not stale):
    Touch ID unwrap the blob → use secret → proceed
    touch mtime (resets this blob's timer)

elif per-tool blob exists but stale (>7200s):
    wipe /tmp/s3c-gorilla/*
    fall through to fan-out

else (no blob yet this session — first tool call):
    fan-out extraction (section 2)
    Touch ID unwrap this specific secret → use → proceed
```

### 5. `--paranoid` / `S3C_PARANOID` behaviour

Per-invocation opt-out of the chip-wrap cache:
- Reads no blobs. Writes no blobs. Touches no mtimes.
- Prompts master pw for this one call.
- Extracts just the one secret this call needs.
- Uses it and wipes master pw + secret from memory.
- Fresh master-pw prompt on next paranoid call.

For the SSH agent (daemon, no CLI flag): honours `S3C_PARANOID=1`
env var seen at sign-request time if the caller is a shell child
that set it. Agent reads config on each sign request. If set,
bypass the pushed-keys cache and the per-tool blobs — prompt master
pw, extract the requested SSH key, sign, zero.

### 6. TTL is absolute and user-tunable

No KeePassXC-unlock-based timer refresh. TTL is a single duration
read from `GORILLA_UNLOCK_TTL` in `~/.config/s3c-gorilla/config`
(default 7200 seconds = 2 hours). When any blob's mtime is older
than the TTL, next tool invocation wipes + re-fans-out. Touch ID
is still required for each decrypt.

Originally we planned an AppleScript probe → agent-polled
sentinel → tool-side refresh chain so that keeping KeePassXC
unlocked extended the session indefinitely. That bought one
feature ("session outlives 2h if KeePassXC is open") at the cost
of: Accessibility permission prompt, System Events introspection,
a sentinel file with freshness windowing, clock-jump edge cases,
Phase 0 research for menu-label reliability, and a UNRELIABLE
fallback path. Dropped (Concerns #12 / #21 / #32 / #38 marked
obsolete). Users who want longer sessions set
`GORILLA_UNLOCK_TTL=28800` for 8 hours — one line, zero runtime
complexity.

Phase 3 of the implementation plan is removed. If the timer-
refresh feature turns out to matter in practice, we can ship it
later as an opt-in.

### 7. KeePassXC GUI SSH-Agent integration (SSH only)

KeePassXC has a built-in SSH Agent feature: when the database unlocks,
it pushes marked keys into the ssh-agent pointed to by `SSH_AUTH_SOCK`.
We let it push straight into our agent.

**Mechanics:**
- `install.sh` sets `SSH_AUTH_SOCK` to `$HOME/.s3c-gorilla/agent.sock`
  via `launchctl setenv` (already done) AND in `.zprofile` (already
  done). So KeePassXC — whether launched from Dock, Finder, or a
  shell — inherits this and pushes keys to our agent.
- Our agent adds handlers for three more ssh-agent protocol messages:
  - `SSH_AGENTC_ADD_IDENTITY` (11 → 17) — accept key blob, store in
    agent-process memory.
  - `SSH_AGENTC_REMOVE_IDENTITY` — drop one key (KeePassXC sends this
    when the DB locks or a key is removed).
  - `SSH_AGENTC_REMOVE_ALL_IDENTITIES` — drop all pushed keys (DB
    lock).
- On sign request: check in-memory pushed-keys cache first; if the
  requested pubkey matches, sign from cache **without Touch ID** (the
  user already authenticated by unlocking the GUI). Else fall through
  to the existing chip-wrap / SE-born path (which does use Touch ID).
- In-memory pushed keys are zeroed on SIGTERM and on receive of
  REMOVE-ALL.

**Consequence:** if you unlock KeePassXC GUI, every subsequent ssh
(terminal or SourceTree or VSCode) uses the pushed keys, zero Touch
ID, zero master-pw prompt. When KeePassXC locks, those keys vanish
from memory; next ssh falls through to our Touch ID flow.

Env / otp unchanged — KeePassXC has no equivalent GUI-push for
`.env` contents or TOTP secrets. Those always use the per-tool
chip-wrap blob flow.

## Files

### Modified
- `src/touchid-gorilla.swift`
  - `unwrap` touches the blob's own mtime on success (only the blob
    being unwrapped, no cross-blob mtime updates).
  - `wrap` / `unwrap` / `wrap-list` / `wrap-clear` already present
    from earlier session — unchanged.
  - Add `master-prompt --label <what-for>` (H4 — secure input).
  - Add `fan-out` — shared bootstrap routine (see Architecture §2).
    flock-serialised. Extracts every kdbx secret, chip-wraps each,
    saves SSH pubkeys + chip-wrapped `keys.json.s3c` registry
    (Concern #42).
- `src/s3c-ssh-agent.swift`
  - On first sign request with no matching per-key blob: invoke
    `touchid-gorilla fan-out` as a subprocess, wait for exit, then
    unwrap the specific key for the current sign.
  - Add `SSH_AGENTC_ADD_IDENTITY` / `REMOVE_IDENTITY` /
    `REMOVE_ALL_IDENTITIES` handlers.
  - Maintain in-memory pushed-keys cache
    `[pubKeyBlob: (rawPrivateBytes, keyType)]`.
  - `handleRequestIdentities()` lists on-disk registry keys (from
    fan-out) **plus** pushed keys (pushed keys get a
    `(pushed by KeePassXC)` comment).
  - `handleSignRequest()` checks pushed cache first (sign without
    Touch ID), else per-tool blob (Touch ID unwrap + sign + zero).
  - Honours `S3C_PARANOID` env (re-prompt master pw, extract this
    one key only, sign, zero — no blob writes).
  - SIGTERM + REMOVE_ALL zero the pushed-keys cache and all on-disk
    blobs.
  - Subscribe to `com.apple.screenIsLocked` via
    `NSDistributedNotificationCenter` (macOS). On notification:
    **check `GORILLA_WIPE_ON_SCREEN_LOCK` from config.** If 1
    (default, Paranoid Screen Lock), wipe `/tmp/s3c-gorilla/` +
    `.session-valid` + zero the pushed-keys cache. If 0, ignore
    the event (sessions survive screen locks).
  - `RunAtLoad` handler: **unconditionally** `rm -rf
    /tmp/s3c-gorilla/*` (Concern #26). No mtime logic. Cost is one
    fresh fan-out — which is the intended fresh-session behaviour
    anyway.
- `src/env-gorilla`, `src/otp-gorilla`
  - Add `--paranoid` flag (skip blob cache, single-secret extract,
    discard).
  - Add `--pw-dialog` / `--pw-terminal` flags.
  - Runtime flow: check own per-tool blob → **inline check
    blob-mtime vs `sysctl -n kern.boottime`** → if pre-boot, treat
    blob as absent (Concern #26) → unwrap → use; else trigger
    fan-out (same primitive used by the agent) and retry.
- `src/setup/config.example` (moved out of repo root into `src/setup/` alongside the per-step installers that read it)
  - `GORILLA_UNLOCK_TTL=7200`
  - `GORILLA_MASTER_PW_PROMPT=dialog`
  - `GORILLA_WIPE_ON_SCREEN_LOCK=1` (Paranoid Screen Lock; 0 opts out)

### New files (refactor + features)
- `src/install.sh` — rewritten from scratch as a lean orchestrator (≤200 lines). Lives at `src/install.sh` (NOT repo root) to match the curl-bash one-liner URL (Step 0.e).
- `src/setup/00-common.sh` — shared vars + TUI helpers.
- `src/setup/01-keepassxc.sh` through `99-done.sh` — per-step files (~15 files).
- `src/setup/touchid-codesign-picker.sh`, `touchid-compile-touchid.sh`,
  `touchid-compile-agent.sh` — helpers sourced by `05-touchid.sh`.
- New subcommands in `src/touchid-gorilla.swift`:
  - `master-prompt --label <what-for>` (H4 — secure keyboard input).
  - `fan-out` (shared bootstrap: prompt master pw, extract every kdbx secret, chip-wrap each).
- **`src/s3c-gorilla`** — umbrella CLI that ties the suite together.
  Shell wrapper (plain `bash`), no compile step, `install -m 0555`
  to `/usr/local/bin/s3c-gorilla`. Subcommand surface (§"s3c-gorilla
  CLI" below for details):
  - `s3c-gorilla` (= `status`) — default: show agent state + TTL
    remaining + config paths of env/ssh/otp-gorilla.
  - `s3c-gorilla setup` — re-run `install.sh`.
  - `s3c-gorilla keychain check` — scan macOS Keychain for items
    that should be in the kdbx instead (git creds, SSH passphrases,
    cloud-provider credentials, KeePassXC's own stored items).
  - `s3c-gorilla keychain fix` — runs `check`, verifies each
    discovered item exists in the kdbx before offering removal.
    Post-install run auto-invoked once.
  - `s3c-gorilla scan` — filesystem sweep for plaintext `.env`
    files in common project roots (`~/Projects/`, `~/Code/`, etc).
- No other new standalone binaries. No NaCl library. No SPM.

### Out of scope — do NOT touch
- `README.md` — user maintains this directly. Plan makes no changes
  to it and implementation must leave it untouched.
- `CHANGELOG.md` — only append minimal entries (one line max per real
  user-visible change). No bullet lists of internal helpers or per-file
  refactor notes.
- **`src/touchid-gorilla.entitlements` — `keychain-access-groups`
  string `M6CUAS2AGM.com.slav-it.sec-gorilla` is INTENTIONAL and
  must NOT be renamed.** It is an opaque identifier tied to the
  Apple Developer Team ID + App ID registered with Apple, not the
  user-facing project name. Renaming it to `s3c-gorilla` would
  require: new App ID registration in Apple Developer Console,
  new provisioning profile, and all existing SE wrap keys would
  become undecryptable (different keychain-access-group → different
  keychain scope). Every chip-wrapped blob ever created would
  need to be thrown away and re-seeded. If a future automated
  rename pass flags this, the answer is: leave it alone.

## s3c-gorilla CLI (umbrella tool)

One shell wrapper at `/usr/local/bin/s3c-gorilla` that ties the
suite together. Subcommands dispatch to the existing tools
(`touchid-gorilla`, `env-gorilla`, `otp-gorilla`, `ssh-gorilla.sh`,
`s3c-ssh-agent`) plus its own audit helpers.

### `s3c-gorilla` / `s3c-gorilla status` (default)
Prints:
- Agent state: PID + running/dead (via `launchctl list com.slav-it.s3c-ssh-agent`, Concern #39 pattern).
- Session: TTL remaining (seconds until any `.s3c` blob goes stale), fan-out sentinel present? blob count.
- Binary integrity: cdhash matches pin? (Concern #43 Layer 3 — reads `/usr/local/share/s3c-gorilla/{agent,touchid-gorilla}.cdhash`, runs `codesign -d -v` on the installed binary, compares).
- Config paths: `~/.config/s3c-gorilla/config`, `~/.s3c-gorilla/`, `/tmp/s3c-gorilla/`.
- Tool paths: `env-gorilla`, `otp-gorilla`, `ssh-gorilla.sh`, `touchid-gorilla`, `s3c-ssh-agent`.
- KDBX: path + existence + eviction status (Concern #30 probe).

No secrets printed. Exit 0 on clean, 1 on any failure.

### `s3c-gorilla setup`
Re-invokes `src/install.sh` from the repo the binary was installed
from. Records repo path at install time in
`/usr/local/share/s3c-gorilla/install-source`. If the repo is
missing, prints a clear error + instructs how to re-clone.

### `s3c-gorilla keychain check`
Scans macOS Keychain for items that should live in the kdbx
instead. Uses `security dump-keychain` + `security find-internet-password`
/ `find-generic-password` pattern matching. Target categories:
- **Git credentials** — internet passwords for `github.com`,
  `gitlab.com`, `bitbucket.org`, `codeberg.org`, `gitea.*`, or any
  entry whose service/label contains `git`.
- **SSH passphrases** — items in `com.apple.ssh.passphrases` or
  older `com.openssh.ssh-agent` service. (These sit in the
  Keychain when `ssh-add -K` / `UseKeychain yes` is configured.)
- **Cloud credentials** — AWS (`Amazon Web Services`), Google
  (`com.google.cloudsdk`), Azure (`AzureCloud`), Anthropic API
  keys, OpenAI tokens, etc. — pattern-match on common service /
  account names.
- **KeePassXC's own stored items** — ironic but real; if the user
  once ran `keepassxc` with keychain integration on, there may be
  a kdbx password in the Keychain.

Output: a table (label, service, where-stored, recommendation)
with exit code 0 if clean, 1 if any hits. Does NOT extract
secrets — only enumerates. Safe to run anytime.

Auto-invoked once at the end of `install.sh` (user sees it
immediately on first install; if hits, they know what to do).

### `s3c-gorilla keychain fix`
Interactive migration. For each hit from `check`:
1. Print the item's label + service.
2. Ask: `Verify this is also in your kdbx? [Y/n]`.
   - On Y: run a kdbx lookup via `keepassxc-cli ls` (one Touch ID
     prompt for the whole batch, gated through `touchid-gorilla
     fan-out`'s flock — reuses the session).
   - If the kdbx has a matching entry → offer to delete the
     Keychain copy via `security delete-internet-password` /
     `delete-generic-password`.
   - If no kdbx match → warn, skip, do NOT delete. User must add
     it to KeePassXC first.
3. Summarize: `N items migrated, M items left (not in kdbx)`.

Requires an unlocked session (invokes `touchid-gorilla fan-out`
if no `.session-valid` present). Explicit y/N prompt per delete
— no blanket mode. Reason: this touches the Keychain, which
GUI apps depend on. One mistake = log-in flow broken.

### `s3c-gorilla doctor`
Aggregated health check. Superset of `status` + deeper probes:
- All of `status`'s output.
- **Binary integrity** — run `SecCodeCheckValidity` via
  `codesign --verify --deep --strict /usr/local/bin/s3c-ssh-agent`
  and same for `touchid-gorilla` (Concern #43 Layer 2).
- **Codesign flags** — `codesign -d --verbose=4 <bin>` shows
  `flags=0x10000(runtime)` + `Timestamp=` (Concern H3).
- **Filesystem modes** — `/tmp/s3c-gorilla/` is 0700, every `.s3c`
  inside is 0600; `~/.s3c-gorilla/` is 0700, `agent.sock` is 0600,
  `keys.json.s3c` is 0600 (Concern #17 / #42).
- **Bootstrap lockfile** — `/tmp/s3c-gorilla/.bootstrap.lock`
  exists (Concern #28).
- **Dependencies** — `keepassxc-cli` installed, version reported;
  `terminal-notifier` installed + version ≥ pinned minimum
  (Concern #36).
- **Hardware** — Touch ID available on this Mac (bioauth policy
  probe via LAContext); SE usable.
- **KDBX reachable** — path exists, not iCloud-evicted
  (Concern #30 probe).
- **Agent pushed-keys cache** — count + oldest age; warn if
  anything > 5min without a fresh ADD_IDENTITY (Concern #20).
- **Memlock budget** — `ulimit -l` current vs 32 MiB / 48 MiB
  agent plist (Concern #23 / N2).

Output: categorized pass/warn/fail per check. Exit 0 if no fails
(warns OK), 1 on any fail. The quick answer when "something feels
off".

### `s3c-gorilla wipe`
Manual session kill. Use when handing the laptop over, suspecting
tampering, or wanting to force a fresh master-pw prompt before a
risky operation.

Flow:
1. Acquire bootstrap flock (Concern #25 — only fan-out or
   explicit wipe commands mutate the blob dir).
2. `touchid-gorilla wrap-clear` — zero every `.s3c` + `.session-valid`.
3. `launchctl kickstart -k gui/$UID/com.slav-it.s3c-ssh-agent` —
   restart the agent, which hits its SIGTERM path and zeros the
   pushed-keys cache (Concern #20).
4. Report: `N blobs wiped, M pushed keys zeroed, agent restarted`.

No-op if already empty. Silent success = actually wiped.

### `s3c-gorilla ssh list` / `env list` / `otp list`
Enumerate vault contents by group. Names only — no values, no
secrets touched.

Implementation: reads `ls /tmp/s3c-gorilla/<prefix>-*.s3c`
(filenames are stable: `ssh-<name>.s3c`, `env-<proj>.s3c`,
`otp-<service>.s3c`). No Touch ID, no registry unwrap — just a
filename strip. Sub-millisecond.

If no active session (`.session-valid` absent), prints:
```
no active session — run any tool to start one, or
`touchid-gorilla unwrap keys.json` for an immediate listing.
```
User decides whether to spend a Touch ID on the immediate view
or wait for natural tool usage to populate `/tmp/`.

### `s3c-gorilla scan [--env|--ssh|--git|--shell-history|--all]`

Unified filesystem + history scanner. Default: `--env`.

**`--env`** (default) — what the original `scan` spec covered:
plaintext `.env` files under `~/Projects/`, `~/Code/`,
`~/Workspaces/`, `~/src/`, plus `GORILLA_SCAN_ROOTS` from config.
Max depth 6. Uses `find -print0` + NUL-delimited `read`
(Concern #37). For each hit: print path + size + mtime; flag red
if `.env` is in git history OR if containing repo has no
`.gitignore` entry for it.

**`--ssh`** — audit `~/.ssh/`:
- Directory mode = 0700 (warn otherwise).
- For each private key file (detect by header:
  `BEGIN OPENSSH PRIVATE KEY`, `BEGIN RSA PRIVATE KEY`, etc.):
  - Mode must be 0600 (warn if 0644).
  - **Encryption check** — OpenSSH v1 format: look for
    `bcrypt` / `aes256-ctr` cipher markers in the header block.
    PEM format: `Proc-Type: 4,ENCRYPTED`. Plaintext key → flag red.
- `~/.ssh/known_hosts` not hash-formatted (`HashKnownHosts=no`) →
  warn (exposes host list if stolen).
- `~/.ssh/config` mode not 0600 → warn.

**`--git`** — scan git repos in scan-roots for secret-shaped
strings in history. Patterns:
- Private-key PEM headers: `-----BEGIN .* PRIVATE KEY-----`
- AWS access key IDs: `AKIA[0-9A-Z]{16}`
- GitHub tokens: `gh[ps]_[A-Za-z0-9]{36,}`, `github_pat_\w+`
- Slack tokens: `xox[baprs]-[A-Za-z0-9-]+`
- JWT-ish: `eyJ[A-Za-z0-9_-]+\.eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+`
- Google API: `AIza[0-9A-Za-z_-]{35}`

Implementation: `git log -p --all | grep -HnE '<pattern>'`,
printed as `repo:commit:file:line — [REDACTED — pattern N]`. The
actual matched bytes are NOT echoed to terminal (redaction is
non-negotiable — tool must not print secrets even when finding
them). Exit 1 on any hit. Extends the `--env` scope without
overlapping (that one is file-existence; this one is git-history
content).

**`--shell-history`** — grep `~/.zsh_history`,
`~/.bash_history`, `~/.local/share/fish/fish_history` for:
- `export [A-Z_]{3,}=['"]?[A-Za-z0-9/+=_-]{20,}` (long assignments)
- The same secret-shape patterns as `--git`.

Output: file + line number + `[REDACTED — pattern N]`. No secret
values printed. Exit 1 on hits. Same redaction rule as `--git`.

**`--all`** — runs all four in sequence, aggregate exit code.

### `s3c-gorilla keychain import`
The *migration* half of `keychain fix`. For each hit from
`keychain check`, interactively:
1. Print item label + service.
2. Ask for a target kdbx location: group (`ENV`/`SSH`/custom) +
   entry name (default: service). User can skip per-item.
3. Extract the Keychain secret value (one `security
   find-*-password -w <label>`), pipe into `keepassxc-cli add`
   (reuses the fan-out session's master pw; one Touch ID for the
   batch).
4. Keychain entry is left in place — `import` NEVER deletes. Pair
   with `keychain fix` as the second step.

Net: user workflow becomes `check → import → fix`. Each step is
reversible up until `fix` actually deletes. No blanket "migrate
everything" mode — explicit y/N per item.

### Implementation notes
- All subcommands are pure bash in `src/s3c-gorilla` (one file,
  dispatcher + per-subcommand functions). Hard cap ≤ 250 lines
  per CLAUDE.md — if this grows, split into
  `src/s3c-gorilla.d/<subcommand>.sh` sourced by a thin dispatcher.
- `keychain check/fix/import` shells out to `security(1)` —
  standard macOS CLI, works same-uid without special entitlements.
- `scan` uses `find`, `git`, `grep` — no new dependencies.
- `doctor` shells out to `codesign`, `stat`, `launchctl`,
  `keepassxc-cli`, `terminal-notifier`, `ulimit`. All present on
  a working install.
- `wipe` uses `touchid-gorilla wrap-clear` + `launchctl kickstart`
  — no new code.
- `ssh/env/otp list` uses `ls` + `sed` — sub-ms, no Touch ID.
- **Secret-redaction rule for `scan`**: any subcommand that
  discovers a secret-shaped string must NEVER echo the matched
  bytes to stdout or logs. Redaction template:
  `[REDACTED — matched pattern N at <file>:<line>]`. Patterns
  named, values never. Violating this makes the tool worse than
  useless.
- Help: `s3c-gorilla -h` / `s3c-gorilla <cmd> -h` shows usage for
  each. Consistent `--help` at both levels.

## Config knobs (new)

```
# Seconds of inactivity before a blob expires. 7200 = 2hr.
# Every blob tracks its own mtime; any blob touched within this window
# stays valid. Stale blobs trigger a fresh fan-out on next access.
GORILLA_UNLOCK_TTL=7200

# Paranoid Screen Lock: wipe every .s3c when the screen locks.
# 1 = wipe (default, strictest) — locking screen = next tool call needs master pw.
# 0 = keep — sessions survive screen locks; blobs persist until TTL/logout/reboot.
# Turn off if you habitually Cmd-Ctrl-Q your screen many times a day.
GORILLA_WIPE_ON_SCREEN_LOCK=1

# Colon-separated roots for `s3c-gorilla scan`. Defaults cover
# common project layouts; add your own if you keep code elsewhere.
GORILLA_SCAN_ROOTS="$HOME/Projects:$HOME/Code:$HOME/Workspaces:$HOME/src"
```

No mode knob. The eager-unified flow is the only flow. `--paranoid`
per-call flag covers the paranoid case.

## Setup-file numbering

Previously planned `11-unlock-mode.sh` asked A/B for unlock mode.
The eager-unified design makes Mode B redundant, so this step was
deleted. After that drop, the insertion of `12-screen-lock.sh`,
and the removal of `10-fs-gorilla.sh` (fs-gorilla / llm-gorilla /
firewall-gorilla are out of scope for this project), final setup
file numbering is:

```
... 09-database.sh
    [10 retired — was fs-gorilla, out of scope]
    11-pw-prompt.sh
    12-screen-lock.sh      (Paranoid Screen Lock toggle)
    13-ssh-mode.sh
    14-launchagent.sh
    15-permissions.sh
    16-s3c-gorilla.sh      (install umbrella CLI; auto-run keychain check)
    99-done.sh
```

Slot 10 left deliberately empty rather than renumbered — keeps
churn down in docs/comments/validation rows that reference
11-16 by number. `sort -V` handles the gap fine.

## Step 1 behavior (`01-keepassxc.sh`) — detail

- Install `keepassxc-cli` via `brew install --cask keepassxc` if
  missing (the cask installs both GUI + CLI in one shot).
- Install `terminal-notifier` via `brew install terminal-notifier`
  if missing — required by `otp-gorilla` for macOS notifications.
- After install (or if already present), print a one-liner that the
  KeePassXC **GUI app** is officially available both via Homebrew
  cask and as a direct `.dmg` from upstream:
  - https://keepassxc.org/download/#macos
  - https://github.com/keepassxreboot/keepassxc/releases

  (So users who prefer the signed upstream `.dmg` over Homebrew know
  where to get it.)
- Bail with a clear error if Homebrew isn't installed; don't try to
  download things ourselves.

## Step 9 behavior (`09-database.sh`) — detail

Instead of blindly verifying the path from config, actively scan
iCloud Drive for `.kdbx` files and offer a picker when ambiguous.

Flow:
1. If `$GORILLA_DB` from config already points to a real file, print
   it and move on. No prompt.
2. Else: scan
   ```
   find ~/Library/Mobile\ Documents/com~apple~CloudDocs -type f -name '*.kdbx' 2>/dev/null
   ```
   - **0 matches**: warn that no kdbx was found in iCloud; keep
     `$GORILLA_DB` as-is (user can edit config later or set it up
     in KeePassXC first, then re-run install).
   - **1 match**: print the path, ask
     `Use this database? [Y/n]`. On Y, rewrite `$GORILLA_DB` in
     `~/.config/s3c-gorilla/config`.
   - **≥ 2 matches**: print a numbered list, let user pick:
     ```
     Multiple KeePassXC databases found in iCloud:
       1) /Users/yaro/Library/Mobile Documents/…/personal.kdbx
       2) /Users/yaro/Library/Mobile Documents/…/gorilla_tunnel.dat.kdbx
       3) /Users/yaro/Library/Mobile Documents/…/shared/work.kdbx

     Pick one [1-3, 0=keep config default]:
     ```
     Selected path → written to `$GORILLA_DB` in user config.

Also scan `~/Documents/` and the legacy Dropbox path
(`~/Dropbox/`) on a best-effort basis — same picker semantics.
Scan depth capped at ~5 levels to avoid chewing on huge trees.

No change to Step 1 behavior (`01-keepassxc.sh` just ensures
binaries exist and prints info; it doesn't touch the DB path).

### Large-attachment warning (added after Phase 0 verification)

After the kdbx path is confirmed, `09-database.sh` runs a rough
size probe — no unlock required, just `stat -f %z "$GORILLA_DB"`:

```bash
kdbx_bytes=$(stat -f %z "$GORILLA_DB" 2>/dev/null || echo 0)
kdbx_mib=$((kdbx_bytes / 1048576))
# Fan-out budget (default 32 MiB) must cover XML export (~kdbx × 1.33).
# 24 MiB kdbx → ~32 MiB XML → right at the budget wall.
if (( kdbx_mib > 24 )); then
    warn "your kdbx is ${kdbx_mib} MiB. s3c-gorilla's default"
    warn "GORILLA_MLOCK_BUDGET handles vaults up to ~24 MiB safely."
    warn "if fan-out fails with 'vault exceeds budget', bump"
    warn "GORILLA_MLOCK_BUDGET in ~/.config/s3c-gorilla/config"
    warn "(and GORILLA_AGENT_MEMLOCK_BYTES for the LaunchAgent plist)."
fi
```

Why a `stat`-only probe (no unlock needed at install time):
- Kdbx on-disk size ≈ raw attachment bytes (internal gzip
  compression ≈ base64 overhead on export, roughly cancels).
- XML export is ~1.33× the kdbx size due to base64 expansion.
- Default 32 MiB budget ÷ 1.33 ≈ 24 MiB kdbx ceiling.
- Probe accuracy doesn't matter much — it's an early warning,
  not a gate. The real gate is fan-out's runtime budget check
  (Concern #23 / N3) which fails closed with a clear error.

Config knob (added to `src/setup/config.example`):
```
# Memlock budget for fan-out extraction (bytes). Default 32 MiB
# covers kdbx up to ~24 MiB (XML export ≈ 1.33× kdbx). Raise if
# your vault has large attachments (multi-MB PDFs, cert chains).
GORILLA_MLOCK_BUDGET=33554432   # 32 MiB
```

## Step 11 behavior (`11-pw-prompt.sh`) — detail

Ask user the default master-password prompt style, saved to config:

```
How should the master password prompt look?

  A) macOS dialog window  [Recommended]
     Native password dialog with secure keyboard input (resists
     keyloggers that don't have Accessibility permission). Works
     from terminal AND when GUI apps trigger the flow.

  B) Terminal prompt (hidden input)
     Traditional `read -s` in the terminal you're running from.
     Simple but uses regular keyboard input — a user-level keylogger
     could capture your master password.

Which? [A/B, Enter=A]:
```

Saved as `GORILLA_MASTER_PW_PROMPT=dialog` (A) or
`GORILLA_MASTER_PW_PROMPT=terminal` (B) in
`~/.config/s3c-gorilla/config`.

**Per-invocation override flags** (available on both env-gorilla
and otp-gorilla regardless of install-time default):

- `--pw-dialog` — force macOS dialog prompt for this call.
- `--pw-terminal` — force terminal `read -s` for this call.

Also an env-var equivalent for scripted contexts:
`S3C_PW_PROMPT=terminal` or `S3C_PW_PROMPT=dialog`.

**SSH agent constraint**: the daemon is a LaunchAgent and never has
a TTY — it always uses the dialog path, regardless of the
install-time setting or any shell env var. So the terminal-prompt
option effectively applies only to env-gorilla / otp-gorilla /
manual `touchid-gorilla` invocations. Documented clearly in
`11-pw-prompt.sh` output:
```
  Note: SSH agent always uses the dialog regardless of this choice
  (it runs as a background daemon with no terminal).
```

## Step 12 behavior (`12-screen-lock.sh`) — detail

Ask how strict the user wants screen-lock behaviour:

```
Paranoid Screen Lock

Every time your screen locks (Cmd-Ctrl-Q, screensaver, lid close),
should we wipe all cached secrets?

  A) Wipe on every screen lock  [Recommended, strictest]
     You re-enter your KeePass master password the next time you
     use any tool. Every lock = full session reset. Best against
     attackers who get access to an unlocked screen.

  B) Keep sessions across screen locks
     Touch ID after unlocking the screen still unwraps cached
     secrets. Session only ends on logout, reboot, 7200s idle, or
     explicit wipe. Much more convenient if you lock your screen
     many times per day.

Which? [A/B, Enter=A]:
```

Saves `GORILLA_WIPE_ON_SCREEN_LOCK=1` (A) or `=0` (B) to
`$CONFIG_FILE`. Agent reads this on every notification: if 0,
ignores `com.apple.screenIsLocked`; if 1, wipes `/tmp/s3c-gorilla/`
and the pushed-keys cache. 7200s TTL + logout still fire regardless.

## Optional SSH-hygiene steps during chip-wrap import (`13-ssh-mode.sh`)

Offered per key during the chip-wrap import flow, before the kdbx
attachment-import. Both optional — user can skip each.

### Optional A — rotate the key's passphrase
If the key currently has a passphrase, offer to rotate it now
(just a passphrase change on the on-disk key file before we
import it). Rationale: hygiene; periodic rotation is good even
when it eventually gets stripped (defense in depth).

**No server-side changes.** The passphrase protects the private
key file; servers only verify via the public half, which stays
identical. Called out explicitly in the prompt:

```
Key 'id_rsa' has a passphrase.
  Rotate passphrase now? (optional, good hygiene)
  → public key does NOT change → no server changes needed.

Rotate? [y/N]
```

If Y: `ssh-keygen -p -f ~/.ssh/id_rsa` interactively (user types
old + new + confirm).

### Optional B — upgrade weak/old key to modern type
When we detect the selected key is RSA (any size) or DSA, offer
to generate a fresh **Ed25519** key and use THAT for the rest of
the flow (chip-wrap the new key, push new public half to servers).

```
Key 'id_rsa' is RSA 2048-bit — works fine but Ed25519 is the
modern default (shorter keys, faster signatures, resistant to
implementation bugs common in older RSA code).

Generate a new Ed25519 key and use it from now on?
  → The PUBLIC KEY CHANGES → you'll need to add the new public
    key to authorized_keys on every server you ssh into
    (the old key stays in ~/.ssh/ as backup until you delete it).

Upgrade? [y/N]
```

If Y:
1. `ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519_<timestamp> -C "s3c-gorilla upgrade from id_rsa on $(date +%Y-%m-%d)"`
2. Display new public key with server-push instructions:
   ```
   New Ed25519 public key:
     ssh-ed25519 AAAAC3… s3c-gorilla upgrade from id_rsa on 2026-05-01

   Saved to: ~/.ssh/id_ed25519_20260501.pub

   Push it to each server:
     ssh-copy-id -i ~/.ssh/id_ed25519_20260501.pub user@host

   Press Enter once you've pushed it to all servers you use…
   ```
3. Use the new key for the rest of the import flow (strip/rotate
   passphrase, chip-wrap, register in `keys.json.s3c`).
4. Old key stays in `~/.ssh/` as untouched backup. Not imported.
   User can delete it manually once confident.

If user says N to upgrade: the old RSA key is imported as-is
(RSA signing works fine via our CommonCrypto-backed path).

### Ordering of the three passphrase options per key
For each selected key (new upgraded Ed25519 or original), after
upgrade question:

```
What do you want to do with this key's passphrase?

  1) Strip it — kdbx is the new guard (Recommended for chip-wrap).
     Touch ID will be the only gate.
  2) Rotate it — change the passphrase now, keep it as a second
     layer on top of kdbx (type it on every ssh).
  3) Keep it as-is — don't change anything.

[1/2/3, Enter=1]:
```

Rotate is the "optional A" path offered only as the #2 choice
here. Strip remains the recommended default.

## macOS permissions guidance in install.sh

macOS has several permission categories we'll trip into. Install.sh
should walk the user through each one **at the right moment** — not
dump them all at the start, not let them hit errors silently later.

### Permissions we need (and when)

| Permission | Needed by | Triggered at |
|---|---|---|
| **Notifications** (`terminal-notifier`) | otp-gorilla popups | First `terminal-notifier` invocation |

(Phase 3 was dropped; no Accessibility / Automation prompts from
s3c-gorilla itself. The only remaining osascript usage is the
optional dialog-mode master-pw prompt, which runs under the
user's Terminal process and inherits whatever Automation grants
Terminal already has.)

### Install-time guidance flow

Add a new step `15-permissions.sh` that runs AFTER the LaunchAgent
installation and before the final cheatsheet. It:

1. **Triggers each permission request proactively**, one at a time,
   with clear narration:
   ```
   [14] macOS permissions

   We're going to trigger each permission prompt one at a time so
   macOS can ask you now (rather than you hitting a silent failure
   later). Grant each one and press Enter to continue.

   ---
   (1/1) Notifications — terminal-notifier needs this for OTP
         codes. Sending a test notification…
   ```
   Runs: `terminal-notifier -title "s3c-gorilla" -message "Notifications are working"`.
   First run pops the "Allow terminal-notifier to send notifications?"
   prompt. Tells user to click Allow.
   ```
   Press Enter when you've clicked Allow (or Don't Allow to skip):
   ```

2. **Documented in post-install cheatsheet** what happens if they
   revoke a permission later:
   - Revoke Notifications → otp codes still print to terminal +
     clipboard, no desktop popup.

### For the Secure Event Input call (H4)

`EnableSecureEventInput()` does **not** require any permission.
It's a system-wide input lock any signed process can request.
While held, macOS displays a small icon in the menu bar. No setup
needed, no user intervention. Documented in the plan so we don't
accidentally wire a permission check for it.

## Clear labelling of every password prompt

There are four distinct passwords in play during a session — users
get lost. Every prompt across install.sh, agent, and all CLI tools
must label which password is being asked for:

| Password | When asked | Exact label |
|---|---|---|
| macOS login / sudo | install.sh Step 2 (sudo prime), Step 14 (LaunchAgent install) | `macOS login password (sudo):` |
| KeePass master | env/otp/ssh bootstrap | `KeePass master password — needed to unlock ENV/project_x:` (include tool + item) |
| SSH key passphrase | ssh-keygen -p during chip-wrap import in Step 12 | `SSH key passphrase for id_rsa (the one you've been typing when connecting):` |
| KeePassXC GUI unlock | KeePassXC's own dialog (not our prompt) | (not ours) |

Implementation:
- `touchid-gorilla master-prompt` (new subcommand from H4) takes a
  `--label <what-for>` arg and renders:
  ```
  ┌─────────────────────────────────────────────┐
  │ KeePass master password                     │
  │ (needed to unlock ENV/project_x)            │
  └─────────────────────────────────────────────┘
  Password:
  ```
- Dialog variant (osascript) uses `display dialog` with the label
  as the message body.
- sudo prompts in install.sh get a prefix banner: "This asks for
  your **macOS login password** (sudo)." — printed once at the
  start of each step that primes sudo.
- ssh-keygen passphrase stripping (chip-wrap SSH import) gets a
  one-line callout above: "The next prompt is the **existing SSH
  key passphrase** — the one you type when connecting to servers."

No emoji in these prompts (per memory). Plain text, clear ownership.

## Security hardening (ships as part of Phase 1)

Four improvements lifted from the self-review. Ship them now, not later.

### H1 — Explicit zeroing of master-pw / secret bytes in Swift
Replace `String` with `Data` for all secret buffers in
`touchid-gorilla.swift` and `s3c-ssh-agent.swift`. After use, zero
the bytes explicitly before deallocation:

```swift
func zero(_ d: inout Data) {
    let n = d.count
    d.withUnsafeMutableBytes { ptr in
        guard let base = ptr.baseAddress else { return }
        memset(base, 0, n)
    }
    d.removeAll(keepingCapacity: false)
}
```

Touched code paths: master pw bytes zeroed immediately after
fan-out extraction completes; unwrapped SSH key bytes zeroed after
`SecKeyCreateSignature` returns; TOTP secret bytes zeroed after
`computeTOTP`; .env bytes zeroed after `exec`'s environment is set
up. Swift `String` only used where we can't avoid it (argv, print).
Any `String`-held secret wrapped in a `defer` block that overwrites
its backing storage where possible.

### H2 — Eliminate hand-rolled BigInt via CommonCrypto
Skip computing CRT params in Swift entirely. Hand the raw factors
`(n, e, p, q)` to CommonCrypto's `CCRSACryptorCreateFromData`
(private-key variant); the framework computes all internal CRT
material using Apple's audited math. Then sign via
`CCRSACryptorSign` with PKCS#1 v1.5 padding.

```swift
import CommonCrypto

var cryptorRef: CCRSACryptorRef?
let status = CCRSACryptorCreateFromData(
    .rsaKeyPrivate,
    /* modulus */ nData, nData.count,
    /* exponent (e) */ eData, eData.count,
    /* p */ pData, pData.count,
    /* q */ qData, qData.count,
    &cryptorRef
)
```

Our BigInt struct + `modPow` + CRT-param derivation become a
**dormant fallback** — code stays in the repo but isn't called on
the primary path. Selected at runtime by a single
`useCommonCrypto()` check (see Concern #22). If CommonCrypto is
unavailable on a future macOS, we flip to the hand-computed path
automatically.

If CommonCrypto is available but rejects our inputs (non-standard
exponent etc.), **fail closed** — return `SSH_AGENT_FAILURE` rather
than silently fall back to the hand-rolled path. We only use the
fallback when the framework itself is missing.

### H3 — Hardened runtime on every codesign invocation
Add `--options runtime` to every `codesign` call in
`05-touchid.sh` / `touchid-compile-touchid.sh` /
`touchid-compile-agent.sh`. Blocks debugger injection and library
interposition at the OS level. Standard practice for Developer ID
distribution.

```bash
codesign --force --options runtime --timestamp \
    --sign "$SIGN_IDENTITY" \
    --entitlements "$ENT_FILE" \
    "$BUILD_BIN"
```

`--timestamp` is a freebie while we're there — it future-proofs
the signature against certificate expiry.

### H4 — Secure keyboard input for terminal master-pw prompts
macOS has `EnableSecureEventInput()` (from Carbon / HIServices) —
while active, keystrokes are routed through a special path
inaccessible to user-level keyloggers (yellow padlock appears in
the menu bar, same UX Keychain Access uses for its master-pw
prompts).

Bash's `read -s` doesn't request it. Fix: centralise the master-pw
prompt inside `touchid-gorilla`, which is a signed Swift binary
that CAN call the API:

```swift
func readMasterPasswordSecurely(prompt: String) -> Data? {
    EnableSecureEventInput()
    defer { DisableSecureEventInput() }
    fputs(prompt, stderr)
    return readLinePasswordBytes()   // raw bytes into Data, no Swift String
}
```

New subcommand: `touchid-gorilla master-prompt "Master password: "`
prints the prompt, reads the password silently with secure input,
writes the bytes to stdout (piped to caller), unsets memory.

`env-gorilla`, `otp-gorilla`, and the agent (when falling back to
terminal) all call `touchid-gorilla master-prompt` instead of
doing `read -s` themselves. One code path, secure input always.

## Pre-implementation — refactor install.sh

Before any code changes, split the current monolithic `install.sh`
(~800 lines) into a lean orchestrator + per-step helper files. Goal:
main `install.sh` ≤ 200 lines.

### Step 0.a — move the current script
```bash
mv install.sh install.sh.bak          # keep old monolith as rollback reference
# new lean install.sh will live at src/install.sh (NOT repo root) —
# matches the URL path used by the curl-bash one-liner:
#   bash <(curl -fsSL https://raw.githubusercontent.com/RussianRoulette84/s3c-gorilla/master/src/install.sh)
```

### Step 0.b — lean `src/install.sh` (≤200 lines)
Lives at `src/install.sh`. Does only:
- Self-bootstrap when invoked via curl-bash (see Step 0.e below).
- Set `SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"`,
  `REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"`, `SRC_DIR="$SCRIPT_DIR"`,
  plus `BIN_DIR`, `SHARE_DIR`, `CONFIG_DIR`, `CONFIG_FILE`, `BUILD_DIR`.
- Source `$REPO_ROOT/lib/ywizz/ywizz.sh` for TUI helpers.
- Prime sudo + sudo-keepalive.
- Source `$SRC_DIR/setup.sh` (orchestrator).
- Print final "INSTALLED" banner + cheatsheet (or delegate to
  `$SRC_DIR/setup/99-done.sh`).

### Step 0.c — `src/setup.sh` orchestrator
Sources the numbered step files in order. Helpers (non-digit-prefix)
are skipped by the orchestrator glob and sourced by the specific
step files that need them:
```bash
for step in "$SRC_DIR/setup/"[0-9]*.sh; do
    source "$step"
done
```

### Step 0.d — per-step files under `src/setup/`
250-line hard cap per CLAUDE.md. Touch ID is split preemptively —
it's the largest step and Phase 2 will add more to it. Layout:

```
src/setup/
├── 00-common.sh                    # shared vars + TUI helpers
├── 01-keepassxc.sh                 # keepassxc-cli + terminal-notifier
├── 02-targets.sh                   # print install targets, prime sudo
├── 03-config.sh                    # deploy user config
├── 04-tools.sh                     # install env-gorilla, otp-gorilla, ssh-gorilla.sh
├── 05-touchid.sh                   # orchestrator: detect hw, ask Y/N, call helpers below
├── 06-ssh-config.sh                # sanity-check ~/.ssh/config
├── 07-shell.sh                     # add source lines to .zprofile
├── 08-path.sh                      # verify /usr/local/bin on $PATH
├── 09-database.sh                  # find + verify kdbx path (iCloud scan)
├── 11-pw-prompt.sh                 # [NEW] dialog vs terminal → GORILLA_MASTER_PW_PROMPT
├── 12-screen-lock.sh               # [NEW] Paranoid Screen Lock toggle → GORILLA_WIPE_ON_SCREEN_LOCK
├── 13-ssh-mode.sh                  # chip-wrap vs se-born, import SSH keys
├── 14-launchagent.sh               # install + bootstrap s3c-ssh-agent
├── 15-permissions.sh               # [NEW] guide through Notifications grant (Accessibility/Automation no longer needed after Phase 3 drop)
├── 16-s3c-gorilla.sh               # [NEW] install `/usr/local/bin/s3c-gorilla` + auto-run `keychain check`
├── 99-done.sh                      # final banner + cheatsheet
│
│  # helpers — no digit prefix, skipped by orchestrator glob.
│  # Sourced by 05-touchid.sh as needed.
├── touchid-codesign-picker.sh      # defines pick_codesign_identity()
├── touchid-compile-touchid.sh      # defines compile_install_touchid()
└── touchid-compile-agent.sh        # defines compile_install_agent()
```

`05-touchid.sh` flow (stays ≤ 80 lines):
```bash
# 05-touchid.sh
source "$SCRIPT_DIR/src/setup/touchid-codesign-picker.sh"
source "$SCRIPT_DIR/src/setup/touchid-compile-touchid.sh"
source "$SCRIPT_DIR/src/setup/touchid-compile-agent.sh"

section "[5] Touch ID"
detect_touchid_hardware || { skip "No Touch ID"; return 0; }
read -p "Enable Touch ID mode? [Y/n] "
[[ ! $REPLY =~ ^[Yy]$|^$ ]] && { skip "opted out"; return 0; }

pick_codesign_identity            # sets SIGN_IDENTITY
compile_install_touchid           # compile → codesign → `sudo install -m 0555 -o root -g wheel` → pin cdhash (Concern #43)
compile_install_agent             # compile → codesign → `sudo install -m 0555 -o root -g wheel` → pin cdhash (Concern #43)
```

Both `compile_install_*` helpers share a post-install snippet:
```bash
sudo mkdir -p /usr/local/share/s3c-gorilla && sudo chmod 0755 /usr/local/share/s3c-gorilla
cdhash=$(codesign -d -v "/usr/local/bin/$bin" 2>&1 | awk -F'=' '/^CDHash/ {print $2}')
printf '%s\n' "$cdhash" | sudo tee "/usr/local/share/s3c-gorilla/$bin.cdhash" >/dev/null
sudo chmod 0444 "/usr/local/share/s3c-gorilla/$bin.cdhash"
sudo chown root:wheel "/usr/local/share/s3c-gorilla/$bin.cdhash"
```

Each helper file is ≤ 250 lines by construction (they're tight,
single-responsibility).

Each step/helper file starts with a header comment describing its
purpose, inputs (global vars it expects), and outputs (vars it sets).

### Step 0.e — curl-bash self-bootstrap
The primary install UX is a one-liner:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/RussianRoulette84/s3c-gorilla/master/src/install.sh)
```

That fetches ONLY `src/install.sh` — the rest of the repo
(`setup/*.sh`, `lib/ywizz/`, helpers) isn't available yet. So
`src/install.sh` must detect the curl-bash case and bootstrap
itself by cloning the repo to a canonical location, then re-exec
from the local clone.

**Canonical local-clone path:** `~/.local/share/s3c-gorilla/repo`
(user-writable; no sudo needed for the clone itself — sudo is
primed later when binaries land in `/usr/local/bin`).

**Detection + bootstrap** (first block of `src/install.sh`):
```bash
#!/usr/bin/env bash
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
CANONICAL="$HOME/.local/share/s3c-gorilla/repo"

# Running via curl-bash? Two signals:
#   1. BASH_SOURCE is /dev/fd/NN or empty (process substitution).
#   2. Sibling files (../lib/ywizz or ./setup/) aren't there.
if [[ -z "$SCRIPT_DIR" ]] \
   || [[ "${BASH_SOURCE[0]:-}" == /dev/fd/* ]] \
   || [[ ! -d "$SCRIPT_DIR/setup" ]]; then
    echo "→ Bootstrapping from github into $CANONICAL"
    mkdir -p "$(dirname "$CANONICAL")"
    if [[ -d "$CANONICAL/.git" ]]; then
        git -C "$CANONICAL" pull --ff-only || {
            echo "git pull failed — delete $CANONICAL and retry."; exit 1
        }
    else
        git clone --depth 1 \
            https://github.com/RussianRoulette84/s3c-gorilla.git \
            "$CANONICAL" || exit 1
    fi
    exec bash "$CANONICAL/src/install.sh" "$@"
fi

# Normal path: we're running from a local clone. Proceed.
# ... rest of install.sh ...
```

- **`git` is required.** Present on macOS via Xcode CLT (installed
  by default on modern macOS). If missing, bootstrap prints
  `xcode-select --install` instructions and exits.
- **Install-source recording (Concern #43):** after `sudo install`
  lands the binaries, record `$(git -C "$CANONICAL" rev-parse
  --show-toplevel)` into `/usr/local/share/s3c-gorilla/install-source`.
  `s3c-gorilla setup` reads this path, runs `git pull` there, then
  re-invokes `src/install.sh`.
- **Security tradeoff — curl|bash honesty.** A security-focused
  tool shipped via `curl | bash` is, optically, ironic. README
  acknowledges this by offering a `git clone && less
  src/install.sh` inspect-before-run path as the recommended
  alternative. No checksum pin ships today — pinning a fresh
  hash on every commit creates its own update-friction pit. If
  this becomes a real user request, we can publish signed
  tarballs per release and update the one-liner to verify against
  a pinned minisign/GPG key.

### Benefits
- Main `install.sh` becomes scannable in seconds.
- Each step is independently testable (`source src/setup/05-touchid.sh`).
- Edits localized — Touch ID compile flow stays in one file, etc.
- Adding new steps is a matter of dropping a numbered file.

### Scope + sequencing
This refactor happens ONCE, **before** Phase 1 of the feature plan,
AND must be verified end-to-end before any feature code is touched.

**Gate before moving to Phase 1:**
1. After the split, run `src/install.sh` on a Mac (local dev) and
   confirm the installer completes all steps successfully and
   produces the same installed state as `install.sh.bak` would.
2. Any regression = fix in the refactor first. Do not start Phase 1
   on top of a broken installer.

All subsequent phases below (eager fan-out, KeePassXC integration,
etc.) edit individual step files rather than the main install.sh.

### Shared constants / helpers
Step files are "independently testable" only if they can load the
common environment without the orchestrator. Solution:

```
src/setup/00-common.sh
```

Sets `SCRIPT_DIR`, `SRC_DIR`, `BIN_DIR`, `SHARE_DIR`, `CONFIG_DIR`,
`BUILD_DIR`, sources `lib/ywizz/ywizz.sh`, defines `section()`,
`item()`, `skip()`, etc. Every step file opens with:
```bash
[[ -z "${SETUP_COMMON_LOADED:-}" ]] && source "$(dirname "$0")/00-common.sh"
```
Main `install.sh` sources `00-common.sh` first, then the rest.

### File size
Each step file ≤ 250 lines per CLAUDE.md. Current Step 5 (Touch ID)
is ~130 — fine. If Phase 2/3 pushes it past 200, split
(`05a-codesign-picker.sh` + `05b-compile.sh` + `05c-touchid-store.sh`).
Split lazily, not preemptively.

### install.sh.bak disposition
Add `install.sh.bak` to `.gitignore`. It's a local migration
artifact — not shipping.

### Phase 0 is research, not an install step
Phase 0 is decision-time work for the implementer (keepassxc-cli
XML export verification on a real vault). It does NOT appear as
a step in `install.sh`. The installer just ships the result.

---

## Build strategy + execution model

See [plan/BUILD_STRATEGY.md](BUILD_STRATEGY.md) for the full
7-point rule set. Non-negotiable summary:

1. **Never touch `master`.** All work goes through `develop`.
2. **Branch-per-phase.** `phase/0-kcli-probe`, `phase/1-fanout`,
   `phase/2-kpxc-push`. Merge into `develop` only after the
   phase's PLAN.md §4 validation rows pass.
3. **Red-first, one concern at a time.** Tests already
   skip-stub most concerns. Remove a skip → ship the smallest
   diff that passes → commit → next. The 43-concern list IS
   the backlog.
4. **Parallel subagents for genuinely independent work.** Spin
   them in one turn when entering a phase. Dependencies must be
   zero across panes.
5. **`/review` after every phase merge** — de-slop first
   (CLAUDE.md rule), then code review. No Phase-N cruft into
   Phase-N+1.
6. **Dogfood as soon as it compiles.** Real `id_rsa` + real
   `ssh somehost` the minute fan-out works on one secret.
7. **Keep this file alive.** Tick `[x]` + bump success % on
   every closed concern. Add rows when new issues surface.
   Stale plan mid-build > no plan.

### Execution via `cld --tmux-team`
Implementation runs inside `llm-docker`'s tmux-team layout:

```
┌────────────────┬─────────────────┐
│                │  @agent-1       │  ← Opus subagent (purple)
│                ├─────────────────┤
│   @lead        │  @agent-2       │  ← Opus subagent (blue)
│   60% width    ├─────────────────┤
│   (Opus)       │  @agent-3-haiku │  ← Haiku cheap/fast runner (orange)
└────────────────┴─────────────────┘
```

- **@lead** — orchestrator: reads PLAN.md, picks next concern,
  delegates, merges, ticks boxes.
- **@agent-1 / @agent-2** — Opus workers in parallel on
  independent tasks (e.g. fan-out impl + install.sh refactor).
- **@agent-3-haiku** — cheap/fast pane for test runs, lints,
  file moves, grep sweeps. Don't send it design work.

Shared FS + sessions inside one container (llm-docker's
default). All four panes see the same repo, same `src/tests/`,
same `plan/PLAN.md`. Commits from any pane land on the same
branch.

## Implementation phases

**Ordering (strict):**
1. Refactor `install.sh` per "Pre-implementation" section. Gate: new installer must match old installer's behaviour on a dev Mac before any feature work begins.
2. **Phase 0 — `keepassxc-cli export --format xml` verification (GATE, Concern #24).** Must pass before Phase 1 starts. See dedicated section below.
3. Phase 1 — eager fan-out extraction + per-blob TTL + `--paranoid` + H1-H4 security hardening.
4. Phase 2 — KeePassXC SSH-Agent push integration.

(Phase 3 — KeePassXC unlock refreshes TTL — **dropped**. See
Architecture §6: TTL is user-tunable via `GORILLA_UNLOCK_TTL`.
Concerns #12/#21/#32/#38 marked obsolete.)

- **Phase 0 — `keepassxc-cli export --format xml` verification**
  (research, ~30 min, GATE before Phase 1 — Concern #24). The
  bulk XML export is the primary fan-out path; we can't commit to
  it without a direct read of current KeePassXC-cli behaviour on a
  real vault. Probes (all run on a disposable test kdbx
  containing one SSH key attachment, one `.env` attachment, one
  TOTP entry, plus one oversized-attachment entry ~15 MiB):

  1. **stdout vs `-o <file>` behaviour.**
     ```
     keepassxc-cli export --format xml <db>                 # stdout?
     keepassxc-cli export --format xml -o /tmp/out.xml <db> # file-only?
     ```
     Confirm whether stdout is supported. If it is → use it.
     If the binary REQUIRES `-o <file>`: **plan-breaker unless
     we can point `-o` at a path we control with correct modes.**
     Acceptable fallback: `-o /dev/stdout` on macOS (named fd).
     If neither stdout nor `/dev/stdout` works, Concern #24
     escalates and we drop the bulk-XML primary path in favor of
     the Phase 1 fallback: parallel `keepassxc-cli` workers
     (§2a path 2).
  2. **Temp-file behaviour.** Run `lsof` / `dtruss -t open`
     against the export process and confirm it does NOT write a
     tempfile elsewhere (e.g. `/tmp/keepassxc-<pid>.xml`) before
     streaming to stdout. **If it does → plan-breaker.** Secrets
     on disk — even for microseconds — violate our threat model.
     Fallback: parallel-workers path.
  3. **Attachment encoding format.** Inspect the produced XML:
     does it inline attachments as base64 under
     `<Meta><Binaries><Binary ID="N" Compressed="True">BASE64</Binary></Binaries></Meta>`
     with `<Binary Ref="N"/>` references in entries? Or does it
     emit raw bytes in-place? Confirm current KeePassXC-cli
     version (upstream has changed this across 2.6 → 2.7). Our
     two-pass Swift parser (§2a) assumes the `Meta/Binaries` +
     `Ref` scheme.
  4. **Behaviour on large attachments (>32 MiB).** Does
     keepassxc-cli stream them, buffer the whole XML, or crash?
     Sized deliberately above our 32 MiB mlock budget (Concern
     #23) so we see the failure mode. Expected: we catch the
     oversize at our budget gate and fail-closed; verify nothing
     leaks to disk first.
  5. **Master-pw piping semantics.** Confirm `keepassxc-cli` still
     reads master pw from stdin via
     `keepassxc-cli export --no-password --format xml <db> < <(printf '%s' "$mpw")`
     or whatever the current pattern is. Confirm no interactive
     prompt on controlling TTY; confirm clean exit code on wrong
     password (§2b integrity check).

  **Output of Phase 0:** findings folded directly into this plan
  (budget bumps, Step 9 size warning, Compressed="True" on all
  attachments, etc.) — no separate verdict markdown. Verdict:
  **bulk-XML GREEN** (2026-04-24, kxc-cli 2.7.12). Phase 1 uses
  the bulk-XML path as primary; parallel-workers fallback stays
  in the plan as an escape hatch if a future kxc-cli version
  regresses. No code is shipped in Phase 0.

- **Phase 1** — eager fan-out + per-blob TTL + `--paranoid` flag +
  all four security hardening items (H1-H4) + Concerns #18-#39
  that deliver alongside.
  Touches:
  - `src/touchid-gorilla.swift`:
    - H1/Concern #27 (90/5 rule): inline `mmap`+`mlock` on the bulk XML buffer only, with explicit `memset` → `munlock` → `munmap` in a `defer` block. Per-entry secrets (SSH key / .env / TOTP seed) are plain `Data`; call the five-line `wipe(&d)` helper via `defer` at end-of-scope. No raw-pointer `SecretBuf` type, no `// SECRET-NECROPSY` annotations, no lint script.
    - H2/Concern #22: use `CCRSACryptorCreateFromData(n, e, p, q)` + `CCRSACryptorSign` as the primary RSA path via `dlopen`/`dlsym` runtime guard. Keep BigInt / `modPow` / `convertOpenSSHRSAToPKCS1` as a DORMANT fallback, selected automatically if `dlsym` returns nil. Fail-closed on primary input rejection.
    - H2/Concern #33: byte-identical-to-`ssh-keygen -Y sign` test for all three RSA algorithms (ssh-rsa, rsa-sha2-256, rsa-sha2-512) plus live `sshd` smoke.
    - H4/Concern #18: new `master-prompt --label <what-for>` subcommand that calls `EnableSecureEventInput()` around a raw `read` into a `Data` buffer (wiped via `wipe()` in a `defer`); SIGINT/TERM/SEGV/BUS/ABRT/PIPE handlers all call `DisableSecureEventInput()` (no fork).
    - Concern #23: `setrlimit(RLIMIT_CORE, {0,0})` on entry; `getrlimit(RLIMIT_MEMLOCK) ≥ 32 MiB` precheck; per-alloc budget counter fails closed on exceed.
    - Concern #43: first thing at `main()` — call `SecCodeCheckValidity` on self, then compare own cdhash to `/usr/local/share/s3c-gorilla/touchid-gorilla.cdhash` (or `agent.cdhash` for the agent). Fail-closed on either mismatch before any SE call.
    - Add `fan-out` subcommand (shared bootstrap; used by agent + env/otp subprocess). Takes bootstrap flock → wipes `/tmp/s3c-gorilla/*` → extracts → renames → writes `.session-valid` → releases lock.
    - Tool-side inline check: `fstat` blob mtime vs `sysctl -n kern.boottime` (Concern #26) before trusting any blob.
  - `src/s3c-ssh-agent.swift`:
    - H1/Concern #27: plain `Data` + `wipe(&d)`-in-`defer` across unwrap/sign paths. No mlock on per-key buffers (agent only holds one key at a time during a sign, not a vault's worth).
    - `RunAtLoad` unconditionally wipes `/tmp/s3c-gorilla/*` under the bootstrap flock (Concern #26), then re-creates the dir + lockfile (Concern #28).
    - Sign-path fan-out trigger: on first sign with no matching per-key blob, invoke `touchid-gorilla fan-out` (under flock, one master-pw prompt). Agent unwraps the specific SSH key for the current sign.
    - Honours `S3C_PARANOID` env var.
    - (Phase 2 adds ADD_IDENTITY/REMOVE handlers separately.)
  - `src/env-gorilla`, `src/otp-gorilla`:
    - Add `--paranoid` flag, `--pw-dialog` / `--pw-terminal` flags.
    - Runtime flow: own blob present → Touch ID unwrap; absent → trigger fan-out, then unwrap. No mode branching.
    - All master-pw prompts route through `touchid-gorilla master-prompt`.
  - `src/setup/touchid-compile-*.sh` (and any other codesign invocations):
    - H3: add `--options runtime --timestamp` to every `codesign` call.
  - `src/setup/config.example`: new knobs `GORILLA_UNLOCK_TTL`, `GORILLA_MASTER_PW_PROMPT`. NO `GORILLA_UNLOCK_MODE` — single flow only.

- **Phase 2** — KeePassXC SSH-Agent integration: s3c-ssh-agent
  gains ADD_IDENTITY + REMOVE_IDENTITY + REMOVE_ALL_IDENTITIES.
  Touches: s3c-ssh-agent.swift only.

Phase 1 delivers the main UX win: one master pw per session, all
secrets extracted + chip-wrapped up front, per-secret Touch ID from
then on. Phase 2 is the SSH-only cherry on top: unlock KeePassXC
GUI with SSH-Agent enabled → SSH signs skip Touch ID (env/otp
still chip-wrap-gated). TTL is absolute and user-tunable
(`GORILLA_UNLOCK_TTL`) — no runtime probe, no sentinel.

## Verify

1. Reboot. `ls /tmp/s3c-gorilla/` → empty.
2. `ssh foo` → master-pw prompt → **fan-out runs**: blobs appear for every SSH key, every ENV project, every 2FA service. Touch ID fires once for this sign. Next ssh to same host: only Touch ID.
3. `env-gorilla proj -- env` → **no master-pw prompt**, only Touch
   ID (fan-out already extracted env-proj.s3c in step 2).
4. `otp-gorilla svc` → **no master-pw prompt**, only Touch ID.
5. `env-gorilla --paranoid other -- env` → **master-pw prompt**
   despite existing env-other.s3c; no writes to /tmp during
   paranoid call (opt-out works).
6. Wait >7200s with no tool use. `ssh foo` → master-pw prompt again.
7. Use a tool every 30min for 3hr → no re-prompt (activity resets
   timer).
7b. Lock screen (Ctrl-Cmd-Q), wait, unlock with Mac password →
    `ssh foo` → master-pw prompt (screen lock wiped the blob).
7c. Log out and log back in → `ssh foo` → master-pw prompt.
8. **Phase 2 check:** launch KeePassXC GUI, unlock it, enable SSH
   Agent, mark your keys for SSH-agent → `ssh-add -L` lists them
   (via our agent). `ssh foo` in a fresh terminal → **no Touch ID,
   no master pw**. Lock KeePassXC → keys vanish → next ssh falls
   through to Touch ID flow.
9. GUI tool (SourceTree) with KeePassXC unlocked → works
   transparently, no prompt of any kind.
10. Set `GORILLA_UNLOCK_TTL=28800` (8h) → wait >7200s idle → next
    tool call: no master-pw prompt (TTL not yet expired). Wait
    >28800s → master-pw prompt. Confirms tunable TTL works.

## Concerns — resolved

Each open concern below has an explicit resolution. No unresolved
loose ends going into implementation.

### 1. `--paranoid` flag for ssh
**Concern:** the ssh agent is a long-lived daemon; `S3C_PARANOID=1`
set in a shell doesn't reach the agent.

**Resolution:** `--paranoid` applies to `env-gorilla` and
`otp-gorilla` only. For ssh, users who want per-sign master-pw
prompts can disable KeePassXC's SSH Agent push AND manually
`touchid-gorilla wrap-clear` between each ssh invocation. Not a
supported first-class workflow; the unified eager-unified flow
with Touch ID per sign is the intended SSH security model.

### 2. Concurrent tool race on fan-out extraction
**Concern:** two tools running at the same time both try to
bootstrap (fan-out extract) and each prompt master pw.

**Resolution:** wrap the fan-out in a `flock`-acquired lock on
`/tmp/s3c-gorilla/.bootstrap.lock`. First tool acquires, runs
fan-out, releases. Second tool blocks on the lock; when it wakes,
finds its own per-tool blob already exists (from the first tool's
fan-out) → unwraps via Touch ID. One master-pw prompt per session
guaranteed.

### 3. KeePassXC protocol drift (SSH-Agent push)
**Concern:** if future KeePassXC versions change the ADD_IDENTITY
message format, our agent silently misparses.

**Resolution:** our `handleAddIdentity` logs a warning to
`/tmp/s3c-ssh-agent.err.log` whenever it receives an unparseable
ADD_IDENTITY (or an unsupported key type). Returns `SSH_AGENT_FAILURE`
to KeePassXC. Keys we don't understand don't enter our cache. User
sees the warning if something breaks.

### 4. Pushed-keys cache lives in agent RAM
**Concern:** while KeePassXC has pushed keys, a coerced fingerprint
signs without prompting.

**Resolution:** explicitly accepted. User's stated threat model
already accepts that an unlocked KeePassXC GUI + compromised session
= compromised vault. Pushed keys are zeroed on: SIGTERM, screen
lock, REMOVE_ALL_IDENTITIES, and KeePassXC-lock (we subscribe to
both screen-lock and our own SIGTERM). User can disable
KeePassXC's "SSH Agent" integration in KeePassXC settings if even
this is too loose — our agent then never receives pushes and Touch
ID is mandatory for every sign.

### 5. (Removed — obsolete.)
Phase 3 dropped; no AppleScript probe.

### 6. Screen-lock notification reliability
**Concern:** `NSDistributedNotificationCenter` subscription to
`com.apple.screenIsLocked` isn't formally documented API; behavior
across macOS versions varies.

**Resolution:** two belts-and-suspenders:
- Primary: subscribe to `com.apple.screenIsLocked` (works on
  macOS 10.7 through current; battle-tested).
- Backstop: the 7200s TTL still fires regardless of whether the
  screen-lock notification was received. If the notification ever
  stops firing on a future macOS, worst case: blobs persist
  through lock-screens until TTL expires. User can manually
  `touchid-gorilla wrap-clear` if worried.

### 7. Config change after re-install
**Concern:** if user re-runs `install.sh` and changes the prompt
style or SSH mode, the long-running agent still runs with old
config.

**Resolution:** `14-launchagent.sh` bootouts + bootstraps the
LaunchAgent on every install.sh run (via `launchctl bootout` +
`launchctl bootstrap`). Fresh agent process picks up new config.
Also: agent reads `$HOME/.config/s3c-gorilla/config` on each
bootstrap (not just startup) — cheap file read. Config changes
propagate instantly either way.

### 8. (Removed — obsolete.)
Previously covered Mode B behaviour for the ssh agent. With Mode B
gone, there's no separate flow to document.

### 9. (Removed — obsolete.)
Previously covered `GORILLA_UNLOCK_MODE` propagation. The knob is
gone.

### 10. Localization of KeePassXC menu labels for Phase 2 probe
**Concern:** "Lock Database" menu string varies by UI language.

**Resolution:** Phase 0 tries the direct AppleScript command (not
menu-string-dependent) first. Only falls back to System Events
menu inspection if the direct command isn't supported, and in that
case probes by **menu index** rather than string where possible.
Documented in Phase 0's output as "confirmed / fragile / fail".

### 11. `/tmp` survives reboots on macOS
**Concern:** I wrote "macOS sweeps /tmp on reboot" — that was wrong.
macOS cleans `/tmp` via `/etc/periodic/daily/110.clean-tmps` (files
older than 3 days, daily). A reboot alone does NOT clear `/tmp`.
So blobs could carry across reboots and defeat the session-bound
guarantee.

**Resolution:** see Concern #26 for the full fix. Summary: agent's
`RunAtLoad` handler unconditionally wipes `/tmp/s3c-gorilla/`, AND
every CLI tool inline-checks each blob's mtime against
`sysctl -n kern.boottime` before trusting it (defence in depth —
tools may race ahead of agent startup).

### 12. (Removed — obsolete.)
Phase 3 dropped. TTL is a single `GORILLA_UNLOCK_TTL` read from
config; no refresh target, no `refresh-all` subcommand.

### 13. CLI tools can't subscribe to screen-lock — how do they wipe?
**Concern:** `env-gorilla` and `otp-gorilla` are short-lived scripts.
They can't subscribe to `NSDistributedNotificationCenter`.

**Resolution:** the agent (LaunchAgent daemon) is the subscriber. On
`com.apple.screenIsLocked`, it wipes the whole `/tmp/s3c-gorilla/`
dir. Next time any CLI tool runs, it finds no blobs and prompts
master pw. No code changes to env/otp.

### 14. Touch ID re-enrollment kills the SE wrap key
**Concern:** SE key created with `.biometryCurrentSet` is invalidated
by the OS when the user adds/removes fingerprints. All blobs
become undecryptable.

**Resolution:** the unwrap path in `touchid-gorilla` detects the
decrypt failure, distinguishes "user cancelled" (errSecUserCanceled,
exit 1) from "key lost / invalidated" (errSecInvalidKeyData or
similar). On the latter: wipe all blobs in `/tmp/s3c-gorilla/`,
print a one-line notice ("Touch ID enrollment changed — re-enter
master password to re-seed"), return failure. Tools see the failure
and fall through to master-pw prompt. One-time re-seed, then
normal flow resumes.

### 15. LaunchAgent is mandatory for Phase 1
**Concern:** The screen-lock wipe + boot-time stale-blob wipe both
require the agent to be running. User can't opt out of the agent
without losing those wipes.

**Resolution:** `14-launchagent.sh` unconditionally installs and
bootstraps the LaunchAgent. No opt-out prompt. If the user truly
doesn't want a daemon, they can `launchctl bootout` it manually —
they accept that blobs then only wipe via the 7200s TTL and
`/tmp` daily cleanup. Documented in the post-install summary.

### 16. (Removed — obsolete.)
With Phase 3 dropped, `s3c-ssh-agent` no longer runs osascript,
so it no longer needs Accessibility / Automation permission.
`15-permissions.sh` still grants Terminal's access for any manual
osascript usage (e.g. dialog-mode master-pw prompt), but the
LaunchAgent-specific surprise-dialog scenario is gone.

### 17. `/tmp/s3c-gorilla/` needs hardened permissions (0700 / 0600)
**Concern:** `/tmp` is world-readable and world-writable (mode `1777`
with sticky bit). Without explicit permissions on our own
subdirectory and files, other users on the Mac could list the
contents of `/tmp/s3c-gorilla/`, read metadata, and — if we
forgot the file mode — actually read the encrypted blob bytes.
The blobs are SE-encrypted so content reads are useless without
the chip, but metadata (filenames = which tools / services are in
use) is still an information leak, and defense-in-depth means we
don't rely solely on the SE encryption.

**Resolution:** enforce modes at every creation path — existing code
in `touchid-gorilla.swift` does this, but the plan calls it out
explicitly so it's not accidentally dropped during refactor / H1-H4
rewrites:

- `/tmp/s3c-gorilla/` created with mode **0700**:
  ```swift
  try FileManager.default.createDirectory(
      atPath: blobDir,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
  ```
- Every `.s3c` file written with mode **0600**:
  ```swift
  FileManager.default.createFile(
      atPath: tmp, contents: data,
      attributes: [.posixPermissions: 0o600])
  ```
- Atomic write uses a `.tmp` file (mode 0600) → `rename()` to final
  path. `rename` preserves permissions, so the final file is also
  0600.
- Same pattern for `s3c-ssh-agent`:
  - `~/.s3c-gorilla/` created with mode **0700**.
  - `agent.sock` chmod'd to **0600** right after `bind()`.
  - `~/.s3c-gorilla/keys.json.s3c` written with mode **0600** AND
    chip-wrapped (Concern #42 — mode 0600 alone is insufficient
    because same-uid processes still read the metadata; the
    registry names every SSH key, ENV project, and TOTP service
    in the vault and maps your infrastructure).

Validated in section 4: "directory is mode 0700" + "every `.s3c`
file is mode 0600" + "agent socket is mode 0600". Non-negotiable
before calling implementation done.

### 18. EnableSecureEventInput process-wide + crash-leaks-the-lock
**Concern:** `EnableSecureEventInput()` grabs the system input lock
process-wide. If the `touchid-gorilla master-prompt` process crashes
while holding it, other apps can lose keyboard input. `defer` doesn't
run on SIGKILL or hard crashes.

**Resolution (defense in depth, no fork):**
- **Minimize hold window** — only wrap the actual `read()` /
  `getline()` call in Enable/Disable, not the whole program lifetime.
  Microseconds of exposure, not seconds.
- **Signal handlers** — install handlers for SIGINT, SIGTERM, SIGSEGV,
  SIGBUS, SIGABRT, SIGPIPE that call `DisableSecureEventInput()`
  before re-raising / exiting. `DisableSecureEventInput` is a simple
  refcount decrement, safe from a signal handler.
- **No fork-for-read.** Earlier draft proposed spawning a child just
  for the `read()`. Dropped: adding an IPC hop means the password
  bytes cross a process boundary, which is strictly more surface
  than what we save. macOS releases SEI on process death anyway —
  combining narrow-scope Enable/Disable with comprehensive signal
  handlers covers the crash case without the IPC.
- **Practical vs formal async-signal-safety (N9).**
  `DisableSecureEventInput` is a refcount decrement that ultimately
  calls into WindowServer IPC. Apple does NOT formally list it as
  async-signal-safe. In practice it behaves safely from a signal
  handler (no malloc, no locks held across the call on any macOS
  we've tested), and the worst-case failure is "SEI stays locked
  until the kernel reaps the process on exit" — which is the
  same behaviour we'd get with no handler at all. Document this
  honestly: "practically safe; no worse than leaving SEI locked
  on crash."
- **Handler-induced hang caveat.** One subtlety: if the handler
  itself deadlocks on WindowServer IPC (process is in a weird
  state when the signal fires), a clean crash becomes a silent
  hang. The SEI lock gets reclaimed only when something external
  kills the process. In practice this is near-theoretical — the
  Enable/Disable window wraps only the `read()` syscall, so the
  time the handler can fire while holding interesting state is
  milliseconds — but document it so we're not claiming "always
  better than no handler". A `setitimer(ITIMER_REAL, 1s)` inside
  the handler installs a SIGALRM backstop that force-exits if
  `DisableSecureEventInput` itself hangs, converting a hang back
  into a crash.

### 19. flock deadlock if holder hangs
**Concern:** `flock /tmp/s3c-gorilla/.bootstrap.lock` with no timeout —
if the holding process hangs (not crashes; hangs), other tools block
forever waiting on the lock.

Note: kernel auto-releases flock on process death (crash, SIGKILL).
Only live-hangs are the real failure mode.

**Resolution:** acquire with a 30-second timeout. Bash callers use
`flock -w 30`; Swift callers use `fcntl(F_SETLK)` with a polling
loop. On timeout, fail with a clear error:
```
bootstrap lock held by another process (pid 12345, hung for 30s).
Try: touchid-gorilla wrap-clear
Then: retry your command.
```

### 20. Pushed SSH keys lifetime after KeePassXC crash
**Concern:** pushed keys in agent RAM are zeroed on SIGTERM,
REMOVE_ALL_IDENTITIES, and screen lock. But if KeePassXC **crashes**
(doesn't send REMOVE_ALL), its keys sit in our agent RAM with no
Touch ID gate until next reboot / logout / screen lock.

**Resolution (two layers, tightened):**
- **PID heartbeat** — agent timer every **10 seconds** (was 30s)
  runs `pgrep -x KeePassXC`. If not running → zero the pushed-keys
  cache. Worst-case Touch-ID-free window after a KeePassXC crash
  shrinks from 30s → 10s.
- **Max age per key** — any pushed key older than **5 minutes**
  (was 30min) without a fresh ADD_IDENTITY for it gets dropped.
  KeePassXC re-pushes on every database unlock — legitimate keys
  refresh naturally; the short cap costs nothing in normal use
  and dramatically limits the rogue-push dwell time. User can
  override via `GORILLA_PUSHED_KEY_MAX_AGE_SEC` in config if they
  want the looser 30-min behaviour for some reason (not
  advertised).

Either firing clears stale keys. Both together catch crashes +
re-pushes.

### 21. (Removed — obsolete.)
Phase 3 dropped. No osascript probe of KeePassXC state, so no
auto-launch risk.

### 22. CommonCrypto RSA deprecation risk
**Concern:** H2 relies on `CCRSACryptorCreateFromData` from
CommonCrypto. Apple has soft-deprecated CommonCrypto in favor of
CryptoKit + Security framework. The RSA APIs still compile and work
on current macOS versions (14/15 per last confirmed data), but
future removal is possible.

**Resolution:**
- Plan stays on CommonCrypto for H2 (it works, it's audited).
- **Runtime** `dlopen` + `dlsym` is the actual gate, NOT `#if
  canImport`. `#if canImport` is a *compile-time* check — if the
  framework is present when we build but removed via a future
  macOS update, the binary would crash on first RSA sign. We need
  a runtime guard:
  ```swift
  private let ccRSA: RSACreateFn? = {
      // Bare name — loader resolves through the dyld shared cache.
      // On Apple Silicon the .dylib file is not on disk (the
      // framework lives only in the cache), so a hardcoded
      // /usr/lib/... path fails. Bare name is the portable form.
      guard let h = dlopen("libcommonCrypto.dylib", RTLD_NOW)
          else { return nil }
      guard let sym = dlsym(h, "CCRSACryptorCreateFromData")
          else { return nil }
      return unsafeBitCast(sym, to: RSACreateFn.self)
  }()
  ```
  If `ccRSA == nil` at call time → use the BigInt / `modPow` /
  `convertOpenSSHRSAToPKCS1` fallback. No compile-time magic —
  the failure is caught when the binary runs.
- Keep the BigInt + `modPow` code as a **dormant runtime fallback**
  rather than deleting it outright. H2 revised: don't delete,
  quarantine. Switch is automatic based on `dlsym` result.
- If CommonCrypto is **available but rejects inputs** (non-standard
  exponent etc.), still fail-closed (return `SSH_AGENT_FAILURE`).
  Fallback only fires when the framework itself is missing, not
  when it disagrees with our key data.

### 23. Fan-out blast radius — all secrets simultaneously in heap
**Concern:** during `touchid-gorilla fan-out`, every SSH key + every
env + every TOTP secret in the vault is simultaneously live in one
process's heap, and the bulk XML buffer contains all of them in
plaintext for the duration of the parse + wrap loop (~1-2s). H1's
`memset` only runs at function exit — it does NOT protect against:

- **Swap-out under memory pressure.** APFS swap is encrypted at
  rest, but keys live in memory while active; a page-out window
  copies plaintext to swap until the page is reused.
- **Core dumps from an unhandled signal** (SIGSEGV/SIGBUS/SIGILL/
  SIGFPE/SIGABRT) — a dump captures the full heap, every secret
  included.
- **Debugger attach.** Hardened runtime (H3) blocks `task_for_pid`
  for non-entitled processes but isn't absolute: same-uid
  processes with the right entitlements (or a compromised dev
  signing cert) could still attach.
- **Same-uid memory inspection.** Any process running as the same
  user can in principle walk process memory via
  `proc_regionfilename` + `vm_read` with the right entitlements,
  or via `lldb` where SIP doesn't block it.

**Resolution — three runtime mitigations + honest threat-model note:**

- **`setrlimit(RLIMIT_CORE, {0, 0})`** on entry to
  `touchid-gorilla fan-out`, `s3c-ssh-agent main()`, and every
  Swift binary that holds plaintext secrets even briefly
  (`env-gorilla`, `otp-gorilla` wrappers exec into Swift, so the
  rlimit inherits). Prevents the kernel from writing a core dump
  regardless of which signal kills us. Applied before any secret
  is extracted:
  ```swift
  var rl = rlimit(rlim_cur: 0, rlim_max: 0)
  setrlimit(RLIMIT_CORE, &rl)   // call before first secret read
  ```

- **`mlock()` on the bulk XML buffer only** (90/5 rule — Concern
  #27). The XML buffer is the one that matters: it briefly holds
  *every* secret in the vault at once (~500ms during parse). Worth
  the complexity. Per-entry secrets (one SSH key, one .env, one
  TOTP seed) are short-lived and held one-at-a-time — `mlock()` on
  each buys little, and Swift's `Data` with explicit `memset` on
  release is 90% of the value at 5% of the cost.

  **Bulk XML buffer — mmap+mlock+zero (no SecretBuf type):**
  ```swift
  // One specialized allocation for this one buffer, inline.
  let MLOCK_BUDGET: size_t = 32 * 1024 * 1024   // 32 MiB hard cap
  let xmlPtr = mmap(nil, MLOCK_BUDGET, PROT_READ|PROT_WRITE,
                    MAP_ANON|MAP_PRIVATE, -1, 0)!
  guard mlock(xmlPtr, MLOCK_BUDGET) == 0 else {
      munmap(xmlPtr, MLOCK_BUDGET)
      fatalError("mlock failed — aborting fan-out")
  }
  defer {
      memset(xmlPtr, 0, MLOCK_BUDGET)
      munlock(xmlPtr, MLOCK_BUDGET)
      munmap(xmlPtr, MLOCK_BUDGET)
  }
  // stream keepassxc-cli stdout into xmlPtr[..written]; parse in place.
  ```
  `mlock` failure is fatal (fail-closed, Concern #23 / N3 rule).

  **Per-entry secrets — plain `Data` + wipe helper:**
  ```swift
  // One helper. Five lines. That's the whole regime.
  func wipe(_ d: inout Data) {
      d.withUnsafeMutableBytes { buf in
          guard let base = buf.baseAddress else { return }
          memset(base, 0, buf.count)
      }
      d.removeAll(keepingCapacity: false)
  }
  // Caller pattern:
  var keyBytes = extractOneSSHKey(from: xmlPtr, entry: e)
  defer { wipe(&keyBytes) }
  chipWrap(keyBytes, to: blobPath)
  ```
  No raw-pointer wrapper type, no `// SECRET-NECROPSY` annotation,
  no lint script. We lose theoretical CoW-ghost protection; in
  practice a grep-based lint wasn't going to catch those ghosts
  anyway, and the threat model already concedes same-uid
  debugger-attach sees everything.

  **Explicit 32 MiB ceiling on the mlocked region.** User's
  expected vault is small, but we defend against heavy vaults
  (large SSH keys, base64'd binary attachments bloating the XML).
  On fan-out entry, before the `mmap`:
  ```swift
  let MLOCK_BUDGET: size_t = 32 * 1024 * 1024   // 32 MiB hard cap
  var rl = rlimit()
  getrlimit(RLIMIT_MEMLOCK, &rl)
  guard rl.rlim_cur >= MLOCK_BUDGET else {
      fatalError("RLIMIT_MEMLOCK (\(rl.rlim_cur)) < 32 MiB budget — refusing fan-out")
  }
  ```
  If `keepassxc-cli` streams more than 32 MiB into our pre-sized
  buffer, we fail-closed on the first over-budget chunk with
  "vault XML export > 32 MiB — aborting"; nothing leaks to disk
  (Concern #23 / N3). Per-entry secrets are bounded by their
  slice of the XML and by each key's on-disk footprint; no
  separate mlock budget needed — they use plain `Data`.

  **RLIMIT_MEMLOCK recovery path (N2).** macOS LaunchAgent default
  `RLIMIT_MEMLOCK` can be well below 32 MiB. If our precheck
  fails, the user must have a fix — not just a cryptic abort.
  Mitigation delivered as two stacked defences:
  1. `14-launchagent.sh` embeds `SoftResourceLimits` +
     `HardResourceLimits` in the agent's plist, requesting a
     memlock cap that comfortably covers our budget:
     ```xml
     <key>SoftResourceLimits</key>
     <dict>
         <key>MemoryLock</key>
         <integer>50331648</integer>   <!-- 48 MiB: 32 MiB budget + 16 MiB slack -->
     </dict>
     <key>HardResourceLimits</key>
     <dict>
         <key>MemoryLock</key>
         <integer>50331648</integer>
     </dict>
     ```
     `launchctl bootstrap` applies this on install, no user
     action needed. CLI tools (`env-gorilla`, `otp-gorilla`,
     `touchid-gorilla fan-out`) inherit the calling terminal's
     limits — which on macOS default to "unlimited" for
     MemoryLock under Terminal.app — so the cap only matters for
     the agent.
  2. Tool precheck error message includes a concrete remedy:
     ```
     RLIMIT_MEMLOCK (X bytes) below 32 MiB budget.
       Agent:  sudo launchctl limit memlock 50331648 50331648
               then relaunch the agent: launchctl kickstart -k gui/$UID/com.slav-it.s3c-ssh-agent
       Shell:  ulimit -l 49152    (units: KiB)
     ```
     User sees a one-line fix, not a dead end.
  Validation row: fresh install on a Mac with
  `launchctl limit memlock` set to 4 MiB → agent's plist override
  restores 48 MiB → fan-out succeeds.

  **XML streaming — pre-allocate, no realloc (N3).**
  `keepassxc-cli` offers no pre-size API, and `realloc`-on-demand
  would mean copying plaintext across allocations (+
  `memset`+`munlock`+`munmap` of the old region) mid-stream —
  ugly and error-prone. Simpler: the `mmap`+`mlock` above is
  sized at `MLOCK_BUDGET` once, and we stream into it; "read
  past buffer end" is the fail signal.
  ```swift
  var written = 0
  while let chunk = readNextChunk() {   // from keepassxc-cli stdout
      guard written + chunk.count <= MLOCK_BUDGET else {
          // defer already zeroes + munlocks + munmaps xmlPtr
          fatalError("vault XML export > 32 MiB budget — aborting")
      }
      memcpy(xmlPtr + written, chunk.baseAddress, chunk.count)
      written += chunk.count
  }
  // parse xmlPtr[..written]; extract per-entry bytes into Data;
  // chip-wrap each; wipe(&data) per the per-entry helper above.
  ```
  No realloc, no copy-between-buffers, no partial-plaintext
  windows during growth. The unused tail of the 32 MiB
  allocation is already zeroed by `mmap(MAP_ANON)`. Phase 0
  probe #4's 15 MiB synthetic attachment → `written + chunk > BUDGET`
  at the first chunk that pushes past 32 MiB → clean abort,
  nothing leaked to disk first.

  If `mlock` fails with `EAGAIN`/`ENOMEM`, fail-closed (abort
  fan-out, print a clear error) rather than silently fall back to
  swappable memory.

- **Zero + release the bulk XML buffer immediately after parse.**
  `XMLParser.parse()` streams, so the bulk buffer is zeroed and
  `munlock`+`munmap`-ed before the per-entry chip-wrap loop starts.
  Narrows the "everything simultaneously plaintext" window from
  "parse + wrap" (~1-2s) to "parse only" (~100-500ms). Per-entry
  `Data` buffers live only until each chip-wrap completes, then
  get `wipe(&d)` called via `defer`.

- **Document honestly in the threat model.** Add a paragraph in
  section "## Context" and in the `99-done.sh` post-install
  cheatsheet:

  > *For ~100-500ms every session start, every vault secret is
  > simultaneously live in the `touchid-gorilla fan-out` process's
  > locked memory. Core dumps are disabled and pages are
  > unswappable, but any attacker with code execution as your uid
  > during that window sees every secret. After fan-out returns,
  > only per-secret `.s3c` files remain — each requires Touch ID
  > to decrypt. The master password itself is never stored on
  > disk and is zeroed from memory before fan-out returns.*

  Not hidden in a concern list — surfaced up front so the user
  knows exactly what the tradeoff is vs the "master pw never
  stored" headline.

Checklist additions (already folded into Section 1 + Section 4
tables): "Concern #23 — RLIMIT_CORE + mlock bulk XML buffer +
early-zero + threat-model note" implementation row; validation
rows for `getrlimit(RLIMIT_CORE)` returning 0, one `mlock(` call
site (XML buffer) plus `wipe(` helper + callers in `src/`,
simulated SIGSEGV during fan-out producing no `/cores/core.<pid>`
file, and bulk XML buffer freed before the per-entry loop
(instrumented log line).

### 24. `keepassxc-cli export --format xml` is an unverified black box
**Concern:** our primary fan-out path depends on
`keepassxc-cli export --format xml` behaviour that we haven't
directly verified on a real vault: does it emit on stdout or
require `-o <file>`? If `-o`, does it create a tempfile first?
Does it inline attachments as base64 under `<Meta><Binaries>`, or
does the current version emit raw-bytes-inline? How does it
behave on large attachments? If the export ever writes secrets
to disk — even transiently — that breaks our threat model
(secrets on disk outside our SE-encrypted `.s3c`).

**Resolution:** Phase 0 (see Implementation phases) is a
dedicated research gate that runs before Phase 1. It probes all
five behaviours on a disposable test kdbx and produces a binary
verdict: **GREEN** (bulk XML stream viable) or **RED** (fall
back to parallel `keepassxc-cli` workers per §2a path 2). Phase 1
implementation branches on this result. No speculative code.
**Phase 0 completed 2026-04-24 against keepassxc-cli 2.7.12 →
verdict GREEN.** Findings applied in-plan (no separate verdict
markdown — that was bloat).

Acceptance bar: bulk-XML path may be adopted only if
keepassxc-cli (a) streams to stdout or `/dev/stdout` without any
intermediate tempfile touching disk, AND (b) emits the
`<Meta><Binaries>` + `<Binary Ref="..."/>` encoding our two-pass
parser expects, AND (c) degrades gracefully on oversized
attachments (errors out or streams; does not silently truncate).
Anything else → bulk-XML is RED, parallel-workers is primary.

### 25. `.session-valid` sentinel race under concurrent tool-side recovery
**Concern (from external review):** §2c as originally written let
every tool "recover" (wipe + re-fan-out) if it saw the sentinel
absent + blobs present. But the tool-side recovery path didn't
acquire the bootstrap flock. Race:

```
T0  A takes flock, starts fan-out, writes 20 of 75 blobs
T1  B invoked, sees .session-valid absent + blobs present
T2  B calls wrap-clear (no flock!) — wipes dir
T3  A is still renaming .s3c.tmp → .s3c (dir just got nuked)
T4  A writes .session-valid
Final state: .session-valid + partial blobs + phantom renames.
             The sentinel is lying.
```

**Resolution (simpler, safer):** **only `touchid-gorilla fan-out`
ever mutates `/tmp/s3c-gorilla/` contents.** Tools never wipe,
never recover, never `wrap-clear` on their own. Tool decision
tree becomes:

```
if .session-valid present:
    → proceed to unwrap
elif .session-valid absent AND any .s3c or .s3c.tmp exists:
    → invoke `touchid-gorilla fan-out` (takes flock → wipes
      under lock → fans out → writes .session-valid → releases)
else:
    → invoke `touchid-gorilla fan-out`
```

The flock inside fan-out serializes the wipe + write set. A
late-arrival tool during fan-out A blocks on the flock, then
sees `.session-valid` when the lock releases and skips its own
fan-out invocation. Screen-lock wipe / logout SIGTERM /
`wrap-clear` subcommand (which wipe the whole dir, no
partial-state risk) also acquire the same flock before wiping.
Updated §2c reflects this.

### 26. Boot-time wipe via mtime-vs-boottime is racy and overcomplicated
**Concern (from external review):** two problems with the
original design:
- **Hibernate / sleep / clock weirdness.** `mtime > kern.boottime`
  doesn't strictly imply "created this session" on a machine
  that's been hibernated, time-synced, or had its clock touched.
- **LaunchAgent ordering.** macOS does not order the agent's
  `RunAtLoad` handler against Dock / Terminal startup. User
  logs in → Dock appears → user hits Cmd-T → `ssh` → agent
  hasn't yet run its wipe. Tool sees pre-boot blobs and happily
  decrypts them with Touch ID. Session-boundary guarantee broken.

**Resolution — two-layer defence:**
1. **Agent `RunAtLoad` unconditionally wipes** `/tmp/s3c-gorilla/`
   — no mtime logic. The cost is one extra fan-out on login,
   which is the intended fresh-session behaviour anyway.
2. **Every CLI tool inline-checks each blob's mtime vs
   `sysctl -n kern.boottime` before trusting it.** Pre-boot
   blobs are treated as absent → invoke `touchid-gorilla fan-out`.
   Belt + suspenders: tools can't wait for the agent to win the
   startup race.

The mtime-vs-boottime check is kept on the tool side (not just
on the agent side) precisely because the external review flagged
the LaunchAgent race. It's a weaker check than the unconditional
wipe (hibernate/clock drift caveat noted), but it's the fastest
defence a tool can run inline without waiting for the agent. In
the pathological clock-touched case, worst outcome is an extra
fan-out — never a stale-blob decrypt.

Implementation notes:
- Tool inline check: open the blob, `fstat()`, compare `st_mtime`
  to boot time. If `st_mtime < boottime`, unlink + re-fan-out.
- Agent `RunAtLoad`: one `rm -rf /tmp/s3c-gorilla/*` under the
  bootstrap flock (Concern #25). No per-file logic.
- §2c crash-rollback is unaffected; this concern is purely about
  the reboot boundary.

### 27. Swift `Data` zeroing is weaker than H1 implies (CoW) — 90/5 rule
**Concern (external review):** `Data` is CoW-backed by a reference
type under ARC. `withUnsafeMutableBytes { memset(base, 0, n) }`
zeroes the current buffer — but a `let copy = secretData` earlier
in the call chain lives on with its own independent backing.
Bridging to `String` or passing to some Foundation APIs can
trigger a transparent CoW copy and leave a ghost.

**Resolution — 90/5 rule: mlock only where it matters.**
Previous drafts of this concern escalated through two progressively
heavier designs — first a full "no `Data`, `SecretBuf` everywhere"
regime with `// SECRET-NECROPSY` annotations and a lint script,
then a "SecretBuf for XML + per-entry buffer, hygiene rules for the
rest" compromise. Both were fighting Swift hard for a gain that
H3 (hardened runtime) + Concern #23's `RLIMIT_CORE=0` + #23's
XML-buffer `mlock` already bound. The threat model explicitly
concedes that a same-uid attacker with debugger / `vm_read`
entitlements sees everything anyway.

**What we actually ship:**
- **`mlock` on the bulk XML buffer only.** That one buffer is the
  prize: it briefly holds every vault secret at once for ~500ms
  during parse. Worth the `mmap`+`mlock`+zero-on-release dance.
  Mechanics in Concern #23 above.
- **Per-entry secrets use plain `Data` + a five-line `wipe()`
  helper.** One helper function, called via `defer` at the end of
  each per-entry chip-wrap. Unswappable-ish for the brief moment
  the secret is live (pages aren't pinned — accepted), zeroed on
  release. This is the 90% of practical value for 5% of the
  complexity:
  ```swift
  func wipe(_ d: inout Data) {
      d.withUnsafeMutableBytes { buf in
          guard let base = buf.baseAddress else { return }
          memset(base, 0, buf.count)
      }
      d.removeAll(keepingCapacity: false)
  }
  ```
- **No raw-pointer `SecretBuf` type.** The XML buffer is one
  inline `mmap`/`mlock`/`defer` block, no type wrapper needed.
- **No `// SECRET-NECROPSY` annotations, no lint script.** A
  grep-based lint can't understand Swift semantics and would be
  either ignored or a lie. CoW ghosts are a theoretical gap the
  threat model already accepts.
- **One-paragraph dev note** in `src/README-SECRETS.md`: "For
  secret bytes, use `Data` with a `defer { wipe(&d) }` at the
  point of last use. The bulk XML buffer is a special case —
  see fan-out code." That's it.

If a future audit finds a concrete CoW leak we care about, we
revisit — but not speculatively.

### 28. flock lockfile creation + dir-wipe race
**Concern (external review):** `flock -w 30 /tmp/s3c-gorilla/.bootstrap.lock`
requires the file to exist. But screen-lock / boot / `wrap-clear`
wipes the whole dir — including the lockfile. Two processes
concurrently racing to re-create `dir + lockfile` are themselves
unserialized.

**Resolution:**
- **Agent re-creates** `/tmp/s3c-gorilla/` (mode 0700) and an
  empty `.bootstrap.lock` at the END of every wipe handler
  (RunAtLoad, screen-lock, logout SIGTERM, wrap-clear). This is
  the primary guarantee.
- **CLI tools idempotently ensure** the dir + lockfile exist
  before the first `flock`:
  ```bash
  ensure_lockfile() {
      mkdir -p /tmp/s3c-gorilla && chmod 700 /tmp/s3c-gorilla
      : >> /tmp/s3c-gorilla/.bootstrap.lock  # create if absent, no-op if present
  }
  ensure_lockfile
  exec 9< /tmp/s3c-gorilla/.bootstrap.lock
  flock -w 30 9 || { err "bootstrap lock stuck"; exit 1; }
  ```
  `: >>` (append-redirect of empty) creates the file without
  truncating. `mkdir -p` is race-safe. Multiple tools racing
  result in the same empty lockfile; content doesn't matter
  (`flock` uses the inode, not content).
- Swift callers (`touchid-gorilla fan-out`, `s3c-ssh-agent`)
  mirror the same logic via `mkdir()` + `open(O_CREAT|O_WRONLY)`
  on the lockfile path before calling `fcntl(F_SETLK)`.
- Validation: simulate `rm -rf /tmp/s3c-gorilla/` with two tools
  racing behind; both must complete successfully, neither must
  deadlock, and the final directory must have mode 0700.

### 29. `utimes()` vs TTL-check race
**Concern (external review):** Tool A reads blob mtime (7100s old,
within TTL), begins unwrap. Tool B reads mtime (say 7205s if the
clock ticked or A's clock source differs), wipes. A's unwrap
fails mid-flight. Not fatal — A can re-fan-out — but the error
path must not scare the user.

**Resolution:**
- **Clean error-path fall-through.** Tool unwrap errors are
  classified; any failure that could plausibly be "blob was wiped
  under us" (ENOENT, errSecInvalidKeyData, errSecItemNotFound)
  triggers a silent re-invocation of `touchid-gorilla fan-out`
  followed by a retry of the unwrap — no stderr noise, no scary
  dialog. Persistent failures (2nd attempt also fails) surface a
  real error.
- **Do not race-fix via flock on the unwrap path.** Holding the
  bootstrap flock around every unwrap would serialize all tool
  calls across the system, defeating the fan-out performance win.
  The race is harmless with a clean retry; we optimize for the
  common case and accept the rare retry.
- **`utimes()` stays outside the flock.** Only the fan-out write
  set is flock-gated; `utimes()` on an existing blob is atomic at
  the VFS level and crash-safe.
- Validation row: synthetic race (tool A sleeps 100ms mid-unwrap
  while tool B triggers screen-lock wipe) → A's wrapper code
  performs one transparent retry and succeeds; stderr is clean.

### 30. keepassxc-cli on iCloud-evicted kdbx
**Concern (external review):** If the kdbx lives in iCloud Drive
with "Optimize Mac Storage" on, the file may be *evicted* — the
placeholder shows up in `ls` but opening it returns a generic
"file not found" or blocks for a long time. Step 09's picker
needs to detect this and guide the user.

**Resolution:** `09-database.sh` adds an eviction probe for each
candidate kdbx:
- Check the `com.apple.cloud.evict` xattr via `xattr -p
  com.apple.cloud.evict <path> 2>/dev/null`. Presence indicates
  an evicted placeholder.
- Belt: attempt a 4-byte read with a 2s timeout. macOS does NOT
  ship `timeout(1)` (it's GNU coreutils = `gtimeout` via Homebrew,
  N5). Use a shell-native pattern instead:
  ```bash
  ( head -c 4 "$path" >/dev/null ) & pid=$!
  ( sleep 2 && kill -TERM $pid 2>/dev/null ) & killer=$!
  wait $pid 2>/dev/null; rc=$?
  kill -TERM $killer 2>/dev/null
  [[ $rc -eq 0 ]] || evicted=1
  ```
  Same semantics as `timeout 2 head -c 4`, no brew dependency.
  If the read blocks past 2s or exits non-zero, assume evicted.
- If evicted, print:
  ```
  KeePassXC database is stored in iCloud but not downloaded
  locally (Optimize Mac Storage is evicting it).

    Path: <full path>

  Open KeePassXC in Finder once to force iCloud to materialize
  the file, then re-run `src/install.sh`. Or disable "Optimize Mac
  Storage" in System Settings → Apple Account → iCloud Drive.

  Skip for now? [y/N]
  ```
- Also skip such paths in the picker "1 match / 2+ matches"
  decision — evicted paths are not auto-selected.
- Runtime (fan-out) check: the same eviction probe runs before
  each `keepassxc-cli` invocation; on evict-detected, surface the
  same "open KeePassXC in Finder first" message via
  `osascript display dialog` (so GUI tools like SourceTree get a
  readable error).

### 31. `otpauth://` URI parsing must handle all params
**Concern (external review):** §2a's "extract `secret=`" is not
enough. Services that use `digits=8`, `period=60`, or
`algorithm=SHA256`/`SHA512` produce wrong codes if we default to
6/30/SHA1. Also `issuer=` is needed for display (and to
distinguish two entries with the same account name).

**Resolution:** store the entire `otpauth://` URI as the `.s3c`
blob payload (not just the secret). `otp-gorilla` parses at
unwrap time:
```swift
struct TOTPParams {
    let secret: Data          // base32-decoded
    let digits: Int           // default 6
    let period: Int           // default 30 (seconds)
    let algorithm: HashAlg    // default .sha1
    let issuer: String?
    let account: String?
}
func parseOtpauth(_ uri: String) -> TOTPParams? { ... }
```
- Reject malformed URIs (missing `secret`, invalid base32, unknown
  algorithm) with a clear error listing the offending entry so
  the user can fix it in KeePassXC.
- Full RFC 6238 compliance for the code computation (parametric
  digits / period / algorithm).
- Chip-wrap the full URI — at fan-out time we don't know which
  params matter, and the URI is compact (tens of bytes to low
  hundreds).
- Validation: synthetic KeePassXC entries with `digits=8`,
  `period=60`, `algorithm=SHA512` produce codes that
  byte-identical-match `oathtool` (or equivalent reference) for a
  given `steam-guard`-style test vector.

### 32. (Removed — obsolete.)
Phase 3 dropped. No per-tool osascript, no agent poll, no
sentinel, no clock-jump edge case. TTL is absolute and tunable
via `GORILLA_UNLOCK_TTL`.

### 33. CommonCrypto RSA padding + SHA variants (byte-identical to ssh-keygen)
**Concern (external review):** SSH RSA signing uses three
algorithms across modern servers: `ssh-rsa` (SHA-1),
`rsa-sha2-256`, `rsa-sha2-512`, all with PKCS#1 v1.5 padding.
`CCRSACryptorSign` takes padding + digest params separately —
easy to produce a signature with the wrong hash-OID DER prefix
that `sshd` rejects with a generic "signature verification
failed". Miserable to debug from the client side.

**Resolution — verify wiring before shipping H2:**
- Implement all three paths: SHA-1 (for legacy `ssh-rsa`),
  SHA-256, SHA-512. Explicitly select padding `ccPKCS1Padding`
  plus the matching `digest` parameter in `CCRSACryptorSign`.
  Reference: Apple's own sample + `man CCRSACryptor`.
- **Byte-identical test harness** during Phase 1 impl: for a
  known test RSA key, sign the same message via our
  CommonCrypto path AND via `ssh-keygen -Y sign -f <key> -n
  test`, compare the raw signature bytes. Repeat for all three
  hash algorithms. Zero byte diff → H2 declared done for RSA.
- Repeat against a real `sshd` with a test account: `ssh
  test@host 'echo ok'` must succeed with each negotiated
  algorithm. Server-side `sshd -d` logs inspected to confirm
  the algorithm used (matches our intention).
- If the byte-identical test fails, fall back to the BigInt
  dormant path (Concern #22) for that specific algorithm; do NOT
  ship broken CommonCrypto wiring.
- Validation rows: three byte-identical-to-ssh-keygen checks,
  three live-ssh checks.

### 34. `set -e` + `return` in sourced step files
**Concern (external review):** `src/setup.sh` sources 15 numbered
step files. Under `set -e`, any non-zero exit from a sourced file
propagates to the orchestrator. A careless `[[ condition ]] &&
do_thing` on the last line of a step file (evaluates to 0/1) can
return non-zero → orchestrator exits mid-install with no
indication of which step died.

**Resolution — explicit-failure convention:**
- Every step file under `src/setup/` MUST end with `true` (or
  `:`), guaranteeing a clean zero exit unless an earlier
  explicit error triggers `exit`/`return 1`.
- Orchestrator sources each file with explicit error handling:
  ```bash
  for step in "$SCRIPT_DIR/src/setup/"[0-9]*.sh; do
      if ! source "$step"; then
          err "step failed: $(basename "$step")"
          exit 1
      fi
  done
  ```
  Converts implicit propagation into a named failure.
- Doc line at the top of `00-common.sh` stating the convention so
  future contributors can't miss it.
- Linter row: `./scripts/lint.sh` checks that every
  `src/setup/[0-9]*.sh` file ends with `true` or `:` as its final
  non-comment line.

### 35. Numbered glob sort is lexicographic, not numeric
**Concern (external review):** `[0-9]*.sh` sorts `10-foo.sh`
before `9-foo.sh`. Fine today at 00-15 (two-digit padded), but
fragile the moment someone drops in `9a-helper.sh` or forgets
the zero pad.

**Resolution:**
- **Hard convention:** every numbered step file uses a two-digit
  pad (`09-`, not `9-`). Documented in `src/setup/README` (dev
  doc) and `00-common.sh` header comment.
- **Lint check:** `./scripts/lint.sh` asserts every file in
  `src/setup/` matching `[0-9]*.sh` has exactly two leading
  digits followed by `-`. Files like `9a-foo.sh` or
  `5-hello.sh` fail lint.
- **Runtime safety:** orchestrator glob is augmented with an
  explicit numeric sort. BSD `sort` on macOS has had `-V` for a
  while (Ventura+), but CI or older systems may not; probe in
  `00-common.sh` and pick the right sorter (N6):
  ```bash
  # in 00-common.sh
  if printf '10\n9\n' | sort -V 2>/dev/null | head -1 | grep -q '^9$'; then
      SETUP_SORT='sort -V'
  else
      # Fallback: zero-padded lexical sort works because we
      # enforce two-digit padding via lint (see above).
      SETUP_SORT='sort'
  fi
  ```
  Then the orchestrator:
  ```bash
  while IFS= read -r step; do
      source "$step"
  done < <(printf '%s\n' "$SCRIPT_DIR/src/setup/"[0-9]*.sh | eval "$SETUP_SORT")
  ```
  `sort -V` handles mixed widths correctly when available; on
  systems without it, the two-digit-pad convention (enforced by
  lint) keeps plain lexical `sort` correct.

### 36. `terminal-notifier` is maintenance-only; consider `alerter`
**Concern (external review):** `terminal-notifier` is effectively
abandoned and has had broken notifications on newer macOS before.

**Resolution:**
- Primary: keep `terminal-notifier` since it's still the most
  widely deployed option, **but pin a known-working version**.
  `01-keepassxc.sh` installs via
  `brew install terminal-notifier` without a version lock;
  update to a pinned tap or explicit version check after install
  (`terminal-notifier -h | head -1` reports version; refuse to
  proceed below a known-good minimum).
- Fallback option: `alerter`
  (https://github.com/vjeantet/alerter) — drop-in for the
  common case, actively maintained. Documented in
  `plan/NOTIFIER-FALLBACK.md` (dev-only); install.sh auto-swaps
  to `alerter` if a `terminal-notifier` self-test fails (runs a
  test notification during `15-permissions.sh` and checks exit
  code + a visible toast prompt).
- Runtime: `otp-gorilla` uses a thin wrapper (`src/notify.sh`)
  that calls whichever is installed. Swap is a one-line change.

### 37. iCloud paths with apostrophes / special characters
**Concern (external review):** iCloud Drive on localized systems
can produce paths like `User's Database.kdbx` or `O'Brien's
Vault.kdbx`. The `find | picker` flow in Step 9 must survive
quote chars and spaces without breaking.

**Resolution:**
- Use NUL-delimited `find -print0` + `read -d ''` throughout the
  scanner:
  ```bash
  while IFS= read -r -d '' path; do
      candidates+=("$path")
  done < <(find "$ICLOUD_ROOT" -type f -name '*.kdbx' -print0 2>/dev/null)
  ```
- Quote every expansion in the picker prompt and the
  config-write step (`sed` / `printf` uses `%q` for the path).
- Write `GORILLA_DB` to `~/.config/s3c-gorilla/config` using
  `printf 'GORILLA_DB=%q\n' "$path"` so shell-unsafe chars are
  escaped on disk; tools source the config with
  `. "$CONFIG_FILE"`, which reverses the escape.
- Validation: CI / manual test on a kdbx named
  `O'Brien's Test Vault.kdbx` in a path containing a space and
  an apostrophe. Scanner picks it up; install writes it cleanly;
  `touchid-gorilla fan-out` reads it without quoting errors.

### 38. (Removed — obsolete.)
Phase 3 dropped; no AppleScript probe to be reliable or not.

### 39. Agent health is invisible to tools
**Concern (external review):** If `s3c-ssh-agent` crashes and
launchd is slow to restart it, screen-lock wipe + boot-wipe +
pushed-key heartbeat + Phase-3 polling all silently stop. User
has no indication their security posture just degraded.

**Resolution — one-line health check per tool invocation:**
- Every CLI tool (`env-gorilla`, `otp-gorilla`, `ssh-gorilla`
  wrapper, `touchid-gorilla` subcommands) runs a cheap health
  probe at the END of its work (stderr, not stdout, so it
  doesn't corrupt piped output). Apple explicitly says "don't
  parse `launchctl print`" and its format has changed across
  macOS versions (N7). Use the pre-launchd2 `launchctl list`
  surface instead — it's been stable since at least macOS 10.10
  and reliably returns a PID column for running services:
  ```bash
  # launchctl list output columns: PID STATUS LABEL
  # PID is "-" when the service is loaded but not running.
  agent_pid=$(launchctl list 2>/dev/null \
      | awk -v L=com.slav-it.s3c-ssh-agent '$3==L {print $1}')
  if [[ -z "$agent_pid" || "$agent_pid" == "-" ]]; then
      printf '\nwarning: s3c-ssh-agent is NOT running.\n' >&2
      printf 'Screen-lock wipe, boot wipe, and Phase-3 timer refresh are degraded.\n' >&2
      printf 'Try: launchctl kickstart -k gui/%d/com.slav-it.s3c-ssh-agent\n\n' "$UID" >&2
  fi
  ```
- Swift tools use `Process` to run the same `launchctl list`
  check and parse stdout identically.
- Does NOT fail the tool — degraded security is still working
  security for the current call, since the CLI can always
  trigger its own fan-out. Warning only.
- Validation: `launchctl bootout gui/$UID/com.slav-it.s3c-ssh-agent`
  then run `env-gorilla proj -- env`; expect the warning on
  stderr. `launchctl kickstart -k …` restarts; next invocation
  is silent.

### 40. Agent socket admission — peer-credential whitelist
**Concern (external review, extension of S3):** the uid-isolation
baseline is fine for generic ssh-agents, but `s3c-ssh-agent`
holds a fan-out's worth of secrets and signs without Touch ID for
pushed keys. A rogue same-uid process that opens the socket
first can push its own keys and have them signed unattended.
We should raise the bar above "any process that can connect()".

**Resolution — peer-credential check on every ADD_IDENTITY:**
- On each `accept()`, read the peer's PID via
  `getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID)`. (macOS exposes this
  for AF_UNIX sockets; returns the connecting-process PID.)
- Resolve the PID to an executable path via `proc_pidpath()`,
  and if it's a `.app` bundle, pull the bundle identifier via
  `CFBundle(url: ...)` → `bundleIdentifier`.
- Maintain a whitelist of allowed pushers (default:
  `["org.keepassxc.keepassxc"]`, configurable via
  `GORILLA_PUSHER_ALLOWLIST` in config, comma-separated bundle
  IDs).
- On `SSH_AGENTC_ADD_IDENTITY`:
  - If the peer's bundle ID matches the whitelist → accept,
    store in pushed cache.
  - Otherwise → return `SSH_AGENT_FAILURE`, log the rejection
    to `/tmp/s3c-ssh-agent.err.log` with PID + path + reason
    ("peer bundle `com.rogue.foo` not in allowlist").
- `REQUEST_IDENTITIES` and `SIGN_REQUEST` are NOT gated (any
  same-uid caller can list keys / trigger signs — same as
  OpenSSH's agent). Only ADD_IDENTITY, REMOVE_IDENTITY, and
  REMOVE_ALL are gated, because only those mutate the agent's
  pushed-key state.
- Limits: `LOCAL_PEERPID` returns the PID at connect time; a
  malicious process could execve into a whitelisted binary after
  connecting. Our check runs at `accept()`, so this would require
  the attacker to already be running as the KeePassXC bundle ID
  — at which point they already have the vault.
  Bundle-ID spoofing via a self-written `Info.plist` is possible
  but requires writing to a visible on-disk path; detection is
  the user's responsibility (external filesystem tripwire
  tooling — not shipped with s3c-gorilla).
- Validation rows: send ADD_IDENTITY from a non-whitelisted
  binary (e.g. `nc -U agent.sock`) → rejected with
  `SSH_AGENT_FAILURE`, log line appears. Send from KeePassXC →
  accepted.

### 41. Fan-out flock silent hang (progress sentinel)
**Concern (external review):** Concern #19's 30s flock timeout
applies everywhere except fan-out (§2a step 4 keeps 120s for
legitimate slow extractions). 120 seconds of a blocked `ssh foo`
with no UI feedback is brutal UX — indistinguishable from a
hang.

**Resolution:** progress sentinel at
`/tmp/s3c-gorilla/.fan-out-in-progress` maintained by the fan-out
holder; waiting tools stat + display progress instead of blocking
silently. Full mechanics in §2a step 4. Three outcomes for a
waiter:
- Sentinel fresh + `kill -0 <pid>` succeeds → display live
  progress line, keep waiting.
- Sentinel stale (`started > 120s ago`) or PID dead (`kill -0`
  returns ESRCH) → let flock time out naturally → surface the
  dead-holder error from Concern #19 with the stuck PID.
- No sentinel + flock acquires quickly → normal fan-out path.
Validation: simulate a fan-out that pauses at 42/75; waiting
`ssh` shows `waiting for initial secret extraction (42/75,
otp-GitHub)…` on stderr, rewritten with `\r`, until fan-out
completes.

### 42. `keys.json` registry leaks vault metadata
**Concern (external review):** the agent's `~/.s3c-gorilla/keys.json`
registry is mode 0600 but **unencrypted**. It contains the name,
key type, and mode of every SSH key plus (by extension of the
fan-out) every ENV project and TOTP service in the vault. A
same-uid read (rogue process, backup read, errant `cat`) gives
an attacker a full map of your infrastructure — what accounts,
what services, what key types — before they even attempt blob
decryption. Metadata is intel.

**Resolution — chip-wrap the registry like any other secret:**
- Rename on disk: `~/.s3c-gorilla/keys.json` →
  `~/.s3c-gorilla/keys.json.s3c`. SE-wrap encrypted via the same
  biometry-gated wrap key as the per-secret blobs.
- Fan-out builds the registry in a plain `Data` in memory
  (registry is metadata — bundle-IDs, names, modes — not huge),
  chip-wraps it, writes the `.s3c` atomically (tmp → `rename`,
  mode 0600), then `wipe(&registryData)` before returning.
- Agent reads the registry on startup (needed for
  REQUEST_IDENTITIES) via `touchid-gorilla unwrap keys.json`,
  which triggers one Touch ID. Agent caches the decoded registry
  in a plain `Data` for the process lifetime and calls
  `wipe(&cachedRegistry)` on SIGTERM / screen-lock wipe /
  REMOVE_ALL.
- `REQUEST_IDENTITIES` answers from the in-memory cache — no
  re-unwrap per request. Sub-millisecond.
- If the registry blob is missing or unwrap fails (Touch ID
  denied, SE key invalidated), the agent re-invokes
  `touchid-gorilla fan-out` which rebuilds the registry under
  the bootstrap flock.
- `pubkeys/<name>.pub` files stay **unencrypted**. Public keys
  are public; leaking them is harmless, and ssh-agent needs to
  serve them fast. Only the name/type/mode registry gets
  chip-wrapped — the piece that actually maps infrastructure.
- Validation: `cat ~/.s3c-gorilla/keys.json.s3c` produces
  non-ASCII ciphertext; `file ~/.s3c-gorilla/keys.json.s3c`
  reports "data" not "JSON text"; `grep -l '"keyType"'
  ~/.s3c-gorilla/*.s3c` returns no matches. `touchid-gorilla
  unwrap keys.json` triggers a Touch ID prompt and emits JSON
  on stdout.

Cost: one additional Touch ID at agent startup (coalesced with
the existing fan-out flow — user sees one prompt, not two).
Zero cost at steady state (cache hits).

### 43. Binary replacement attack on installed executables
**Concern:** `/usr/local/bin/s3c-ssh-agent` and
`/usr/local/bin/touchid-gorilla` are installed by default with the
installing user as owner. If an attacker ever gets same-uid write
to `/usr/local/bin` (buggy installer, sloppy `cp` from a project
build, a malicious formula, etc.), they can replace either binary.
Next `launchctl kickstart` runs attacker code as our signed daemon
— with full SE unwrap flow + Touch ID prompts the user will
reflexively approve. Nothing in the current plan prevents this.

**Resolution — three stacked defences (all required):**

**Layer 1 — root-owned, mode 0555 on disk.**
`14-launchagent.sh` and `05-touchid.sh` install binaries via
`sudo install`:
```bash
sudo install -m 0555 -o root -g wheel \
    "$BUILD_DIR/s3c-ssh-agent" /usr/local/bin/s3c-ssh-agent
sudo install -m 0555 -o root -g wheel \
    "$BUILD_DIR/touchid-gorilla" /usr/local/bin/touchid-gorilla
```
Effect: non-root processes (including the user's own shell, rogue
same-uid code) cannot `write()` or `unlink()` the installed
binaries. Replacement requires privilege escalation. install.sh
already primes sudo, so no extra user prompt. Uninstall path
mirrors with `sudo rm`.

**Layer 2 — agent self-verifies its codesign via
`SecCodeCheckValidity` on startup.**
On entry, both `s3c-ssh-agent main()` and `touchid-gorilla fan-out`
call:
```swift
import Security
var selfRef: SecCode?
guard SecCodeCopySelf([], &selfRef) == errSecSuccess, let me = selfRef,
      SecCodeCheckValidity(me, SecCSFlags(rawValue: kSecCSDefaultFlags), nil)
        == errSecSuccess
else {
    fputs("s3c-gorilla: codesign check failed — aborting\n", stderr)
    exit(99)
}
```
Catches: unsigned replacement, tampered binary, broken signature,
revoked certificate. Runs **before** any SE unwrap, before any
socket `bind()`. Hardened runtime (H3) combined with this check
is what Apple expects for security-sensitive daemons.

**Layer 3 — pinned cdhash from install time.**
install.sh, immediately after `sudo install`, captures the binary's
cdhash and writes it to a root-owned pin file:
```bash
# 14-launchagent.sh, after install
sudo mkdir -p /usr/local/share/s3c-gorilla
sudo chmod 0755 /usr/local/share/s3c-gorilla
cdhash=$(codesign -d -v /usr/local/bin/s3c-ssh-agent 2>&1 \
    | awk -F'=' '/^CDHash/ {print $2}')
printf '%s\n' "$cdhash" | sudo tee /usr/local/share/s3c-gorilla/agent.cdhash >/dev/null
sudo chmod 0444 /usr/local/share/s3c-gorilla/agent.cdhash
sudo chown root:wheel /usr/local/share/s3c-gorilla/agent.cdhash
```
Same for `touchid-gorilla.cdhash`. At launch the agent reads the
pin file and compares its own cdhash (via `SecCodeCopySigningInformation`
→ `kSecCodeInfoUnique`) against the recorded value:
```swift
let info = SecCodeCopySigningInformation(me, [.dynamicInformation], nil)
let runtimeCdhash = (info?[kSecCodeInfoUnique] as? Data)?.hexString
let pinnedCdhash = try? String(contentsOfFile: "/usr/local/share/s3c-gorilla/agent.cdhash")
    .trimmingCharacters(in: .whitespacesAndNewlines)
guard runtimeCdhash == pinnedCdhash else {
    fputs("s3c-gorilla: cdhash mismatch vs pinned — aborting\n", stderr)
    exit(99)
}
```
Catches: valid-signature-but-different-binary (attacker with a
signing cert replaces our binary with their own validly-signed
version; layer 2 would pass, this layer doesn't). Fail-closed if
the pin file is missing (treated as tampering, not as "first
run" — install.sh always writes it).

**Rotation:** after every re-install / upgrade, install.sh
rewrites the pin file before bootstrapping the agent. Order
matters — the sequence in `14-launchagent.sh` is:
1. `sudo install` new binary (Layer 1).
2. Record new cdhash to `agent.cdhash` (Layer 3 pin refresh).
3. `launchctl bootout` old agent.
4. `launchctl bootstrap` new agent. First thing it does on
   startup: Layer 2 self-check + Layer 3 pin compare.

**Threat-model coverage:**
- Same-uid attacker replaces binary on disk → Layer 1 blocks.
- Root-compromised attacker replaces binary → Layer 2 blocks
  unsigned binary; Layer 3 blocks a different signed binary. Only
  bypass: root attacker with OUR exact signing cert AND rewrites
  the pin file → at that point they are us, game over either way.
- Binary swap between `bootstrap` and first use → Layer 2 runs on
  every agent restart (including launchd's automatic respawn),
  Layer 3 catches mismatch.

Validation rows:
- `stat -f '%Sp %Su %Sg' /usr/local/bin/s3c-ssh-agent` → `-r-xr-xr-x root wheel` (mode 0555, root:wheel).
- Replace `/usr/local/bin/s3c-ssh-agent` with a harmless unsigned
  binary (as root, for the test) → `launchctl kickstart` fails;
  agent exits with "codesign check failed" (Layer 2) or "cdhash
  mismatch" (Layer 3).
- Delete `/usr/local/share/s3c-gorilla/agent.cdhash` → agent
  refuses to start on next launch.
- Same treatment for `touchid-gorilla` (invoked by every fan-out).