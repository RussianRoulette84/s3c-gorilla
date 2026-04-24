# s3c-gorilla tests

Three layers. Each matches a section of `plan/PLAN.md`.

## Layer 1 — Swift unit tests (`swift/`)

Pure-logic code. Runs without Touch ID, without SE, without KeePassXC.
Targets the interfaces specified in PLAN.md §5.

Each test file is a standalone `.swift` script with inline asserts —
no XCTest, no SwiftPM, no Package.swift (matches the project's
"no SPM" stance).

Run one file:
```
swift src/tests/swift/test_wipe.swift
```

Run all:
```
src/tests/run.sh swift
```

**Skip behaviour:** tests targeting unimplemented features emit
`SKIP` with a reason (e.g. "wipe() helper not yet built"). As
PLAN.md phases land, skips convert to passes. A skip is not a
failure — feedback-loop runs exit 0 with skips present.

## Layer 2 — shell tests (`shell/`)

`install.sh` / `src/setup/*.sh` surface. Uses `bats-core`.

Install bats once:
```
brew install bats-core
```

Run one file:
```
bats src/tests/shell/test_config_defaults.bats
```

Run all:
```
src/tests/run.sh shell
```

## Layer 3 — manual e2e (`e2e/README.md`)

The hardware-dependent checks from PLAN.md §4 — Touch ID prompts,
real SE encrypt/decrypt, KeePassXC push, `launchctl kickstart`
reconnect, cdhash pin verification, hardened-runtime flag, etc.
Human walk-through, not automated.

## Run everything

```
src/tests/run.sh
```

Exits 0 if no failures (skips allowed); non-zero on the first
failed test.
