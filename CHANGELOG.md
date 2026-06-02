# Changelog

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
