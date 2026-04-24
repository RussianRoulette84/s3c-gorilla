# Bootstrap Feedback Loop — Autonomous Feedback Loop Setup

You are being asked to perform a ONE-TIME project analysis and setup.
Your goal: make yourself capable of autonomous, self-correcting development in this project — forever after.

---

## PHASE 1 — Project Reconnaissance

Explore the project. Do NOT assume anything. Read the actual files.

**Discover what this project is:**
- Read `package.json`, `Cargo.toml`, `pyproject.toml`, `go.mod`, `pom.xml`, `composer.json` — whatever exists
- Read `docker-compose.yml`, `docker-compose*.yml`, `.env`, `.env.example`
- List all running or startable services (frontend, backend, API, proxy, database, queue, cache, etc.)
- Identify the runtime: Node, Python, Go, Rust, PHP, Java, etc.
- Identify the framework: Vite, Next.js, Express, FastAPI, Django, Laravel, etc.

**Discover what already exists for observability:**
- Search for existing log files: `find . -name "*.log" -not -path "*/node_modules/*" -not -path "*/.git/*"`
- Search for logging config: winston, pino, log4j, python logging, Monolog, slog, zap, etc.
- Search for existing test setup: jest, vitest, pytest, playwright, cypress, go test, etc.
- Search for existing health check endpoints: `/health`, `/status`, `/ping`, `/ready`
- Check if there is a `logs/` or `log/` directory already

**Discover how processes are started:**
- What are the `scripts` in `package.json`? What does `dev`, `start`, `build` do?
- Is there a `Makefile`? A `Procfile`? A `justfile`?
- Are there Docker services? Which ones? What ports?

---

## PHASE 2 — Gap Analysis

Based on what you found, determine what is MISSING for a full feedback loop:

For each discovered service, ask:
- Does it write logs to a file? If not → it needs to.
- Can its crash output be captured? If not → it needs a wrapper.
- Does it have a health check? If not → note it.
- Are browser console errors capturable? (Vite/Next/any frontend) → Playwright smoke test needed if not.

Do NOT blindly install things. Only add what is genuinely missing.

---

## PHASE 3 — Implement the Feedback Loop

Based on your analysis, implement ONLY what is needed. Common implementations:

### Log Capture
- If using a logger already: ensure it writes to `logs/<service>.log` in addition to stdout
- If no logger: add minimal structured logging (single file, not a framework overhaul)
- All log files go to `logs/` at project root

### Process Output Capture
- Modify or create npm/make/shell scripts so that process stdout+stderr is piped: `command 2>&1 | tee logs/<service>.log`
- Do this for EACH service (frontend, backend, worker, proxy, etc.)
- Create a `dev.sh` or add a `dev:logged` script if the existing `dev` script cannot be modified

### Browser Console Capture (Frontend projects only)
- **Vite projects**: Add a custom Vite plugin that (1) injects client-side code to override `console.error` and `console.log`, (2) POSTs captured messages to a dev-only endpoint (e.g. `/__dev-console-log`), (3) adds dev server middleware (prepend to stack so it runs first) to append received messages to `logs/browser-console.log`. Plugin must `apply: 'serve'` so it runs only in dev. Create the plugin file if it doesn't exist.
- **Other frontends (Next.js, etc.)**: equivalent middleware + client injection, or use Playwright smoke test if simpler.
- **Playwright**: If already present, add a smoke test that captures console to `logs/browser-console.log`. Otherwise prefer the Vite plugin approach for Vite projects (no extra deps).

### Database / Queue / Cache Logs
- If PostgreSQL/MySQL/MongoDB in Docker: ensure their container logs are accessible via `docker logs <container> 2>&1 | tee logs/db.log`
- Add this to the dev startup script

### Multi-service Projects
- If docker-compose: add `docker compose logs -f 2>&1 | tee logs/compose.log` to the dev script
- If multiple processes: use a process manager approach (concurrently, honcho, foreman) and pipe all output

---

## PHASE 4 — Write the Project Feedback Manifest

Create a file: `.claude/PROJECT_LOOP.md`

This file must contain the SPECIFIC, DISCOVERED truth about THIS project.

Include a **Log Priority** section: for frontend projects, the browser console log is primary for UI/UX; the frontend build log for compile/crashes; backend logs for API services. Fill with this project's actual log file names.

```
# Project Feedback Loop — [Project Name]

## Services & Their Log Files
[table or list: service, port, log file path, start command]

## How to Start Everything
[exact command(s)]

## How to Check Build Success
[what to look for in which log file]

## How to Detect a Crash
[error patterns per log file]

## How to Run Smoke Tests
[exact command or "none"]

## Health Check Endpoints
[list or "none"]

## Log Priority (for agents)
[which log to check first for UI/UX, for build issues, for backend — use this project's actual log names]

## Known Error Patterns
[fill in after first test run]
```

---

## PHASE 5 — Validate

Actually start the project using the new logged setup.
Read the log files.
Confirm you can see output.
Report back what you found and what you set up.

If something fails during setup: fix it. This is the loop working.

---

## Output

When done, tell the user:
1. What you discovered about the project
2. What was already in place
3. What you added or modified
4. The exact commands to start the project with full logging active
5. That CLAUDE.md feedback loop protocol is now active for this project
