# SSH unlock persistence — stop the 100× Touch ID spam

## Context

In Touch ID mode the SSH agent fires a **fresh fingerprint on every single signature** (`s3c-ssh-agent.swift` unwraps + re-locks the key per sign). A `fab deploy`, an Envoy run, or a `git fetch` fires dozens of signatures, so the user burns a fingerprint dozens of times for one action. GUI apps (Xcode, SourceTree, Sequel Ace) hit the same wall.

The fix rides an existing, proven path: KeePassXC-pushed keys already sign *without* Touch ID from an mlock'd memory cache (`gPushed`), wiped on screen-lock, logout, and reboot. We extend that: after the first unlock, keep the key warm in agent memory for a **user-chosen scope**, and re-lock it when the vault closes.

Security trade is explicit and opt-in: caching the unwrapped key drops the per-signature biometric gate for the cache window. Keys stay mlock'd and zeroed on every wipe event. Default scope is **session**; `once` restores today's per-sign Touch ID exactly.

## Locked decisions

- **App scope = owning-app PID.** Walk up from the throwaway `ssh` process to the app macOS launched. GUI app = its own PID → quit/restart re-locks. Terminal deploy = the terminal window is the app → unlocked until that window closes (no idle cap).
- **Native high-tech custom window** (AppKit + CoreAnimation): glowing app icon, icon palette, animated fingerprint-ridge password effect, 3-way scope switch, "ask password each time" toggle (Touch ID Macs only), and a custom-drawn "unlock for N minutes" TTL dropdown.
- **"Vault close"** = screen lock / logout / system sleep-or-lid / reboot.
- Cross-tool: password in the window warms env/otp too; password in a terminal already warms SSH.

## Three scopes

| Scope | Behavior | Lifetime |
|-------|----------|----------|
| `once` | No caching — Touch ID every sign (today) | n/a |
| `app` | Cache tagged with owning-app PID; sign without Touch ID | until that app/terminal window quits |
| `session` | Cache globally; sign without Touch ID | until vault close |

Scope picker appears only on a **cold unlock** (vault closed since boot) where the SSH agent is first unlocker. Warm vault → default scope `GORILLA_SSH_UNLOCK_SCOPE` (default `session`), one Touch ID unwrap, no window.

## Wave 1 — In-agent key cache with scope  `src/s3c-ssh-agent.swift`

