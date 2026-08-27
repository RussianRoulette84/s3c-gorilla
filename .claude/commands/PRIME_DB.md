---
description: Prime agent with slav_auth Postgres context (Django auth tables) via the safe builder-API db-query job.
allowed-tools: Read, Bash, mcp__slav-ops__run_job, mcp__slav-ops__builder_api
---

# PRIME DB (slav-ai)

Prime your mental model of the **`slav_auth`** Postgres database that backs the Django `unchained` auth app on `:8002`. Don't run raw `psql` — use the builder-API `db-query` job (regex-gated, read-only by default).

## What slav_auth is

- Postgres 16 on `127.0.0.1:5432` (host). DB name: `slav_auth`.
- Owns: users, sessions, JWT refresh, login attempts, IP/email lockouts, intrusion events.
- Migrations live in `src/unchained/users/migrations/` and `src/unchained/intrusion/migrations/`.

## Probe (run all in parallel)

1. `mcp__slav-ops__run_job {name:"pg-status"}` — is Postgres alive?
2. `mcp__slav-ops__run_job {name:"db-query", params:{sql:"SELECT current_database(), current_user, version()"}}` — confirm DB + role.
3. `mcp__slav-ops__run_job {name:"db-query", params:{sql:"SELECT tablename FROM pg_tables WHERE schemaname='public' ORDER BY tablename"}}` — list tables.
4. `mcp__slav-ops__run_job {name:"db-query", params:{sql:"SELECT count(*) FROM users_user"}}` — basic row count sanity.

## Useful read-only queries (db-query is single-statement only)

```sql
-- Users
SELECT id, email, role, is_active, last_login FROM users_user ORDER BY id

-- Active sessions (recent)
SELECT id, user_id, is_active, created_at FROM users_session WHERE is_active=true ORDER BY created_at DESC LIMIT 20

-- Recent login attempts
SELECT email, ip, succeeded, created_at FROM users_loginattempt ORDER BY created_at DESC LIMIT 20

-- Active lockouts
SELECT ip, email, locked_until FROM users_ipemaillockout WHERE locked_until > now()

-- Schema of a table
SELECT column_name, data_type, is_nullable FROM information_schema.columns WHERE table_name='users_user' ORDER BY ordinal_position
```

## Writes / migrations

- **Reads** pass through `db-query` automatically (regex `^[^;]+;?\s*$`).
- **Writes** require `ALLOW_DB_WRITE=true` in builder-API env — don't enable casually.
- Migrations: `mcp__slav-ops__run_job {name:"django-makemigrations"}` then `{name:"django-migrate"}`. Backup first via `db-backup` job.

## Django shell access

For ORM access (`User.objects.get(...)`, `issue_pair`, etc.):

```
mcp__slav-ops__run_job {name:"django-shell-exec", params:{expr:"<python>"}}
```

⚠️ Audited and **prod-gated** — works locally; on prod requires `ALLOW_SHELL_EXEC=true`. Token-minting calls are visible in `/queue` history (consider when handling secrets).

## Report

After priming, output 2-3 sentences: which tables exist, row counts on the auth tables, any anomalies (locked-out IPs, stale sessions, drift between migrations and DB).
