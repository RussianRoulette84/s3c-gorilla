# env-gorilla vault-writes + Infisical sync + manual kdbx backup

## Context

Today, adding a secret to a project means opening the KeePassXC GUI and hand-editing the `.env` attachment — slow and error-prone. This adds fast CLI writes to `env-gorilla` (`set`/`append`/`unset`/`edit`), mirrors secrets to a **self-hosted Infisical** instance (push/pull/sync), and adds a **manual `.kdbx` backup** command for safety. It's a public tool, so **nothing is hardcoded**: the per-project Infisical connection lives inside that project's own `.env` (a `# Infisical` block), and Infisical support is an opt-in installer toggle.

## Locked decisions (from user)

- **Backup: manual only** — `s3c-gorilla backup` (no auto-backup on write, for now). push/pull/sync print a "run backup first" hint.
- **Infisical mapping: project-per-app.** Each s3c project = its own Infisical project. Connection details live in that project's `.env` under a `# Infisical` block:
  ```
  # Infisical
  INFISICAL_API_URL=https://infisical.example.com
  INFISICAL_CLIENT_ID=...
  INFISICAL_CLIENT_SECRET=...
  INFISICAL_PROJECT_ID=00000000-0000-0000-0000-000000000000      # tolerate the INFISCAL_ typo variant too
  INFISICAL_MACHINE_ID=...               # informational
  ```
  This block is **config, never pushed as secrets** — push/pull/sync operate on the *other* keys only.
- **push AND pull are interactive on merge conflicts** (per-key: keep-local / take-remote / skip). `--force-infisical` (alias `--force`) skips prompts and auto-applies the suggested resolution.
- Global on/off via `GORILLA_INFISICAL_ENABLED`; installer asks (default **NO**) with a 3-sentence explainer + URL.

## Wave 1 — manual backup (do first)

`src/s3c-gorilla` (umbrella dispatcher) — add a `backup` verb:
- `cp "$GORILLA_DB"` → `~/.s3c-gorilla/backups/<dbname>-YYYYMMDD-HHMMSS.kdbx`, `chmod 600`, print the path. Create `backups/` 0700. No pruning (manual only).
- Reuse the config-loading the CLI already does for `$GORILLA_DB`.

## Wave 2 — env-gorilla vault writes (`src/env-gorilla`)

New subcommands, dispatched **before** the `--` syntax check (~line 226); helper funcs defined after `have_chip()` (~line 44). One master-pw prompt via `get_master_pw` (banners.sh); current `.env` read via the existing `kdbx_extract_env` (line 74).

- `set <proj> KEY=VAL [KEY2=VAL2 …]` — **upsert**, comment/line-order preserving (replace `^KEY=` line if present, else append).
- `append <proj>` — read a blob from **stdin**, append **verbatim** (preserves `# comment` headers like the SENTRY block).
- `unset <proj> KEY [KEY2 …]` — delete matching `^KEY=` lines.
- `edit <proj>` — decrypt `.env` → temp (0600, in `mktemp`) → `$EDITOR` → re-import → shred temp.
- `--push` modifier on `set` → after the vault write, push that project to Infisical.

Shared write path `_env_write <proj> <tmpfile>` (reuses proven `import-ssh-keys.sh` verbs, lines 56/117-118):
1. `keepassxc-cli add "$DB" "$ENV_GROUP/<proj>" -q || true` (ensure entry)
2. `keepassxc-cli attachment-import "$DB" "$ENV_GROUP/<proj>" .env <tmpfile> -q -f`
3. **bust the blob cache** so the next read is fresh: chip → `touchid-gorilla wrap-clear "env-<proj>"`; password → remove `/tmp/s3c-gorilla/env-<proj>.blob`. (Mirror env-gorilla lines 204-214.)

## Wave 3 — Infisical bridge (`src/lib/s3c-infisical.sh`, new; sourced like banners.sh)

Gated on `GORILLA_INFISICAL_ENABLED=true` and `command -v infisical`. All values come from the project's `.env` block — **no hardcoding**.