Reuse the `gPushed` cache pattern (mlock'd, zeroable, wiped on lock/logout).

- **`gSSHCache`**: `keyName → { keyBytes (mlock'd), scope, ownerPID, expiry }`, serial-queue guarded, alongside `gPushed`.
- **`resolveOwningApp(peerPID)`**: peer PID via `getsockopt(LOCAL_PEERPID)`, walk parent chain (`sysctl KERN_PROC_PID` → `kp_eproc.e_ppid`) until the process whose parent is launchd (pid 1).
- **Sign path** (~line 441 chip-wrap `unwrapViaTouchID`): `session` → cache hit signs no-TouchID, miss unwraps+stores; `app` → resolve owner, live-PID hit signs, else unwrap+store tagged; `once` → unwrap every time, never store.
- **Reaper**: drop `app` entries with dead `ownerPID` (`kill(pid,0)`) and any entry past its TTL cap. Effective lifetime = `min(scope, ttl)`.
- **Sleep/lid wipe**: `NSWorkspace.willSleepNotification` (or IORegistry `kIOMessageSystemWillSleep`) → wipe via existing `cleanup()`. Screen-lock/logout/boot already wired.
- **Scope state**: `gSessionScope` from the window, fallback config default `session`.
- **Paranoid override**: `GORILLA_SSH_ASK_PW_EACH_TIME` ON → skip cache and Touch ID shortcut, force a fresh password window each unlock.

## Wave 2 — Native high-tech unlock window  `src/s3c-unlock-window.swift` (new)

Replace `askMasterPassword()` (osascript ~704-723) with a native window returning **(password, scope, askPwEachTime, ttlMinutes)**. Pure AppKit + CoreAnimation, no external deps.

**Palette (sampled from `icon.png`):** bg navy-black `#12181F→#1E2833`; primary cyan `#2FC9EE`; steel `#8A97A6`; bronze `#C9A24B`; text `#E6EEF5`.

- Frameless `NSWindow`, rounded, dark `NSVisualEffectView`, 1px cyan hairline + outer cyan glow, drag-by-background.
- App icon top-center with a **breathing cyan glow** (`CALayer` shadow radius/opacity on a slow `CABasicAnimation` loop). Icon from `/usr/local/share/s3c-gorilla/icon.png`.
- Title `s3c-gorilla` + subtitle `UNLOCK THE VAULT`.
- Password `NSSecureTextField`, cyan caret; **fingerprint-ridge ring of dots spins a couple turns per keystroke** (`CAShapeLayer` + `CABasicAnimation` on `controlTextDidChange`), honors Reduce Motion.
- 3-way scope segmented control (once/app/session, default session), cyan-glow selection + bronze underline.
- "Ask password each time" ON/OFF toggle, OFF default, **visible only when `hasBiometry()`**.
- "Unlock for [15] minutes" **custom-drawn dropdown** (5/15/30/60min/2h/8h/24h, default 15), themed, caps cache at `min(scope, timer)`.
- Unlock button cyan-glow; Return submits, Esc cancels.

**Agent integration:** LaunchAgent `ProcessType: Interactive` in Aqua → activation policy `.accessory` + `activate(ignoringOtherApps:)`. Fallback to osascript if the native window can't become key. Warm vault → no window.

## Wave 3 — Bidirectional warm  reuse `fan_out_all`

On cold-unlock password capture, warm all secrets: agent shells to a tiny entrypoint (e.g. `s3c-gorilla _fanout`, reads pw on stdin, sources `banners.sh`, calls `fan_out_all`, writes sentinel). Reverse direction already works.

## Wave 4 — Password-only Macs

No SE, no per-sign biometric to spam — `s3c-session-agent` already caches the master pw per-tty (TTL) and `.ssh.sock` serves keys without re-auth. Map scope→lifetime (`session`=keep for TTL, `once`=no cache); window hides `app` + the toggle. No new per-sign logic.

## Wave 5 — Config + docs

- `src/setup/config.example`: `GORILLA_SSH_UNLOCK_SCOPE` (default session) + `GORILLA_SSH_ASK_PW_EACH_TIME` (default off, Touch ID Macs) with notes.
- `src/setup/04-tools.sh`: install `icon.png` → `/usr/local/share/s3c-gorilla/icon.png` (0644); build `s3c-unlock-window.swift` alongside the agent.
- `README.md`: "Stop the Touch-ID spam — SSH unlock scopes" section.
- `CHANGELOG.md`: entry under next version.
- `plans/PLAN.md`: tracked feature line.

## Critical files

`src/s3c-ssh-agent.swift`, `src/s3c-unlock-window.swift` (new), `src/lib/banners.sh`, `src/s3c-session-agent.swift`, `src/setup/config.example`, `src/setup/04-tools.sh`, `README.md`, `CHANGELOG.md`, `plans/PLAN.md`.

## Verification (batched — minimize Touch ID)

1. `./scripts/lint.sh` + build Swift binaries on the Mac.
2. Cold unlock GUI: lock vault, open SourceTree → window pops → pick `app` → one fingerprint → many fetches no re-prompt; quit app → re-prompts.
3. Terminal deploy session scope: one fingerprint for a burst; second run same window → zero; close window → re-prompts.
4. Vault close: lock screen (and sleep/lid) → next sign re-auths.
5. Cross-tool: password in window → `env-gorilla <proj> -- printenv` asks only Touch ID / nothing, not the password.
6. `once` regression: per-sign Touch ID unchanged.
7. Password-only Mac: one prompt per window, wiped on lock.

## Folded defaults

- Default scope `session`; `once` restores current behavior.
- No idle cap on `app` scope; `GORILLA_SSH_APP_IDLE_CAP` can be added later.
- Owning-app = first ancestor whose parent is launchd (pid 1).
- Sleep/lid wipes the cache, same as screen-lock.
