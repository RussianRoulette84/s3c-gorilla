---
description: Three-part health probe — log files, MCP servers, AND the full build toolchain (SSH/deploy/jobs via dry-run + cheap real probes). Output is tables only. Goal — catch a broken tool (SSH, fab, venv, launchctl) NOW, not mid-work.
argument-hint: [optional: "logs" | "mcp" | "tools" — default runs all three]
allowed-tools: Bash, mcp__slav-logs__list_logs, mcp__slav-ops__status, mcp__slav-ops__ps, mcp__slav-ops__builder_api, mcp__slav-ops__run_job, mcp__slav-ops__build_status, mcp__filesystem__list_allowed_directories, mcp__git__git_status
---

# CHECK — logs + MCP + build-toolchain health

Probe what we can see, touch, AND build/ship with. **Output tables only — no walkthroughs, no per-tool narration.** End with the standard reporting footer.

**Why this exists:** Yaro got burned mid-work by a silently-dead tool (SSH key, fab, venv). This command proves every load-bearing build surface is alive UP FRONT. "Registered" is not enough — we dry-run jobs (resolves the real binary + validates placeholders, executes nothing) and run a few cheap read-only jobs for real.

## Variables

MODE: `$ARGUMENTS` (default: `all`. Accepts: `logs`, `mcp`, `tools`, `all`)

## Workflow

Run probes **in parallel** (single tool-call batch per part — independent reads). Don't probe sequentially.

### Part 1 — LOGS (only if MODE ∈ {logs, all})

- `mcp__slav-logs__list_logs` — names, bytes, mtime
- Infer side: **frontend** = `vite.log`; **backend** = `api.log` / `unchained.log` / `hanoi_trello.log` / `conversation.log` / `ai_management.log`; **build/pentest** = `build.log` / `auth_hammer.log` / `lounge.log` / `livekit.log` / other
- Mark "🟢 hot" if mtime within 60s, blank otherwise

### Part 2 — MCP SERVERS (only if MODE ∈ {mcp, all})

- `mcp__slav-ops__status` — 6 expert URLs (GREEN/RED)
- `mcp__slav-ops__ps` — api + vite pid alive
- `mcp__slav-logs__list_logs` — proves slav-logs answers
- `mcp__filesystem__list_allowed_directories` — scope
- `mcp__git__git_status path:"/root/Projects/slav-ai"` — branch + clean/dirty
- Playwright: don't probe — confirm tool list shows `browser_*` deferred tools

### Part 3 — BUILD TOOLCHAIN (only if MODE ∈ {tools, all})

**3a. Real read-only probes** (actually execute — prove the binary RUNS, not just resolves):

- **SSH → prod** (the one that burned us): `ssh -o StrictHostKeyChecking=no -o ConnectTimeout=8 -i /root/Projects/slav-ai/ssh/id_ed25519 llmdocker@slav-it.com 'echo OK; hostname'` — expect `OK` + `slav-it`
- `mcp__slav-ops__builder_api path:"/status"` — daemon alive
- `mcp__slav-ops__builder_api path:"/queue"` — current/pending depth
- `mcp__slav-ops__run_job name:"git-status"` — git binary runs
- `mcp__slav-ops__run_job name:"pg-status"` — Postgres reachable (pg_isready)
- `mcp__slav-ops__run_job name:"django-check"` — proves `.venv` python + Django import chain works (the canary for a broken venv)

⚠️ `run_job` returns **202 async** (`status:"queued"/"building"`), NOT the result. Capture each `id`, then poll `mcp__slav-ops__build_status {id}` and report **only `returncode:0` = 🟢** — never count a `queued` response as a pass.