- `_inf_parse <envtext>` → API_URL, CLIENT_ID, CLIENT_SECRET, PROJECT_ID, ENV (default `prod`; accept `INFISCAL_` typo).
- `_inf_token` → `INFISICAL_TOKEN=$(infisical login --method=universal-auth --client-id … --client-secret … --domain "$API_URL" --plain --silent)` (per-invocation; not persisted).
- `_inf_remote` → `infisical secrets --projectId … --env … --plain` (read remote k/v for the diff).
- **push `<proj>` [--force]** — diff local app-keys (exclude `INFISICAL_*` + comments) vs remote; adds → `infisical secrets set K=V …`; value conflicts → prompt keep-local/skip (force ⇒ local wins); never uploads the connection block.
- **pull `<proj>` [--force]** — diff remote vs local; chosen remote values upserted into the local `.env` (preserve comments, the `# Infisical` block, and local-only keys), then `_env_write`; conflicts prompt (force ⇒ remote wins).
- **sync `<proj>` [--force]** — bidirectional: local-only ⇒ push, remote-only ⇒ pull, value conflict ⇒ prompt (force ⇒ remote wins). Suggestion rule stated in `--help`.
- Wire into env-gorilla dispatch: `push`/`pull`/`sync <proj>` subcommands + `set … --push`.

## Wave 4 — installer + config

- `src/setup/config.example` — add `#GORILLA_INFISICAL_ENABLED="false"` with a short note that per-project creds live in each `.env`'s `# Infisical` block (not here).
- `src/setup/11-infisical.sh` (new step, before `99-done.sh`) — `section "[11] Infisical (optional)"`; print the 3-sentence explainer + `https://infisical.com`; `read -rp "Enable Infisical secret sync? [y/N] "` default **NO**. If yes: detect `infisical` (offer `brew install infisical/get-cli/infisical` like 01-keepassxc.sh does for keepassxc), `set_config GORILLA_INFISICAL_ENABLED true`, and tell the user to add the `# Infisical` block to each project via `env-gorilla edit <proj>`. Verify = CLI present + `infisical --version` (per-project creds live in the vault, so no deep connection test at install).
- `src/setup/04-tools.sh` — install `src/lib/s3c-infisical.sh` → `$SHARE_DIR/s3c-infisical.sh` (0644), alongside banners.sh.

## Wave 5 — docs

- `README.md` — new "Edit secrets from the CLI + Infisical sync" section (set/append/unset/edit, push/pull/sync, `s3c-gorilla backup`).
- `plans/PLAN.md` — add as a new tracked feature line.

## Explainer text (installer, verbatim target)

> Infisical is an open-source secrets manager: a server that stores your app secrets and hands them to your services over an authenticated API. s3c-gorilla can **sync** each project's `.env` between your KeePassXC vault and an Infisical project — push local → server, pull server → local, or reconcile both. Learn more at https://infisical.com. (Optional; default off.)

## Verification (batched — minimize Touch ID)

1. `./scripts/lint.sh` (bash) + `./scripts/build-swift.sh` (no Swift changes, sanity).
2. `s3c-gorilla backup` → timestamped 0600 copy appears under `~/.s3c-gorilla/backups/`.
3. `env-gorilla set _t FOO=bar` then `env-gorilla _t -- printenv FOO` → `bar`; `env-gorilla edit _t` preserves a pasted `# comment` block; `env-gorilla unset _t FOO` removes it.
4. On the Mac (has `infisical` + network): with the `# Infisical` block in `ENV/my-project`, `env-gorilla push my-project` upserts non-INFISICAL keys (interactive on conflict); `pull` merges back; `--force-infisical` runs non-interactively.

## Critical files

`src/env-gorilla`, `src/lib/s3c-infisical.sh` (new), `src/lib/banners.sh`, `src/s3c-gorilla`, `src/setup/00-common.sh`, `src/setup/04-tools.sh`, `src/setup/11-infisical.sh` (new), `src/setup/config.example`, `install.sh`, `README.md`, `plans/PLAN.md`.

## Folded defaults (vetoable)

- Infisical `--env` defaults to `prod` (override via `INFISICAL_ENV` in the `.env` block).
- `--force-infisical` conflict rule: remote wins on pull/sync, local wins on push.
- The connection block (`INFISICAL_*`) is filtered out of every push and never overwritten by pull.
