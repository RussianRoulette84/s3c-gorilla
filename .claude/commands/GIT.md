---
description: Generate a Yaro-style changelog entry for the current uncommitted/staged work. Output to chat, not file.
argument-hint: [optional: custom note]
allowed-tools: Bash, Read, mcp__git__git_status, mcp__git__git_diff, mcp__git__git_log
---

# GIT — changelog-style commit message

Generate a changelog block in **Yaro's house style** (matches `~/Projects/purpletech/CHANGELOG.md`) for the current branch's uncommitted/staged/recent work. **Output to chat only — do NOT write to any file. Do NOT run any git write operations.**

## Style — copy this exactly

- Top heading: `# DD/MMM/YYYY` (uppercase 3-letter month: `JAN FEB MAR APR MAY JUN JUL AUG SEP OCT NOV DEC`). **No author / no name suffix** — Yaro is the only one writing, attribution is noise.
- One short intro sentence describing the gist of the release.
- `## Section Name` for each user-facing area touched (e.g. `## URL cleanup`, `## Phil AI`, `## Hanoi`, `## Behind the scenes`).
- `### Dev logs` ALWAYS LAST — internal/technical work (refactors, build/CI, dep pins, file restructure, doc rewrites).
- Bullets start with **one tag in square brackets**, then plain English:
  - `[NEW]` new feature
  - `[BUG]` bug squashed (past tense: "was crashing", "is fixed")
  - `[BUG?]` maybe a bug — needs investigation
  - `[CHANGE]` request to change existing behavior
  - `[TWEAK]` polish / make existing thing better
- **Plain English. No jargon.** Translate technical terms ("regex catastrophic backtrack" → "endpoint was hanging on long responses"). Mention pages/screens, not file paths or function names. Sales/operations users read this.
- **Past tense for fixes** ("was breaking", "is fixed").
- One blank line after the date heading.
- No "TODO" / "Notes for X" footers — pure changelog only.

## Workflow

1. **Inspect what changed.** Use `mcp__git__git_status` and `mcp__git__git_diff` (with `path:"."`) to see uncommitted + staged work. If nothing changed there, fall back to recent commits (`mcp__git__git_log path:"." maxCount:5`) to summarize whatever the user just did.
2. **Group by user-facing area first**, dev-tooling-only stuff second. Routes / UI / auth / behavior changes go in `## ...` sections. Refactors / dep bumps / CI / docs / file moves go under `### Dev logs`.
3. **Write the changelog block in chat.** Wrap it in a `markdown` code fence so the user can copy it.
4. **Don't write files.** Don't run `git commit`/`add`/`push`. Don't suggest committing — that's the user's job (per project rule).

## Output format

```markdown
# DD/MMM/YYYY

<one-line gist>

## <user-facing section 1>
- [TAG] plain-English line
- ...

## <user-facing section 2>
- ...

### Dev logs

#### <subsection if needed>
- [TAG] line
- ...
```

## Tone reminders

- Short. Sales reader. No code paths in the user-facing sections — only in `### Dev logs`.
- If a release is tiny (just one bug fix), one section + one bullet is fine.
- If you weren't actually involved in the work and you can't infer what changed from `git diff`, say so honestly instead of guessing.

After printing the block, follow up with the standard reporting footer per `CLAUDE.md` (Request / Done / Success / Concerns / Optimizations / Hacks / Next steps).