**3b. Dry-run sweep — EVERY job, no sampling.** First `mcp__slav-ops__builder_api path:"/jobs"` to get the full catalog (count is whatever `/jobs` returns — don't hardcode it). Then dry-run **each one**: `builder_api method:"POST" path:"/job/<name>?dryrun=1" body:{params:{...}}`. Each must return `dryrun:true` + a resolved `would_run` array. This proves every job is wired, its binary path resolves, hash-pinned wrappers haven't drifted, and placeholder regexes match — **executing nothing**.

Jobs with a **required placeholder** need a sample value (regex-valid; dry-run never checks existence, only the regex). Use this canned map:

| placeholder | sample |
|---|---|
| `n` | `5` |
| `depth` | `1` |
| `lines` | `10` |
| `pattern` | `test` |
| `package` | `pip` |
| `sql` | `SELECT 1` |
| `fixture` | `x.json` |
| `cmd` | `status` |
| `spec` | `tests/playwright/specs/x.spec.js` |

Run the dry-runs in parallel batches (they're independent, cheap). Tally `🟢 / 🔴` per job.

- `412 command_hash_mismatch` = a pinned wrapper drifted. **Auto-produce the re-pin:** `sha256sum <command_hash_path>` in-container (= the daemon's `actual_hash`), then hand Yaro a clip-wrapped Mac paste — `cp` backup + `sed 's/<expected_hash>/<actual_hash>/' ~/.llm-docker/builder-api.toml` + a `grep` verify. Don't make him compute the hash. Daemon hot-reloads ~1.5s after he saves; then re-dry-run the job to confirm 🟢.
- `4xx` on a placeholder job = regex mismatch (update the sample map above).
- `404` = job missing from host toml.

Flag any non-🟢 in Concerns.

## Output format

### Table 1 — logs (MODE ∈ {logs, all})

| Log | Side | Size | Last write | What it is |
|---|---|---|---|---|

### Table 2 — MCP servers (MODE ∈ {mcp, all})

| Surface | Probe | Result |
|---|---|---|
| slav-ops | `status` 6 experts | 🟢/🔴 + ms |
| slav-ops | `ps` api/vite | 🟢/🔴 pids |
| slav-logs | `list_logs` | 🟢/🔴 + count |
| playwright | tool list | 🟢/🔴 |
| filesystem | `list_allowed_directories` | scope |
| git | `git_status` | branch + clean/dirty |

### Table 3 — build toolchain (MODE ∈ {tools, all})

**3a — real read-only canaries:**

| Surface | Probe | Result |
|---|---|---|
| SSH → prod | real `echo OK` | 🟢/🔴 (hostname) |
| Builder API | `GET /status` | 🟢/🔴 |
| Builder API | `GET /queue` | 🟢/🔴 + depth |
| git | real `git-status` | 🟢/🔴 |
| Postgres | real `pg-status` | 🟢/🔴 |
| venv+Django | real `django-check` | 🟢/🔴 |

**3b — dry-run sweep, ALL jobs:** ALWAYS fire all jobs and ALWAYS print **every job** with its status — never collapse to failures-only, never skip because "verified earlier this session". Yaro wants to SEE the whole catalog tested each run. Lead with the coverage line (`Dry-ran 66/66 jobs: 64 🟢, 2 🔴`), then a compact multi-column grid listing every job (4 per row, alphabetical).

**Ball on the LEFT, columns aligned.** Each cell is `🟢 <job>` (status first) and columns line up vertically — pad job names to a fixed width so the balls form clean left-aligned columns. A green wall reads "all good" at a glance.

```
🟢 build·desktop      🟢 build·ios          🟢 build·web          🟢 db-backup
🟢 db-cleanup-all     🟢 db-query           🟢 deploy·api         🟢 django-check
... (every job, alphabetical, 4 per row, ball-first) ...
```
**Only show a 🔴 line when something actually failed** — `🔴 <job> → <412 drift / 4xx regex / 404 missing>`. If 0 failures, print NO red line at all (no "🔴 detail: none" — it misreads as an error).

## Tone reminders

- **Tables only. No prose between probes.** Gaps go in the reporting footer.
- Anything that fails → 🔴 in the table + one line in `Concerns` (no novel).
- **Never execute** `deploy`, `build-fe`, `e2e`, `db-cleanup-*`, `pip-install`, xcode/swift — dry-run ONLY. The only real runs are the read-only canaries (SSH echo, git-status, pg-status, django-check).
- Don't hit the browser or take screenshots.
- **Never skip the 3b sweep.** Even if it ran green minutes ago, fire all jobs again and print the full grid — Yaro relies on seeing the whole catalog tested every time.

## Known transients — diagnose, don't false-alarm

- **`status` RED on some experts right after edits** = uvicorn `--reload` churn (it watches the whole repo; heavier routes lose the 2s race mid-reload). Re-probe `status` ONCE before alarming. If only some routes recover and others stay dead → real; if all green on re-probe → it was churn (note it, don't flag).
- **`list_logs` returns `[]`** = the `SA_REPO` env leak (host path inside container), NOT a log outage. Hardened in `scripts/mcp/logs-server/index.js`; if it recurs, that fix regressed — read `logs/` directly via `ls` and flag the MCP, don't report "no logs".

After the tables, standard reporting footer per `CLAUDE.md` (Request / Done / Success / Concerns / Optimizations / Hacks / Next steps).
