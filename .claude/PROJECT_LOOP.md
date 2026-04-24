# Project Feedback Loop — s3c-gorilla

macOS-only CLI toolkit. Swift binaries (`touchid-gorilla`, `s3c-ssh-agent`) +
shell tools (`env-gorilla`, `otp-gorilla`, `ssh-gorilla.sh`). **No Package.swift
on purpose** — `swift build` will always skip.

## Services & Their Log Files

This is a CLI toolkit, not a server. "Services" here = the feedback-loop
commands and their captured output.

- **lint + typecheck**    → `logs/lint.log`          via `./scripts/lint.sh`
- **unit + shell tests**  → `logs/test.log`          via `./scripts/test.sh`
- **installer** (manual)  → `logs/s3c-gorilla.log`   via `./install.sh` — DO NOT run from the agent; user runs it (sudo, signing identity, interactive prompts)
- **runtime LaunchAgent** → `/tmp/s3c-ssh-agent.{out,err}.log` — only exists after the user installs

## How to Start Everything

There is nothing to "start" — the feedback loop is edit → lint → test:

```
./scripts/lint.sh        # swift-linter on src/ + swiftc -typecheck on each .swift
./scripts/test.sh        # runs src/tests/run.sh (swift inline tests + bats if installed)
./scripts/test.sh swift  # only the Swift layer (no bats dependency)
```

Both commands tee to `logs/` and exit non-zero on real failures.

## How to Check Build Success

There is no build system. `swiftc -typecheck` against each top-level
`src/*.swift` stands in for a compile check. `scripts/lint.sh` runs this for
you. In `logs/lint.log` look for:

```
--- swiftc -typecheck on each top-level .swift ---
  OK    s3c-ssh-agent.swift
  OK    touchid-gorilla.swift
```

Any `FAIL` line means the file does not compile — indented lines below it
show the exact swiftc errors.

## How to Detect a Crash

Swift inline tests print `FAIL <name>` followed by `--- N passed, M failed`.
`logs/test.log` tail line `total: X passed, Y failed, Z skipped` — `Y > 0`
means red. Skipped tests are expected while PLAN.md phases are still
landing (they flip to PASS as features ship).

## How to Run Smoke Tests

```
./scripts/test.sh swift          # fast, no external deps
./scripts/test.sh                # full (requires bats-core for shell layer)
```

Hardware-dependent checks (TouchID prompt, real SE encrypt/decrypt,
KeePassXC push, `launchctl kickstart` reconnect, cdhash pin) live in
[src/tests/e2e/README.md](../src/tests/e2e/README.md) — these are **manual
walk-throughs**, not automatable. Do not attempt to run them from the
agent.

## Health Check Endpoints

None — this is a CLI toolkit, there is no HTTP surface.

Runtime sanity commands (only meaningful after `install.sh` has run on the
user's Mac, which the agent never does):

```
s3c-gorilla status     # agent PID, TTL remaining, config paths
s3c-gorilla doctor     # codesign / modes / deps / hw integrity check
```

## Known Error Patterns

Fill in as real failures appear. Starter entries:

- `no such module 'LocalAuthentication'` in `logs/lint.log` → you ran on
  a non-macOS toolchain (the agent is probably inside Docker). Typecheck
  for LocalAuthentication/SecureEnclave code is only meaningful on macOS.
- `bats not installed` in `logs/test.log` → expected on fresh machines;
  the shell test layer auto-skips. `brew install bats-core` to enable.
- `FAIL  <file>.swift` under "swiftc -typecheck" → real compile error,
  indented swiftc output follows. Fix before continuing.
- `ERR  <file>.swift: N lines (max 400 — split this file)` → file-length
  policy from CLAUDE.md. Split, don't suppress.

## What This Loop Does NOT Cover

- **`install.sh`** — needs sudo, user password, signing cert, interactive
  TouchID prompts. User runs it, agent never does (CLAUDE.md hard rule).
- **Signed-binary verification** — `codesign`, `cdhash` pinning, hardened
  runtime self-check only meaningful after install.
- **LaunchAgent lifecycle** — `launchctl bootstrap/kickstart/bootout` are
  manual e2e steps.
- **KeePassXC CLI interaction** — requires a real kdbx file and master
  password; covered by manual e2e only.
