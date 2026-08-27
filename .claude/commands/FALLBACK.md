---
description: slav-ai code archaeology — detect fallback paths, legacy implementations, /chat/ leftovers, and dead code
---

# FALLBACK (slav-ai)

Search the slav-ai repo and identify risky, outdated, or obsolete code paths. **Especially relevant here** — CLAUDE.md bans fallback code and silent-error swallowing, and we just killed the `/chat/` prefix system-wide. This command catches violations + leftovers.

## Scope

- Scan: `src/`, `scripts/`, `docs/`, `tests/`, `vite.config.js`, `.builder-api.toml`, `.mcp.json`, root configs
- Exclude: `node_modules/`, `.git/`, `dist/`, `build/`, `.venv/`, `__pycache__/`, `logs/`, `.Trash-*/`, `phil-ai/` submodule

## Targets

### 1. Fallback Code
Identify code that exists only as a backup or contingency path.

Look for:
- Conditional fallbacks (`if primary fails then X`)
- Silent recovery logic
- Default implementations masking real failures

Examples:
- `try/catch` blocks that swallow errors
- `if (!feature) { legacyPath() }`
- Comments mentioning *fallback*, *backup*, *temporary*, *just in case*

### 2. Legacy Code
Identify code that is still present but no longer aligned with current architecture.

Look for:
- Old APIs, schemas, or protocols
- Versioned logic branches (`v1`, `v2`, `old`, `legacy`)
- Comments indicating historical usage

Examples:
- `legacy_*`, `old_*`, `*_deprecated`
- Conditionals based on outdated flags
- Compatibility layers for removed systems

### 3. Deprecated / Dead Code
Identify code that is unused, unreachable, or explicitly deprecated.

Look for:
- Functions, classes, or files with no references
- Code behind impossible conditionals
- Explicit deprecation markers

Examples:
- `@deprecated`, `TODO remove`, `FIXME remove`
- Feature flags permanently disabled
- Files never imported or executed

## Method

### 1. Static Search
Search for keywords, patterns, and annotations related to fallback, legacy, and deprecation.

### 2. Reference Analysis
Check whether identified functions/files are:
- Imported
- Called
- Used at runtime

### 3. Risk Classification
For each finding, classify:
- **Type**: fallback / legacy / dead
- **Risk**: low / medium / high
- **Removal safety**: safe / needs refactor / dangerous

## slav-ai-specific watchlist

- `/chat/` URL fragments anywhere in `src/` or `vite.config.js` — should only exist in 301-redirect blocks
- `/v1/chat/...` or `/v1/actions/...` — old prefix, dead. Action paths are now `/<expert>/actions/<name>`
- `if not p.exists(): p = ...openapi_smoke.yaml` and similar silent fallbacks (CLAUDE.md "No-Silent-Fallback rule" example)
- `try: ... except: pass` — error swallowing
- `console-filter` additions beyond the documented SVG warning suppression
- Dead expert references after removal (e.g. orphaned `megfigyelo` mentions if it gets removed)
- Legacy paths inside `scripts/`: leftover refs to `apps/`, `.opencode/`, `mcp_server/`, `q3ide`, `llm-docker` (we are not those projects)

## Output

Generate a report:

`./reviews/CODE_FALLBACK_REPORT_YYYY-MM-DD__HH-MM-SS.md`

Each finding must include:
- File path
- Code snippet
- Category (fallback / legacy / dead)
- Why it exists
- Recommendation (keep, refactor, remove)

## Exit Criteria

The command completes when:
- All findings are catalogued
- No code modifications are made automatically
- The report is ready for human review
