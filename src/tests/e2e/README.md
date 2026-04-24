# s3c-gorilla — manual e2e validation

These checks require real hardware, a real Touch ID finger, and a
real KeePassXC. They cannot be automated. Walk through after each
implementation phase per PLAN.md §4 and PLAN.md "Verify" section.

Copy this file as `e2e-run-YYYY-MM-DD.md`, check off as you go.

---

## Filesystem posture (Concern #17)

- [ ] `/tmp/s3c-gorilla/` directory is mode 0700 (`stat -f '%Sp'` → `drwx------`)
- [ ] Every `.s3c` file in `/tmp/s3c-gorilla/` is mode 0600 (`-rw-------`)
- [ ] `~/.s3c-gorilla/` directory is mode 0700
- [ ] `~/.s3c-gorilla/agent.sock` is mode 0600 (chmod'd after `bind()`)
- [ ] `~/.s3c-gorilla/keys.json.s3c` is mode 0600 **AND** `file` reports "data" not JSON (Concern #42)
- [ ] No `master.s3c` exists anywhere (`find ~ /tmp -name 'master.s3c' 2>/dev/null` empty)

## Binary integrity (Concern #43)

- [ ] `stat -f '%Sp %Su %Sg' /usr/local/bin/s3c-ssh-agent` → `-r-xr-xr-x root wheel`
- [ ] Same for `/usr/local/bin/touchid-gorilla`
- [ ] Replace agent binary (as root) with an unsigned binary → `launchctl kickstart` fails with "codesign check failed" (Layer 2)
- [ ] Replace agent binary (as root) with a different validly-signed binary without refreshing the pin → agent logs "cdhash mismatch vs pinned" (Layer 3)
- [ ] Delete `/usr/local/share/s3c-gorilla/agent.cdhash` → agent refuses to start with "pin file missing"
- [ ] Re-install (`./install.sh` re-run) rewrites `agent.cdhash` before `launchctl bootstrap`

## Codesign (Concern H3)

- [ ] `codesign -d --verbose=4 /usr/local/bin/touchid-gorilla` shows `flags=0x10000(runtime)`
- [ ] `codesign -d --verbose=4 /usr/local/bin/s3c-ssh-agent` shows `runtime` flag
- [ ] Both show `Timestamp=` line (not "none")

## Fan-out / unlock flow

- [ ] Reboot → `ls /tmp/s3c-gorilla/` empty
- [ ] First `ssh foo` → master-pw prompt → fan-out runs, blobs appear for every SSH/ENV/2FA entry
- [ ] Second `ssh foo` → Touch ID only, no master pw
- [ ] `env-gorilla proj -- env` after first ssh → Touch ID only
- [ ] `otp-gorilla atlas` after first ssh → Touch ID only
- [ ] `env-gorilla --paranoid other -- env` → master-pw prompt even with env-other.s3c present

## Session boundaries

- [ ] Logout → `/tmp/s3c-gorilla/` empty on re-login
- [ ] `GORILLA_WIPE_ON_SCREEN_LOCK=1` (default): Ctrl-Cmd-Q → unlock → `/tmp/s3c-gorilla/` empty → next tool re-prompts
- [ ] `GORILLA_WIPE_ON_SCREEN_LOCK=0`: lock/unlock cycle → blobs survive, next tool only needs Touch ID
- [ ] Set `GORILLA_UNLOCK_TTL=60`, wait 70s idle → next tool re-prompts (tunable-TTL sanity)
- [ ] Reboot race: interrupt login + run `ssh foo` within ~200ms of logging in → tool's inline mtime vs kern.boottime check fires re-fan-out (Concern #26)

## KeePassXC push integration (Phase 2)

- [ ] Launch KeePassXC, enable SSH Agent, mark keys for agent
- [ ] `ssh-add -L` lists pushed keys tagged `(pushed by KeePassXC)`
- [ ] `ssh foo` with KeePassXC unlocked + Agent enabled → zero Touch ID, zero master pw
- [ ] Lock KeePassXC → pushed keys vanish from `ssh-add -L` within 10s (Concern #20 heartbeat)
- [ ] `ssh foo` after lock → falls through to Touch ID flow
- [ ] Peer-cred check: `nc -U ~/.s3c-gorilla/agent.sock` with a fake ADD_IDENTITY → rejected; log line at `/tmp/s3c-ssh-agent.err.log` names PID + path (Concern #40)

## RSA wiring (Concern #33)

- [ ] Byte-identical-to-`ssh-keygen -Y sign` test passes for ssh-rsa, rsa-sha2-256, rsa-sha2-512
- [ ] Live ssh into a test sshd, each algorithm negotiated successfully (check `sshd -d` logs)

## Secure input (Concern #18)

- [ ] During terminal master-pw prompt, yellow padlock appears in macOS menu bar
- [ ] `kill -SEGV` the master-prompt process mid-`read()` → SEI lock released within 1s (SIGALRM backstop)

## Touch ID re-enrollment (Concern #14)

- [ ] Add or remove a fingerprint in System Settings
- [ ] Next tool call: old blobs fail decrypt cleanly with "re-seed" notice → fan-out re-runs → Touch ID succeeds on the new enrollment

## Agent health (Concern #39)

- [ ] `launchctl bootout gui/$UID/com.slav.s3c-ssh-agent` → next `env-gorilla` prints a one-line stderr warning naming the missing agent + the kickstart command
- [ ] Tool still succeeds (warning only, not fatal)
- [ ] `launchctl kickstart -k ...` → next invocation is silent

## Permissions (Concern #15 / install-time)

- [ ] `15-permissions.sh` triggers the terminal-notifier prompt on a fresh Mac
- [ ] Notifications prompt shows up; clicking Allow makes `otp-gorilla` notify correctly

## Install / re-install

- [ ] `install.sh` completes cleanly on a fresh Mac
- [ ] Re-running `install.sh` preserves `~/.config/s3c-gorilla/config` user edits
- [ ] `install.sh` final line count ≤ 200 (`wc -l install.sh`)
- [ ] Every file under `src/setup/` ≤ 250 lines
- [ ] `git diff README.md` empty after install run

## Phase 0 research gate

- [ ] `plan/PHASE-0-KEEPASSXC-CLI.md` exists with keepassxc-cli version + 5 probe results + GREEN/RED verdict (Concern #24)
- [ ] If GREEN: `dtruss -t open keepassxc-cli export ...` shows no tempfile writes
- [ ] If RED: Phase 1 code uses the parallel-workers fallback path

---

**Convention**: when a check fails, note the failure mode in a new
`e2e-run-<date>.md`, link it into `plan/PLAN.md`'s Concerns section,
fix, re-run the whole checklist.
