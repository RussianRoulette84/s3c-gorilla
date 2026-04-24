# Parallel Agents Guide

Two distinct layers. Don't conflate them.

## Layer 1 — Tmux panes (peer Claude sessions)

`cld --tt` opens four independent top-level Claude processes in one
container. Shared FS + git, but no automatic routing. The human
(or @lead via `tmux send-keys`) decides who does what.

### Pane roles

| Pane | Model | Role |
|---|---|---|
| @lead    | Opus  | Orchestrator — holds PLAN.md context, picks concerns, delegates |
| @agent-1 | Opus  | Parallel worker on an independent concern |
| @agent-2 | Opus  | Parallel worker on a second independent concern |
| @agent-3 | Haiku | Fast/cheap runner — tests, lint, file ops, verification |

### Priming prompts (paste on each pane's first turn)

**@lead:**
> You are @lead in the s3c-gorilla tmux-team. Read plan/PLAN.md §1
> (implementation checklist) + plan/BUILD_STRATEGY.md.
> Current branch: `develop`; current phase branch: `phase/1-fanout`
> (create if missing). Your job: pick next unchecked concern from
> PLAN.md §1 by leverage (Concern #33 RSA byte-identical first),
> delegate implementation to @agent-1 or @agent-2 via
> `tmux send-keys -t team:0.1 "…" Enter`, run tests via
> @agent-3-haiku, tick `[x]` + bump success % in PLAN.md on
> close. You never edit src/ directly — workers do that. You do
> edit plan/PLAN.md.

**@agent-1:**
> You are @agent-1. Wait for @lead to paste a concern spec. Work
> only within the file scope @lead names. Keep commits small,
> one concern per commit. Push to `phase/1-fanout`. Run relevant
> tests before committing: `src/tests/run.sh swift` or
> `src/tests/run.sh shell`. No edits to plan/PLAN.md.

**@agent-2:**
> Same as @agent-1.

**@agent-3-haiku:**
> You are @agent-3-haiku — fast/cheap runner. Do ONLY what @lead
> asks: run `./scripts/dev-setup-check.sh`,
> `src/tests/run.sh`, `./scripts/lint.sh`, `git status`,
> `wc -l src/**/*`. No design, no architecture, no multi-file
> refactors. Paste the output. That's the job.

## Layer 2 — Agent tool (in-process subagents within a pane)

Each pane can spawn subagents via the Agent tool for parallel
in-context work. **This doesn't happen by default** — you have to
trigger it explicitly. The triggers below are policy, not
suggestions.

### When to fan out via Agent tool

| Trigger | Subagent | Notes |
|---|---|---|
| Task needs codebase research across ≥3 files BEFORE implementation | `Explore` (built-in) | Specify thoroughness: quick / medium / very thorough |
| Task needs to find callers / dependencies of a symbol | `SCOUT` | scale=2 for typical case, scale=4 for wide hunts |
| About to merge a phase branch | `REVIEW_AGENT` | Run on the diff against `develop` |
| Need external docs / API reference | `FETCH_DOCS` | URL or library name |
| Writing Swift tests | `general-purpose` | Prompt template below |
| Writing bats shell tests | `general-purpose` | Prompt template below |
| Implementing a plan concern that's fully scoped + single-file | **No subagent** — do it directly |

### Stock prompts

**Swift test writer** (via `general-purpose`):
> Write standalone Swift test script(s) matching the project
> pattern in `src/tests/swift/` (no XCTest, no SPM; inline
> `check()` / `skipTest()` / `finish()` harness; one `.swift`
> file per concern; shebang `#!/usr/bin/env swift`). Reference
> the PLAN.md concern number in a header comment. Return only
> the file contents.

**Bats test writer** (via `general-purpose`):
> Write a bats test file for `src/tests/shell/` matching the
> pattern in `test_config_defaults.bats`. Use `skip` for features
> not yet implemented. Reference the PLAN.md concern number.

### Anti-patterns (don't)

- Don't spawn the Agent tool for a one-file edit — direct is faster.
- Don't send design / architecture work to @agent-3-haiku.
- Don't have two panes touch the same file at the same time —
  @lead coordinates file ownership per concern.
- Don't run the Agent tool from @agent-3-haiku — Haiku shouldn't
  dispatch more work.

## Available project agents (in `.claude/agents/`)

- `SCOUT.md` — codebase search, token-efficient, configurable scale
- `TEST_WRITER.md` — pytest-focused (Python); use `general-purpose`
  with the Swift/bats prompts above for this project
- `REVIEW_AGENT.md` — code review
- `FETCH_DOCS.md` — URL → summarized doc

Plus Claude Code built-ins: `Explore`, `general-purpose`,
`Plan`, `review-agent`, `test-writer`, `statusline-setup`.

## Coordination mechanics

- **File ownership**: @lead assigns a concern to a worker and
  names the file(s) they own for that concern. No cross-pane
  edits of the same file.
- **Task handoff**: @lead uses `tmux send-keys` or drops a file
  in `plan/tasks/` (create as needed) for richer briefs.
- **Test gate**: @agent-3-haiku runs the test suite after every
  commit from a worker pane. Red = revert; green = pass control
  back to @lead.
- **Plan updates**: only @lead edits `plan/PLAN.md`. Workers
  don't touch checklist boxes directly.

That's it. No magic. Panes coordinate like people, Agent tool is
the per-pane force multiplier.
