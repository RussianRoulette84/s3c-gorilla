---
name: yalo
description: >-
  Autonomous, phased build workflow (YOLO-style) for Claude Code. Drives a project
  from exploration → Q&A planning → ./plans/XX-PLAN.md → phase-by-phase implementation
  with minimal human intervention (optionally in YOLO mode), using Yaro's plan formats and reporting rules.
  Use when the user says "YALO", asks to plan or build a feature in phases, or references
  ./plans/XX-PLAN.md or the control words GO, PLAN, HARDEN, MISSING, IDEAS, FIX, WRAP UP.
---

# YALO

A YOLO-style skill that lets Claude Code drive a project through planning and phased
implementation **without** the developer babysitting every "GO / NEXT PHASE". It also
keeps Claude from derailing from the Goal.

## Modes & control words (read first)

- **PLAN mode** — Q&A only. Claude asks, clarifies, and designs. Claude does **not** write code or the plan file yet.
- **Unrestricted mode** — Claude writes `./plans/XX-PLAN.md` and implements. Phase by phase.
- **YOLO mode** — autopilot: Claude runs unattended through to PHASE N-2, skipping the GO/PLAN/HARDEN decision gates (see Step 8.5). Still stops on blocking gates (missing secrets, destructive actions).
- **Single source of truth** — `./plans/XX-PLAN.md` (checkboxes + completion %) is authoritative. Claude derives "where am I / what's next" from the file, never from memory.
- **Plan gate (manual mode switch).** Claude *cannot* put Claude Code into Plan mode by itself — that's a user toggle (`/plan` for the next turn, or **Shift+Tab twice** for a persistent state; Windows: `Alt+M` or `/plan`). So at every plan boundary — before planning a PHASE (Step 10) and before a HARDEN round — Claude must: **stop all edits**, tell the user to enter Plan mode, present the plan, and **wait**. Claude returns to unrestricted/build only after the user approves (approval also exits Plan mode). Even on auto-accept, Claude presents the plan and waits for an explicit `GO` — it never silently starts building a new phase.
- **Interactive options UI.** Present *every* Q&A and *every* `◘` options menu with the interactive question UI (the `AskUserQuestion` tool) — tappable options, not plain-text bullets. The `◘` lists in this file are the *content* to load into that UI, always keeping a "type your response" free-text choice last.
- **Control words** the user can say at a stop point: `GO`, `PLAN`, `HARDEN`, `MISSING`, `IDEAS`, `FIX`, `WRAP UP`, `YES`, `NO`.

## How Yaro works with Claude

The flow below is the full lifecycle — from first exploration to a finished, signed-off plan.

### Step 0 — Prime (recon)
Before anything else, Claude refreshes its mental model of the project so it doesn't plan blind.
- Read `README.md`, then `CLAUDE.md`, then the relevant module(s).
- Scan `./plans/` for existing/in-progress plans; if resuming one, jump to it instead of starting fresh.
- Create `./plans/` if it doesn't exist and determine the next `XX` counter (highest existing number + 1).
- Note the project's holy rules up front (e.g. no `rm` → `trash`, no git writes) so Step 8+ respects them.

### Step 1 — Explore
User "explores" his options to achieve a certain feature/goal.

### Step 2 — Research the web
User researches the web because Claude is outdated.

### Step 3 — Research GitHub/GitLab/web
User "researches" GitHub/GitLab/web so that we don't have to re-invent the wheel.
- If found, the job becomes a simple feature-layer integration problem and we don't have to implement from scratch.

### Step 4 — Enter PLAN mode (Q&A only)
User switches to PLAN mode and asks Claude to PLAN while "working back and forward with him".
- Based on context, Claude now has a basic idea of what the user wants.
- This is **not** an implementation PLAN yet — it's activated just for the Q&A session.
- Claude doesn't know this yet, but the end result of this plan will be a `./plans/XX-SOME_PLAN.md` file, where `XX` is an incrementing counter.

### Step 5 — Q&A cycles
Claude asks a series of Q&A focusing on specification, architecture, security and design decisions.
- Based on complexity, Claude may repeat Q&A cycles.
- Max 3–4 cycles of 1–4 questions per cycle (totalling MAX 16 questions).
- Claude must think between Q&A cycles to post the next questions properly (based on previous responses).
- Claude should not waste time on straightforward Q&A which a 6-year-old can guess.
- Each question must have 1–5 options, always including a "type your response" option as the last one.
- Claude alerts the user about flaws, inconsistencies, and security flaws during Q&A. Allow the user to acknowledge the risk in Q&A.

### Step 6 — Pick a plan format
As the final question, Claude asks to write this plan to `./plans/XX-SOME_PLAN.md` — in which format? We have 3 formats; Claude must ask which to use:
- **Vanilla plan** — for light plans. Claude creates the plan MD file from scratch.
- **OOP Specification** — for heavy plans. Based on OOP Specification guidelines. See `SPECIFICATION_OOP_TEMPLATE.md`.
- **OOP Design** — based on an *existing specification* we created, for heavy plans involving big systems. Based on OOP Specification guidelines. See `DESIGN_OOP_TEMPLATE_v1.0.md`.

### Step 7 — Lock in decisions
User locks in his final decisions. We are still in PLAN mode. Claude has printed his "overall plan".

### Step 8 — Switch to unrestricted mode, write the plan
Only now the user switches to **unrestricted mode** and Claude starts writing to the MD plan file (which can also be the Specification or Design Template).
- This includes a list of tasks to be done with checkmarks, broken down into PHASES.
- All tasks/phases are logically ordered.
- 1 PHASE is one Claude command prompt.
- Max 7 phases are allowed. If the plan is simple, it's OK to use 1 phase.
- At the top of the plan file include "completed %".
- At the top of the plan file include a "completed phases" table with checkmarks.
- Include "Claude tests" in the plan for Claude self-verification (PHASE N-1).
- Include "User tests" in the plan for self-verification (PHASE N).
- Leave "human intervention" and "reviews" between phases out as much as possible, pushing them to the end (PHASE N). How? By planning execution of Phase 1 … Phase N-1 without human intervention needed to complete. Unless really really needed, leave out:
  - user testing
  - tasks that Claude can do itself (instead of asking the user)
  - tasks that Claude can't do itself
  - adding API keys, secrets

  …leave all of this to the last phase.

### Step 8.5 — Choose where to stop (YOLO selector)
Now that the PHASES are defined, Claude asks one extra Q&A: how far should it run autonomously before stopping for the user? Present the live phase list plus a YOLO option. **YOLO MODE is selected by default.**

```
Where should I stop for you?

◘ PHASE 1 — Pre-requirements done, Skeleton dropped, XY implemented
◘ PHASE 2 — Z feature, Y feature
◘ PHASE 3 — W feature, V feature, U feature
   …
◘ PHASE N-2 — K feature
◘ YOLO MODE (no stop)   ← default
◘ type your response
```

- **YOLO MODE** — run everything autonomously through to **PHASE N-2** (where Claude tests itself and prints the results — see Step 18). No GO/PLAN/HARDEN gates in between. This makes YOLO **optional**: the gated, phase-by-phase flow is the alternative.
- **PHASE X** — run autonomously up to and including PHASE X, then stop and present the Step 15 menu (GO / PLAN / HARDEN).
- The chosen stop point is recorded at the top of `./plans/XX-PLAN.md` (e.g. `mode: YOLO` or `stop_after: PHASE_3`) so the autopilot knows the boundary.
- **YOLO is interruptible at any time.** The user can stop Claude mid-run and ask for **HARDEN** or **PLAN next phase** before execution continues; afterwards YOLO resumes from where it left off.
- YOLO still honors **blocking** gates — missing secrets/API keys (Step 12) and destructive-action confirmations (holy rules) — it only skips the *decision* gates.

### Step 9 — Plan is written (don't execute yet)
The MD file is written for the "overall plan". Claude thinks it's ready to execute the whole plan — but we are **NOT** doing that.

### Step 10 — Plan Phase 1 (+2)
User switches back to PLAN mode and asks Claude to PLAN Phase 1 (and maybe Phase 1+2 if it's NOT big). **Plan gate:** Claude first stops editing and reminds the user to enter Plan mode (`/plan` or Shift+Tab twice) if they aren't already; it presents the plan and waits for approval before touching code.
- Claude plans PHASE 1–2 before implementing.
- This is the time to lay a skeleton code structure for all the features we'll have — class and function definitions, comments, and pragma marks in code so Claude doesn't forget to implement later.
- This is the time to think about the "max 500 lines of code per file" rule, where "200 lines per file is the 'sweet spot' in an ideal, finished state".
- This is the time when Claude thinks about the final implementation plan of Phase 1+2 and asks more questions IF really really needed.

### Step 11 — Lock in the Phase 1+2 plan
User locks in to another set of (max 16) Q&A's for Phase 1+2 → Claude is ready to build this subplan → user hits "Accept Plan" and Claude starts working.

### Step 12 — Pre-install tasks (Phase 1.1, if needed)
Before any code is written again, we "might" stop for "pre-install" tasks ("phase 1.1", if needed):
- Claude asks the user to provide secrets (if any required).
- Claude asks the user to run commands in `CMD | CLIP` format for setup tasks Claude can't do from Docker (if any required).
- Claude messages (copy & paste text) the other Claude Code session running the "llm-docker" project in another terminal to make TOML file changes, so the "LLM Docker API" is fully operational for the tasks to come. Expect the other Claude to message back with "ready" or push-backs.

### Step 12.2 — Pick an agent (if applicable)
Claude asks to use a dedicated agent from `./claude/agents/*` if applicable. Main Agents and sub-agents are a possible solution too.

### Step 13 — Implement
Claude implements Phase 1.2 → Phase 1.X (or maybe even Phase 2 if easy) now that it has everything.

### Step 14 — Finish Phase 1 + report
Claude finishes Phase 1:
- Updates PLAN.md checkmarks, completion %, and adds extra tasks to future phases (if needed and realized while developing).
- The **Plan reporting rule** executes — similar to the "Reporting rule" in CLAUDE.md, where we report what was done, concerns, hacks, next:

```
- Request: PHASE 1 - Pre-requirements done, Skeleton dropped, XY implemented
- Done: PHASE 1
   - Pre-requirements collected (XY_API_KEY, npm install)
   - Skeleton dropped (src/project/main.js and app.js)
   - XY features implemented:
     - X:  feature X was done Z way
     - Y:  feature Y was done Q way
- Success: ⚠️ 98% - only because I did not implement PHASE 2.8
  -> Try to avoid 98% work. Why on earth would you make the user say "Go" to finish the last 2% of Phase 1??? Do not do that!
- Tests: ✅ 10/10 OK
- Logs: ✅ no recent WARNING/ERROR in any of the './logs/*' files
- Concerns: ⚠️ we implemented something badly that could be implemented better or differently
- Hacks: ‼️ I hard coded API keys as fallback because I was an IDIOT, hacked my way through it and did not stop for the user
- Actions suggested: Try by logging in at https://127.0.0.1:3001/login
- Next:
    ◘ say "GO" to build PHASE 2
    ◘ say "PLAN" to plan the next PHASE 3 (+4 if not complicated)
    ◘ say "HARDEN" to see top 20 suggestions for the currently implemented PHASE 1
```

### Step 15 — User decides
- **GO** — Claude continues implementing without planning in detail.
- **PLAN** — plan the next PHASE 3 (+4 if not complicated) with min 0 – max 16 Q&A allowed.
- **HARDEN** — now that Claude just finished Phase 1+2, Claude lists the top 20 things to the user. **Plan gate applies:** before implementing any accepted HARDEN item (whether the user accepts or it's auto-accepted), Claude re-enters the plan gate — stop editing, prompt for Plan mode, present, wait for approval.
  - that it would have implemented better and/or differently.
  - could be missing requirements, features, architecture changes, housekeeping, etc.
  - should NOT include things already in the original PLAN.md.
  - the bullet list must be short, ordered by importance, top 20.
  - the user decides to PLAN everything or just a few things from the bullet list to implement before advancing to the next PHASE.

### Step 16 — Repeat
The "Step 14 → 15" cycle repeats with the next big PHASE until we reach "PHASE N-2" OR user intervention is needed in between (hopefully avoided).

**Parking lot (injected phase).** Bugs or ideas discovered mid-phase must NOT derail the current task. Append them to a parking-lot list, then handle them as a **new phase injected between the current PHASE N and the next PHASE N+1** — renumber the following phases. This keeps the current phase focused and nothing gets lost.

### Step 17 — Housekeeping, testing, documentation
When all PHASES are ready except "PHASE N-1" and "PHASE N-2", we do the "housekeeping", "testing", and "documentation" todos a normal developer would do:
- Run `/compact` if context is more than 66% full.
- Use FEEDBACK_LOOP.md — i.e. run Playwright → login → press buttons, test features, take screenshots → fix low-hanging fruit.
- When crawling the frontend with Playwright OR calling curl to test API calls, and facing any error/warning/inconsistency:
  - use "haiku" sub-agents (max 4) to find bugs in logs and browser console logs.
  - collect them in special tmp files → let the main agent finalize the list of bugs → classify them → order them by prio and risk → make sure it's not a false alarm.
- **Read the logs while browser-testing (this last phase):** actually read `recent_errors` / tail the relevant `./logs/*` and the browser console — never claim "logs clean" unread.
- Write and run final tests. Fix issues.
- Do basic curl calls and security audits on LOCAL and PROD (if any) to test basic functions.
- Update/create docs, MD files, claude.md (if really needed — don't spam it), memory (if really needed — don't spam).
- Make sure no secrets are in code.
- Make sure `.gitignore` is updated correctly.
- Make sure to update CHANGELOG.md with features in plain English, no jargon. Run `.claude/commands/GIT.md` to get uncommitted changelogs in the style Yaro likes.
- Make sure to update `./plans/XX-PLAN.md` → last "TEST" section with extra items for the user to test (unless Claude can do it itself).

### Step 18 — FINAL REPORT

```
- Request: `./plans/XX-PLAN.md` ALL PHASES READY 🔥
- Done: PHASE 1-9
   - PHASE 1: Pre-requirements done, Skeleton dropped, XY implemented
   - PHASE 2: Z implemented
   - PHASE 3: W implemented
   .
   .
   - PHASE N-2: W implemented
- Success: ✅ 100%
- Tests: ‼️ 22/23 OK - Anthropic API tests failed './tests/llm.test'. Missing API key.
   -> try to avoid responding with NOT 100% tests. Don't CHEAT! Why on earth would you make the user say "Fix test" to finish the last 1%??? Do not do that!
- Logs: ✅ no recent WARNING/ERROR in any of the './logs/*' files
- Concerns: we did not "harden" the whole thing
- Hacks: ‼️ I hard coded API keys as fallback because I was an IDIOT, hacked my way through it and did not stop for the user
- Actions suggested: YOU do final tests in `./plans/XX-PLAN.md` -> PHASE 9 -> let me know if something did not work
- Next:
    ◘ say "FIX" to fix the remaining issues, warnings, errors, fallbacks, etc.
    ◘ say "WRAP UP" if your side of testing finished SUCCESSFULLY and we should wrap up:
        -> prepare to commit -> push
        -> final CHANGELOG.md update
        -> various "housekeeping" tasks
        -> final 'llm-docker api' update requests to other Claude (if needed)
        -> final 'docs' update
        -> final security audit where Claude shows a summary of 3 commands to the user inside Claude Code:
            - `.claude/commands/security_audit.md`
            - `.claude/commands/security_endpoints_test.md`
            - `.claude/commands/security_files.md`
    ◘ say "HARDEN" to see top 20 suggestions for the current implementation step
```

### Step 19 — Compact
Whatever happens, run `/compact` at the end IF context is more than 66% full.

### Step 20 — Are we done?
Claude asks one question:

```
Are we all done?

◘ say "YES" to move the plan to ./plans/doneXX-PLAN.md
◘ say "NO" to continue talking
◘ say "HARDEN" to see top 20 suggestions for the already-implemented ./plans/XX-PLAN.md where we could do a better job or implement something differently.
◘ say "MISSING" to see top 20 ideas we were stupid enough not to think about and that are considered basic.
◘ say "IDEAS" to see top 20 ideas we could add, implement, or change. New ideas. Wild too. Think out of the box here. Don't even look at the code. Think of "omg why did I not think about this" ideas.
```

## Rules

- Never ask the user to commit or push, unless it's really unavoidable. Example: we need to test on PROD and for that we need to commit → push → deploy.
- Work as autonomously as possible. Expect the user to run this in a loop until we reach PHASE N-1. If you have concerns/issues meanwhile, add them to the PLAN to deal with them later.
- **`./plans/XX-PLAN.md` is the single source of truth.** Update checkmarks and completion % after every task/phase. On resume, re-derive position from the checkboxes — never from memory.
- **Failure budget:** max 4 attempts on the same error/task, then STOP and ask the user one specific question. Don't rewrite unrelated code while blocked, and don't silently retry forever. **In YOLO, hitting the budget halts the autopilot** (don't loop and burn tokens) — park the blocker and ask.
- **Don't fake "tests pass."** Read the actual `./logs/*` and command output. If you didn't run it, say so.
- **Files:** 200 lines is the sweet spot, 500 is the hard cap. Flag offenders when touched and propose a real split.
- **Compact:** run `/compact` whenever context exceeds ~66% full — mid-run too, not only at the end. Make sure PLAN.md state is current first so nothing is lost.
- **Before any destructive or silencing action** (deleting/overwriting configs, stopping services, disabling alerts): back up first, state exactly what will be lost, and wait for confirmation. Use `trash`, never `rm`.
- **Snapshot before risky edits.** Before schema/config/destructive changes, take a quick checkpoint/backup so a bad YOLO step is reversible. Auto-delete snapshots older than 1 week so they don't pile up.

## Per-phase discipline (tests & Definition of Done)

- **Tests first.** The first task of every phase is "define the acceptance tests." The phase isn't started until those tests exist **and fail** — then code until they pass.
- **Run tests after every task**, not just at the end. Fold a test + lint run into the loop so YOLO catches breakage mid-phase, not at PHASE N-2.
- **Definition of Done (per phase):** tests green, lint 0, no new WARNING/ERROR in `./logs/*`. A phase isn't done until all of these hold.
- **No box on unverified work.** A `- [ ]` becomes `- [x]` only after its check ran green — never on "looks done."
- **Smoke test the real thing.** Before declaring 100%, hit the actual endpoint/UI (curl or browser), not just unit tests.
- **Changelog as you go.** Append a plain-English line per phase (see `.claude/commands/GIT.md` style) — don't dump the whole changelog only at WRAP UP.

## YOLO autopilot — Stop hook

YOLO can't drive itself from the skill text alone. Claude ends its turn after each chunk; the only thing that re-fires it is a **Stop hook**. Without the hook, YOLO = you pressing `GO` every time.

**How it works:** one plan file at a time is "armed" by writing `Mode: YOLO` in its header. On every turn-end the hook finds that file and checks for unchecked `- [ ]` boxes.
- Armed plan + tasks still unchecked → force Claude to keep going.
- No armed plan, or all boxes checked → let Claude stop.

**Arm** = put `Mode: YOLO` in the active plan's header. **Disarm** = remove it, or check all the boxes. Only one plan should carry the marker at a time.

Add to `.claude/settings.json`:

```json
{
  "hooks": {
    "Stop": [
      { "hooks": [{ "type": "command", "command": "p=$(grep -liE '^[[:space:]]*(\\*\\*)?mode:?(\\*\\*)?[[:space:]]*`?yolo' plans/[0-9]*-*.md 2>/dev/null | head -1); [ -z \"$p\" ] && exit 0; grep -qE '^[[:space:]]*- \\[ \\]' \"$p\" && { echo \"YOLO: unchecked tasks remain in $p. Do the next one, edit that file ONLY, never create a new plan. Tick boxes + update %.\" >&2; exit 2; }; exit 0" }] }
    ]
  }
}
```

Restart Claude Code after adding it (hooks load at startup). `exit 2` is the lever — for a Stop hook it means "don't stop, keep working." The hook only controls continue-vs-stop; "edit one file, never branch" is a request it passes to Claude, not something it enforces.

SPECIFICATION_OOP_TEMPLATE_v1.0.md
=================================
# JobSite Link — Software Specification (OOP Skeleton)

> Based on the OMG UML 2.5.1 formal specification structure (Booch, Rumbaugh, Jacobson).
> This is a skeleton template — fill sections as the platform is built.

---

## Front Matter

### 1. Scope

> Define the boundaries of the JobSiteLink platform — what it covers and what it explicitly does not.

- **In scope:** AI avatar onboarding, candidate profiles, certification tracking, employer matching, trade school pipeline, brand advertising, reentry pipeline
- **Out of scope:** Payroll processing, benefits administration, time tracking, general staffing (non-trades)
- **System type:** Vertical AI-powered workforce ecosystem for US skilled trades
- **Stakeholder groups:** Job seekers, employers, trade schools, brand advertisers, platform administrators

---

### 2. Conformance

> How implementations are validated against this specification.

- **2.1 API Conformance** — All endpoints must implement the defined request/response schemas
- **2.2 Data Model Conformance** — Database must implement all required entities and relationships
- **2.3 Behavioral Conformance** — AI avatar interactions must follow defined conversation flows
- **2.4 Security Conformance** — All auth, encryption, and compliance requirements must be met
- **2.5 Notation Conformance** — All diagrams follow UML 2.5 notation standards

---

### 3. Normative References

> Standards and specifications this document depends on.

| Reference | Version | Description |
|-----------|---------|-------------|
| OMG UML | 2.5.1 | Unified Modeling Language specification |
| IEEE 1016 | 2009 | Software Design Descriptions standard |
| OpenAPI | 3.1 | REST API specification format |
| JSON Schema | Draft 2020-12 | Data validation schema |
| OAuth 2.0 | RFC 6749 | Authorization framework |
| OSHA Standards | 29 CFR 1926 | Construction industry safety standards |
| Davis-Bacon Act | 40 USC §3141–3148 | Prevailing wage requirements |
| FCRA | 15 USC §1681 | Fair Credit Reporting Act (background checks) |
| COPPA | 15 USC §6501–6506 | Children's Online Privacy Protection |

---

### 4. Terms and Definitions

> Domain-specific terminology used throughout.

| Term | Definition |
|------|-----------|
| **Apprentice** | Entry-level tradesperson enrolled in a structured training program (3–5 years, 8,000 OJT hours typical) |
| **Journeyman** | Fully qualified tradesperson who has completed apprenticeship and passed state exam |
| **Master** | Journeyman with 2–4 additional years + separate exam; can pull permits and supervise |
| **Foreman** | On-site crew leader; manages day-to-day work of 2–20 tradespeople |
| **Superintendent** | Manages multiple foremen across a project or multiple projects |
| **GC** | General Contractor — prime contractor on a construction project |
| **Sub** | Subcontractor — specialty trade contractor working under a GC |
| **JATC** | Joint Apprenticeship and Training Committee — union apprenticeship body |
| **CBA** | Collective Bargaining Agreement — union contract governing wages, hours, conditions |
| **COI** | Certificate of Insurance — proof of workers' comp and general liability coverage |
| **Match Score** | Platform-computed 0–100% compatibility between candidate profile and job requirements |
| **Gap Report** | List of missing certifications/skills with recommended remediation path |
| **Prevailing Wage** | Government-mandated minimum wage rate for each trade classification on public projects |
| **Davis-Bacon** | Federal law requiring prevailing wages on federal construction contracts over $2,000 |
| **OSHA 10/30** | Occupational Safety and Health Administration training cards (10-hour or 30-hour) |
| **EPA 608** | Federal certification for refrigerant handling (HVAC) |
| **ATS** | Applicant Tracking System |
| **OJT** | On-the-Job Training hours |

---

### 5. Notational Conventions

- **SHALL** — absolute requirement
- **SHOULD** — recommended but not mandatory
- **MAY** — optional
- All diagrams use UML 2.5 notation
- Data models use PostgreSQL-compatible types
- API contracts use OpenAPI 3.1 format

---

### 6. Additional Information

#### 6.1 Architectural Alignment
- Platform follows a modular monolith architecture (Phase 1–2), with service extraction planned for Phase 3+
- AI subsystem is multi-model (GPT-4o / Claude for conversation, lightweight models for matching)
- Voice pipeline: STT (Whisper/Azure) → LLM → TTS (ElevenLabs/Azure)

#### 6.2 On the Semantics of This Specification
- **6.2.1 Models and What They Model** — Each section defines entities (what exists), behaviors (what happens), and constraints (what must hold true)
- **6.2.2 Structural vs. Behavioral** — Structural sections define data models; behavioral sections define workflows and state machines
- **6.2.3 Stable vs. Transient** — Stable semantics = data at rest (profiles, certs); Transient = runtime behavior (avatar conversation, matching engine)

#### 6.3 How to Read This Specification
Each technical section follows this format:
1. **Summary** — What this area covers
2. **Abstract Syntax** — Data model / entity definitions
3. **Semantics** — Business rules and meaning
4. **Notation** — UML diagrams
5. **Examples** — Concrete instances
6. **Entity Descriptions** — Detailed field-level specs
7. **Relationship Descriptions** — How entities connect

---

## Structural Modeling

### 7. Common Structure

> Foundation entities shared across all subsystems.

#### 7.1 Summary
Base types, identifiers, relationships, and constraints used by every module.

#### 7.2 Root Entities
- `Entity` — base class: `id` (UUID), `created_at`, `updated_at`, `is_deleted`
- `AuditableEntity` — extends Entity: `created_by`, `modified_by`, `version`
- `Comment` — freeform annotation on any entity
- `Relationship` — abstract base for all associations

#### 7.3 Templates
- [ ] Define generic query/filter patterns reusable across all search endpoints
- [ ] Define pagination, sorting, and field selection templates

#### 7.4 Namespaces
- `core` — shared base types
- `candidate` — job seeker domain
- `employer` — employer domain
- `school` — trade school domain
- `certification` — cert tracking domain
- `matching` — match scoring engine
- `advertising` — brand ad engine
- `avatar` — AI conversation engine
- `admin` — platform administration

#### 7.5 Types and Multiplicity
- [ ] Define all custom types: `TradeType`, `CertificationType`, `StateCode`, `MatchScore`, `ClassificationLevel`
- [ ] Define multiplicity rules: one-to-many (employer → jobs), many-to-many (candidate ↔ certifications)

#### 7.6 Constraints
- [ ] Business rules expressed as invariants (e.g., "Match Score SHALL be 0–100")
- [ ] Certification expiration rules per type
- [ ] Journeyman-to-apprentice ratio constraints per state

#### 7.7 Dependencies
- [ ] Module dependency graph
- [ ] External service dependencies (OSHA API, state licensing DBs, payment gateway)

---

### 8. Values

> Literals, expressions, time, and measurement types.

#### 8.1 Summary
Value types for scores, dates, currencies, distances, durations.

#### 8.2 Literals
- `MatchScore` — Integer 0–100
- `GapSeverity` — Enum: `critical`, `moderate`, `minor`
- `Currency` — USD, stored as integer cents
- `Distance` — miles from job site, computed from coordinates
- `Duration` — project length in weeks/months

#### 8.3 Expressions
- [ ] Match scoring formula: `Score = (CertMatch × 0.35) + (SkillMatch × 0.30) + (ExperienceMatch × 0.20) + (LocationMatch × 0.15)`
- [ ] Gap report generation rules

#### 8.4 Time
- `CertExpirationDate` — with 30/60/90-day alert thresholds
- `ProjectStartDate`, `ProjectEndDate`
- `AvailableFromDate` — candidate seasonal availability
- `LicenseRenewalDate` — state license renewal cycle

#### 8.5 Intervals
- [ ] Apprenticeship progression intervals (year 1–5)
- [ ] Drug test validity window
- [ ] Background check validity window

---

### 9. Classification

> Core classifier taxonomy: profiles, features, properties, operations.

#### 9.1 Summary
How entities are classified, specialized, and related.

#### 9.2 Classifiers

##### 9.2.1 Person Classifiers
```
Person (abstract)
  ├── Candidate
  │     ├── Apprentice
  │     ├── Journeyman
  │     ├── Master
  │     ├── Foreman
  │     └── Superintendent
  ├── Employer
  │     ├── GCAdmin (General Contractor)
  │     ├── SubAdmin (Subcontractor)
  │     └── HiringManager
  ├── SchoolAdmin
  └── PlatformAdmin
```

##### 9.2.2 Organization Classifiers
```
Organization (abstract)
  ├── EmployerOrg
  │     ├── GeneralContractor
  │     └── Subcontractor
  ├── TradeSchool
  ├── Union
  │     └── LocalUnion
  ├── CertificationBody
  └── BrandAdvertiser
```

##### 9.2.3 Work Classifiers
```
WorkItem (abstract)
  ├── JobPosting
  ├── Project
  ├── CrewAssignment
  └── Application
```

#### 9.3 Features
- [ ] Define structural features (attributes) for each classifier
- [ ] Define behavioral features (operations) for each classifier

#### 9.4 Properties
- [ ] Candidate properties: trade, classification_level, years_experience, travel_radius, availability_date, union_affiliation, languages, physical_capabilities, tools_owned
- [ ] JobPosting properties: trade, classification_required, location, pay_range, project_dates, certs_required, prevailing_wage, union_only, per_diem, lodging_provided, tools_provided
- [ ] Certification properties: type, issuing_body, state, issue_date, expiration_date, verification_status

#### 9.5 Operations
- [ ] `calculateMatchScore(candidate, jobPosting) → MatchScore`
- [ ] `generateGapReport(candidate, jobPosting) → GapReport`
- [ ] `verifyCertification(cert) → VerificationResult`
- [ ] `buildCrewRecommendation(jobPosting, constraints) → Crew[]`

#### 9.6 Generalization Sets
- [ ] Trade hierarchy: `Trade` → `Electrical`, `Plumbing`, `HVAC`, `Welding`, `Concrete`, `Carpentry`, `Ironwork`, `Roofing`, `Pipefitting`, `TreeWork`, `Asphalt`
- [ ] Certification hierarchy: `Certification` → `SafetyCert`, `TradeLicense`, `MedicalClearance`, `BackgroundCheck`

#### 9.7 Instances
- [ ] Example candidate profiles (apprentice electrician in FL, journeyman plumber in TX)
- [ ] Example job postings (prevailing wage electrician, open shop HVAC, crew of 5 for concrete pour)

---

### 10. Simple Classifiers

> Data types, signals, interfaces.

#### 10.1 Summary
Enumerations, primitive types, and interface contracts.

#### 10.2 Data Types / Enumerations
```
TradeType:         ELECTRICAL | PLUMBING | HVAC | WELDING | CONCRETE |
                   CARPENTRY | IRONWORK | ROOFING | PIPEFITTING |
                   TREE_WORK | ASPHALT | HEAVY_EQUIPMENT | OTHER

ClassificationLevel: APPRENTICE_1 | APPRENTICE_2 | APPRENTICE_3 |
                     APPRENTICE_4 | APPRENTICE_5 | JOURNEYMAN |
                     MASTER | FOREMAN | SUPERINTENDENT

CertType:          OSHA_10 | OSHA_30 | CPR_FIRST_AID | EPA_608 |
                   CONFINED_SPACE | FALL_PROTECTION | SCAFFOLD |
                   AERIAL_LIFT | FORKLIFT | RESPIRATORY_FIT |
                   STATE_ELECTRICAL | STATE_PLUMBING | STATE_HVAC |
                   STATE_GC_LICENSE | DRUG_TEST | BACKGROUND_CHECK

CertStatus:        ACTIVE | EXPIRING_SOON | EXPIRED | PENDING_VERIFICATION |
                   VERIFIED | REJECTED

ApplicationStatus: DRAFT | SUBMITTED | VIEWED | SHORTLISTED |
                   INTERVIEW_SCHEDULED | OFFERED | HIRED | REJECTED |
                   WITHDRAWN

ProjectStatus:     PLANNING | MOBILIZING | ACTIVE | PUNCH_LIST | COMPLETED

LanguageCode:      EN | ES | OTHER

PayType:           HOURLY | SALARY | PREVAILING_WAGE | PER_DIEM_INCLUDED

UnionStatus:       UNION_MEMBER | WILLING_OPEN_SHOP | OPEN_SHOP_ONLY | EITHER

PhysicalCapability: HEIGHT_COMFORT | CONFINED_SPACE_CLEARED |
                    RESPIRATOR_CLEARED | LIFT_50LB | LIFT_75LB | LIFT_100LB
```

#### 10.3 Signals
- [ ] `CertExpiringSignal` — fired 30/60/90 days before expiration
- [ ] `NewMatchSignal` — fired when a new job matches candidate criteria
- [ ] `ApplicationStatusChangedSignal`
- [ ] `CrewAvailabilityChangedSignal`

#### 10.4 Interfaces
- [ ] `IMatchEngine` — `calculateScore()`, `generateGapReport()`, `rankCandidates()`
- [ ] `ICertVerifier` — `verify()`, `checkExpiration()`, `lookupStateDB()`
- [ ] `IAvatarEngine` — `startConversation()`, `extractProfile()`, `respondVoice()`
- [ ] `INotificationService` — `sendSMS()`, `sendEmail()`, `sendPush()`, `sendTelegram()`
- [ ] `IAdEngine` — `matchAd()`, `trackImpression()`, `trackConversion()`

---

### 11. Structured Classifiers

> Internal structure, classes, associations, components, collaborations.

#### 11.1 Summary
How major subsystems are composed and connected.

#### 11.2 Structured Classifiers — Internal Structure
- [ ] Candidate subsystem internal structure
- [ ] Employer subsystem internal structure
- [ ] Matching engine internal structure

#### 11.3 Ports and Interfaces
- [ ] External API ports (REST endpoints)
- [ ] Internal service ports (matching engine, cert verifier, avatar engine)
- [ ] Third-party integration ports (OSHA API, state DBs, payment gateway, notification services)

#### 11.4 Classes — Core Domain Model
- [ ] `Candidate` class — full attribute and method specification
- [ ] `EmployerOrg` class
- [ ] `JobPosting` class
- [ ] `Application` class
- [ ] `Certification` class
- [ ] `MatchResult` class (score + gap report)
- [ ] `CrewAssignment` class
- [ ] `Project` class
- [ ] `TradeSchool` class
- [ ] `Referral` class
- [ ] `Rating` class
- [ ] `AdCampaign` class

#### 11.5 Associations
- [ ] Candidate ↔ Certification (many-to-many)
- [ ] Candidate ↔ Application ↔ JobPosting
- [ ] Candidate ↔ Referral ↔ Candidate/Employer
- [ ] JobPosting ↔ EmployerOrg
- [ ] JobPosting ↔ Project
- [ ] CrewAssignment ↔ Candidate[] + JobPosting
- [ ] TradeSchool ↔ Candidate (enrollment pipeline)
- [ ] Rating: Employer → Candidate (post-project)
- [ ] Rating: Candidate → Employer (bidirectional)
- [ ] AdCampaign ↔ BrandAdvertiser

#### 11.6 Components
```
┌─────────────────────────────────────────────────────────┐
│                    JobSiteLink Platform                  │
├────────────┬────────────┬───────────┬───────────────────┤
│  Avatar    │  Matching  │   Cert    │   Notification    │
│  Engine    │  Engine    │   Engine  │   Service         │
├────────────┼────────────┼───────────┼───────────────────┤
│  Candidate │  Employer  │  School   │   Advertising     │
│  Service   │  Service   │  Service  │   Engine          │
├────────────┴────────────┴───────────┴───────────────────┤
│              Core (Auth, DB, Config, Audit)              │
└─────────────────────────────────────────────────────────┘
```

#### 11.7 Collaborations
- [ ] "Candidate Onboarding" collaboration (Avatar + CertEngine + CandidateService)
- [ ] "Job Matching" collaboration (MatchEngine + CandidateService + EmployerService)
- [ ] "Crew Building" collaboration (MatchEngine + EmployerService + NotificationService)
- [ ] "School Pipeline" collaboration (SchoolService + CandidateService + NotificationService)

---

### 12. Packages

> Module grouping, models, profiles.

#### 12.1 Package Hierarchy
```
jobsitelink/
├── core/               # Base types, auth, config, audit
├── candidate/          # Candidate profiles, portfolios, availability
├── employer/           # Employer orgs, job postings, crew management
├── school/             # Trade school admin, enrollment pipeline
├── certification/      # Cert wallet, verification, state requirements
├── matching/           # Match scoring, gap reports, recommendations
├── avatar/             # AI conversation, profile extraction, voice
├── advertising/        # Brand campaigns, targeting, analytics
├── notification/       # SMS, email, push, Telegram, WhatsApp
├── referral/           # Trust network, ratings, endorsements
├── compliance/         # Background checks, E-Verify, Davis-Bacon
├── analytics/          # Market intelligence, platform metrics
└── admin/              # Platform administration, moderation
```

#### 12.2 Package Dependencies
- [ ] Dependency matrix (which packages depend on which)
- [ ] Layering rules (who can call whom)

#### 12.3 Profiles
- [ ] Security profile (auth stereotypes, encryption requirements)
- [ ] Compliance profile (FCRA, COPPA, Davis-Bacon stereotypes)
- [ ] Integration profile (third-party API stereotypes)

---

## Behavioral Modeling

### 13. Common Behavior

> Foundation for all behavioral specifications.

#### 13.1 Summary
Events, triggers, and behavioral patterns shared across subsystems.

#### 13.2 Behaviors
- [ ] Request-response behavior (API endpoints)
- [ ] Event-driven behavior (cert expiration, new match, status change)
- [ ] Conversational behavior (avatar multi-turn dialogue)
- [ ] Scheduled behavior (daily job scan, weekly digest, cert expiration check)

#### 13.3 Events
| Event | Trigger | Handler |
|-------|---------|---------|
| `CandidateProfileCompleted` | Avatar finishes onboarding | Run initial matching |
| `CertificationExpiring` | Daily cron detects 30/60/90 day threshold | Send notification |
| `NewJobPosted` | Employer creates posting | Run matching against all candidates |
| `ApplicationStatusChanged` | Employer updates application | Notify candidate |
| `MatchScoreUpdated` | Candidate adds cert or experience | Recalculate all active matches |
| `CrewMemberUnavailable` | Worker declines or becomes unavailable | Suggest replacement |
| `ProjectStartApproaching` | 7 days before project start | Verify crew certs are current |

---

### 14. State Machines

> Finite state behavior for key entities.

#### 14.1 Summary
State machines for entities with well-defined lifecycles.

#### 14.2 Candidate Profile State Machine
```
[New] → (avatar starts) → [Onboarding]
  → (profile extracted) → [ProfileComplete]
  → (certs uploaded) → [CertsPending]
  → (certs verified) → [Verified]
  → (matched to jobs) → [Active]
  → (hired) → [Placed]
  → (project ends) → [Available]
  → (inactive 90+ days) → [Dormant]
```

#### 14.3 Application State Machine
```
[Draft] → (submitted) → [Submitted]
  → (employer views) → [Viewed]
  → (shortlisted) → [Shortlisted]
  → (interview scheduled) → [InterviewScheduled]
  → (offer made) → [Offered]
  → (accepted) → [Hired]
  → (rejected at any stage) → [Rejected]
  → (candidate withdraws) → [Withdrawn]
```

#### 14.4 Certification State Machine
```
[Uploaded] → (admin reviews) → [PendingVerification]
  → (verified) → [Active]
  → (30 days to expiry) → [ExpiringSoon]
  → (expired) → [Expired]
  → (renewed) → [Active]
  → (rejected by admin) → [Rejected]
```

#### 14.5 Job Posting State Machine
```
[Draft] → (published) → [Open]
  → (candidates matched) → [Matching]
  → (crew assembled) → [Filled]
  → (project starts) → [Active]
  → (project ends) → [Completed]
  → (employer closes early) → [Closed]
```

#### 14.6 Crew Assembly State Machine
```
[Assembling] → (all slots filled) → [Ready]
  → (member drops) → [Assembling]
  → (project starts) → [Deployed]
  → (project ends) → [Disbanded]
```

#### 14.7 School Pipeline Lead State Machine
```
[Discovered] → (AI identifies interest) → [Qualified]
  → (school contacted) → [Contacted]
  → (application started) → [Applied]
  → (enrolled) → [Enrolled]
  → (completed program) → [Graduated]
  → (placed in job) → [Placed]
```

---

### 15. Activities

> Procedural and dataflow behavior — key workflows.

#### 15.1 Summary
Activity diagrams for primary platform workflows.

#### 15.2 Candidate Onboarding Activity
```
[Start] → Avatar greets candidate
  → Avatar asks about trade interest
  → Avatar asks about experience level
  → Avatar asks about certifications held
  → Avatar asks about location + travel willingness
  → Avatar asks about availability
  → Avatar asks about physical capabilities
  → Avatar asks about union preference
  → Avatar asks about tools owned
  → (if reentry) Avatar asks about reentry-specific needs
  → Profile extracted as structured JSON
  → Profile saved to DB
  → Cert gap detection runs
  → Gap report generated
  → Initial job matching runs
  → Candidate notified of matches
[End]
```

#### 15.3 Job Matching Activity
```
[Trigger: new job posted OR candidate profile updated]
  → Load candidate profile
  → Load job requirements
  → Calculate cert match % (required vs. held)
  → Calculate skill match % (trade + experience)
  → Calculate experience match % (years + project types)
  → Calculate location match % (distance + travel willingness)
  → Weighted sum → Match Score
  → Generate Gap Report (missing certs/skills)
  → Store MatchResult
  → If score > threshold → notify candidate + employer
[End]
```

#### 15.4 Crew Building Activity
```
[Trigger: employer requests crew of N]
  → Load job requirements (trade, certs, location, dates)
  → Check "trusted workers" list first
  → For each slot: rank candidates by Match Score
  → Check journeyman/apprentice ratio constraints
  → Propose crew to employer
  → Employer approves / modifies
  → Send outreach to selected workers
  → Workers accept / decline
  → (if decline) → suggest replacement
  → All slots filled → crew marked Ready
[End]
```

#### 15.5 Certification Verification Activity
```
[Trigger: candidate uploads cert]
  → Validate file (image/PDF, size, format)
  → Extract cert type, issuing body, dates (OCR or manual)
  → If state license → attempt API verification against state DB
  → If OSHA card → validate card format + OSHA trainer lookup
  → Queue for admin review
  → Admin approves / rejects
  → Update cert status
  → Recalculate all active Match Scores for this candidate
  → Notify candidate of verification result
[End]
```

#### 15.6 School Pipeline Activity
```
[Trigger: AI avatar identifies candidate interested in training]
  → Match candidate to relevant trade school programs
  → Filter by: location, trade, cost, financial aid eligibility
  → Present options to candidate
  → Candidate selects program(s) of interest
  → Pre-fill school application from candidate profile
  → Notify school admin of qualified lead
  → School admin reviews + contacts candidate
  → Track: contacted → applied → enrolled → completed → placed
[End]
```

#### 15.7 Brand Advertising Activity
```
[Trigger: candidate reaches career moment]
  → Identify career stage (exploring, training, applying, hired)
  → Identify trade type + geography
  → Query active ad campaigns matching criteria
  → Select highest-bid matching campaign
  → Serve ad to candidate (in-app, notification, or email)
  → Track impression
  → If clicked → track conversion
  → Report to brand dashboard
[End]
```

---

### 16. Actions

> Fundamental behavioral units — API operations.

#### 16.1 Summary
Atomic actions exposed as API endpoints.

#### 16.2 Candidate Actions
- [ ] `createCandidateProfile(profileData) → Candidate`
- [ ] `updateCandidateProfile(candidateId, updates) → Candidate`
- [ ] `uploadCertification(candidateId, certData, file) → Certification`
- [ ] `setAvailability(candidateId, availableFrom, travelRadius) → void`
- [ ] `getMyMatches(candidateId, filters) → MatchResult[]`
- [ ] `applyToJob(candidateId, jobPostingId) → Application`
- [ ] `withdrawApplication(applicationId) → void`

#### 16.3 Employer Actions
- [ ] `createJobPosting(employerOrgId, jobData) → JobPosting`
- [ ] `searchCandidates(filters, sort) → CandidateResult[]`
- [ ] `viewCandidateProfile(candidateId) → CandidateProfile + MatchScore + GapReport`
- [ ] `shortlistCandidate(applicationId) → Application`
- [ ] `scheduleInterview(applicationId, datetime) → Interview`
- [ ] `makeOffer(applicationId, offerData) → Offer`
- [ ] `buildCrew(jobPostingId, requirements) → CrewRecommendation`
- [ ] `rateWorker(candidateId, projectId, ratingData) → Rating`
- [ ] `rehireFromPrevious(projectId) → Candidate[]`

#### 16.4 School Actions
- [ ] `viewPipeline(schoolId, filters) → PipelineLead[]`
- [ ] `updateLeadStatus(leadId, status) → PipelineLead`
- [ ] `getAcquisitionMetrics(schoolId, dateRange) → Metrics`

#### 16.5 Avatar Actions
- [ ] `startConversation(sessionId, language) → ConversationState`
- [ ] `processUtterance(sessionId, audioBlob) → AvatarResponse`
- [ ] `processText(sessionId, text) → AvatarResponse`
- [ ] `extractProfile(sessionId) → CandidateProfileDraft`
- [ ] `confirmProfile(sessionId, candidateId) → Candidate`

#### 16.6 Matching Actions
- [ ] `calculateMatchScore(candidateId, jobPostingId) → MatchScore`
- [ ] `generateGapReport(candidateId, jobPostingId) → GapReport`
- [ ] `rankCandidatesForJob(jobPostingId, limit) → RankedCandidate[]`
- [ ] `rankJobsForCandidate(candidateId, limit) → RankedJob[]`
- [ ] `batchRecalculate(trigger) → void`

#### 16.7 Notification Actions
- [ ] `sendSMS(recipientId, message) → DeliveryResult`
- [ ] `sendEmail(recipientId, template, data) → DeliveryResult`
- [ ] `sendPush(recipientId, title, body) → DeliveryResult`
- [ ] `sendTelegram(recipientId, message) → DeliveryResult`
- [ ] `sendWhatsApp(recipientId, message) → DeliveryResult`

#### 16.8 Compliance Actions
- [ ] `initiateBackgroundCheck(candidateId, consent) → BackgroundCheck`
- [ ] `checkEVerifyStatus(candidateId) → EVerifyResult`
- [ ] `exportCertifiedPayroll(projectId, weekEnding) → WH347`
- [ ] `validatePrevailingWage(jobPostingId, state, county, trade) → WageDetermination`

---

### 17. Interactions

> Message-based behavioral specifications — key sequences.

#### 17.1 Summary
Sequence diagrams for critical user journeys.

#### 17.2 Candidate Onboarding Sequence
```
Candidate → Avatar: "I want to find work"
Avatar → LLM: processUtterance(audio)
LLM → Avatar: response + extracted fields
Avatar → Candidate: asks about trade
Candidate → Avatar: "I'm a 3rd year electrical apprentice"
Avatar → ProfileBuilder: extractTradeInfo()
ProfileBuilder → CertEngine: checkRequiredCerts(ELECTRICAL, FL)
CertEngine → ProfileBuilder: requiredCerts[]
Avatar → Candidate: "Do you have OSHA 10?"
... (multi-turn)
ProfileBuilder → DB: saveProfile()
MatchEngine → DB: calculateInitialMatches()
NotificationService → Candidate: "5 jobs match your profile"
```

#### 17.3 Employer Search → Hire Sequence
```
Employer → Platform: searchCandidates(trade=ELECTRICAL, state=FL)
Platform → MatchEngine: rankCandidates(jobPostingId)
MatchEngine → Platform: rankedList[]
Platform → Employer: display ranked candidates + scores + gaps
Employer → Platform: shortlist(candidateId)
Platform → Candidate: notification("You've been shortlisted")
Employer → Platform: scheduleInterview(candidateId, datetime)
Platform → Candidate: notification("Interview scheduled")
Employer → Platform: makeOffer(candidateId, offerData)
Platform → Candidate: notification("Offer received")
Candidate → Platform: acceptOffer()
Platform → Employer: notification("Offer accepted")
Platform → MatchEngine: markPlaced(candidateId)
```

#### 17.4 Crew Building Sequence
```
Foreman → Platform: buildCrew(jobPostingId, {journeymen: 2, apprentices: 3})
Platform → MatchEngine: findCrewCandidates(requirements)
MatchEngine → Platform: check trusted workers first
Platform → Foreman: proposed crew (5 workers, scores, availability)
Foreman → Platform: approve 4, replace 1
Platform → MatchEngine: findReplacement(slot, constraints)
Platform → Foreman: replacement candidate
Foreman → Platform: approveAll()
Platform → NotificationService: batchOutreach(5 workers)
Workers → Platform: accept/decline
Platform → Foreman: "4 of 5 accepted, 1 replacement needed"
```

#### 17.5 Certification Expiration Sequence
```
CronJob → CertEngine: checkExpirations(today + 30)
CertEngine → DB: query expiring certs
DB → CertEngine: expiringCerts[]
CertEngine → NotificationService: send alerts
NotificationService → Candidate: SMS "Your OSHA 10 expires in 30 days"
NotificationService → Candidate: email with renewal link
CertEngine → MatchEngine: flagExpiringCerts(candidateIds)
MatchEngine → DB: recalculate affected scores
```

---

### 18. Use Cases

> Actor-goal use case specifications.

#### 18.1 Actors
| Actor | Description |
|-------|-------------|
| **Candidate** | Job seeker in skilled trades (apprentice through superintendent) |
| **Employer** | Hiring manager, foreman, or HR at a contractor/sub |
| **SchoolAdmin** | Admissions or enrollment staff at a trade school |
| **BrandAdvertiser** | Marketing team at a tool/equipment/services brand |
| **PlatformAdmin** | JobSiteLink operations team |
| **AI Avatar** | System actor — conversational AI agent |
| **CronScheduler** | System actor — time-based triggers |

#### 18.2 Use Case Catalog

##### Candidate Use Cases
- [ ] `UC-C01` Onboard via AI Avatar conversation
- [ ] `UC-C02` Upload and manage certifications
- [ ] `UC-C03` View matched jobs with scores and gap reports
- [ ] `UC-C04` Apply to a job
- [ ] `UC-C05` Set availability and travel preferences
- [ ] `UC-C06` View career path and "what do I need next?"
- [ ] `UC-C07` Receive and respond to notifications
- [ ] `UC-C08` Rate an employer after a project
- [ ] `UC-C09` Access reentry pathway resources
- [ ] `UC-C10` Renew expiring certification on-platform

##### Employer Use Cases
- [ ] `UC-E01` Post a job with structured requirements
- [ ] `UC-E02` Search and filter candidates
- [ ] `UC-E03` View candidate profile + match score + gap report
- [ ] `UC-E04` Build a crew for a project
- [ ] `UC-E05` Re-hire from previous projects
- [ ] `UC-E06` Manage application pipeline (view → shortlist → interview → offer → hire)
- [ ] `UC-E07` Rate workers after project completion
- [ ] `UC-E08` Upload COI and manage compliance
- [ ] `UC-E09` Export certified payroll (Davis-Bacon)
- [ ] `UC-E10` View retention analytics

##### School Use Cases
- [ ] `UC-S01` View pre-qualified candidate pipeline
- [ ] `UC-S02` Contact and track leads through enrollment funnel
- [ ] `UC-S03` View acquisition cost metrics
- [ ] `UC-S04` Manage school profile and program catalog

##### Brand Use Cases
- [ ] `UC-B01` Create targeted ad campaign
- [ ] `UC-B02` View impression and conversion analytics
- [ ] `UC-B03` Manage budget and bidding

##### Admin Use Cases
- [ ] `UC-A01` Verify uploaded certifications
- [ ] `UC-A02` Moderate profiles and content
- [ ] `UC-A03` Manage platform analytics
- [ ] `UC-A04` Handle fraud detection alerts

---

### 19. Deployments

> Physical deployment modeling.

#### 19.1 Summary
Infrastructure topology for the JobSiteLink platform.

#### 19.2 Deployment Topology
```
┌──────────────────────────────────────────────────────────────┐
│                         CDN (Cloudflare)                     │
│                    Static assets, SSL termination             │
└─────────────────────────┬────────────────────────────────────┘
                          │
┌─────────────────────────▼────────────────────────────────────┐
│                     Load Balancer                             │
└─────────┬───────────────┬──────────────────┬─────────────────┘
          │               │                  │
┌─────────▼───┐  ┌────────▼──────┐  ┌────────▼──────┐
│  Web/API    │  │  Web/API      │  │  Avatar/Voice │
│  Server 1   │  │  Server 2     │  │  Server       │
│  (FastAPI)  │  │  (FastAPI)    │  │  (STT+TTS)    │
└──────┬──────┘  └───────┬───────┘  └───────┬───────┘
       │                 │                  │
┌──────▼─────────────────▼──────────────────▼──────┐
│                   Internal Network                │
├──────────────┬──────────────┬─────────────────────┤
│  PostgreSQL  │    Redis     │   Object Storage    │
│  (Primary +  │  (Sessions,  │   (Cert images,     │
│   Replica)   │   Cache,     │    portfolios,      │
│              │   Matching)  │    documents)        │
└──────────────┴──────────────┴─────────────────────┘

External Integrations:
  → OSHA / State License APIs
  → Background Check Provider (Checkr / Sterling)
  → Payment Gateway (Stripe)
  → Notification Services (Twilio SMS, SendGrid Email, Telegram API)
  → LLM Providers (OpenAI, Anthropic, Azure)
  → TTS/STT (ElevenLabs, Azure Speech, Whisper)
  → COI Verification (myCOI, Zywave)
```

#### 19.3 Nodes
- [ ] Define hardware requirements per node type
- [ ] Define scaling triggers and auto-scaling rules

#### 19.4 Environments
| Environment | Purpose | Data |
|-------------|---------|------|
| `local` | Developer machine | Fixtures / seed data |
| `staging` | Pre-release testing | Anonymized production subset |
| `production` | Live platform | Real data, encrypted |

---

### 20. Information Flows

> High-level data flows between major subsystems.

#### 20.1 Core Information Flows
```
Candidate ──(profile data)──→ Avatar Engine ──(structured JSON)──→ Candidate Service
Candidate Service ──(profile)──→ Matching Engine ──(scores)──→ Employer Service
Employer Service ──(job posting)──→ Matching Engine ──(ranked candidates)──→ Employer
Candidate Service ──(qualified lead)──→ School Service ──(pipeline status)──→ School Admin
Candidate Service ──(career stage)──→ Ad Engine ──(targeted ad)──→ Candidate
Cert Engine ──(expiration alert)──→ Notification Service ──(SMS/email)──→ Candidate
Compliance Engine ──(background check)──→ External Provider ──(result)──→ Employer Service
```

---

## Standard Types and Profiles

### 21. Primitive Types

| Type | Description |
|------|-------------|
| `UUID` | Unique identifier (v4) |
| `Timestamp` | ISO 8601 datetime with timezone |
| `Email` | RFC 5322 email address |
| `Phone` | E.164 phone number |
| `URL` | Valid URI |
| `Coordinates` | Latitude/longitude pair |
| `Money` | Integer cents (USD) |
| `Percentage` | Integer 0–100 |
| `MilesRadius` | Integer miles |

---

### 22. Standard Profiles

#### 22.1 Stereotypes
| Stereotype | Applies To | Description |
|------------|-----------|-------------|
| `<<verified>>` | Certification, License | Confirmed by admin or API |
| `<<expired>>` | Certification, License | Past expiration date |
| `<<prevailing_wage>>` | JobPosting | Subject to Davis-Bacon Act |
| `<<union_only>>` | JobPosting | Requires union membership |
| `<<reentry>>` | Candidate | Justice-involved reentry pipeline |
| `<<bilingual>>` | Candidate, JobPosting | English + Spanish |
| `<<travel_ready>>` | Candidate | Willing to travel beyond local area |
| `<<trusted>>` | Candidate | Has 3+ positive employer ratings |
| `<<seasonal>>` | JobPosting, Candidate | Tied to seasonal availability |

---

## Annexes

### Annex A: Diagram Index

> All UML diagrams to be created for this specification.

| ID | Type | Subject | Status |
|----|------|---------|--------|
| D01 | Use Case | Full system use case diagram | [ ] TODO |
| D02 | Class | Core domain model | [ ] TODO |
| D03 | Class | Candidate subsystem | [ ] TODO |
| D04 | Class | Employer subsystem | [ ] TODO |
| D05 | Class | Certification subsystem | [ ] TODO |
| D06 | Class | Matching engine | [ ] TODO |
| D07 | Sequence | Candidate onboarding | [ ] TODO |
| D08 | Sequence | Employer search → hire | [ ] TODO |
| D09 | Sequence | Crew building | [ ] TODO |
| D10 | Sequence | Cert verification | [ ] TODO |
| D11 | State Machine | Candidate profile lifecycle | [ ] TODO |
| D12 | State Machine | Application lifecycle | [ ] TODO |
| D13 | State Machine | Certification lifecycle | [ ] TODO |
| D14 | Activity | Job matching workflow | [ ] TODO |
| D15 | Activity | School pipeline workflow | [ ] TODO |
| D16 | Component | System architecture | [ ] TODO |
| D17 | Deployment | Production topology | [ ] TODO |
| D18 | Package | Module dependency diagram | [ ] TODO |

---

### Annex B: API Endpoint Index

> All REST endpoints to be specified in OpenAPI format.

| Method | Path | Module | Status |
|--------|------|--------|--------|
| `POST` | `/api/avatar/start` | avatar | [ ] TODO |
| `POST` | `/api/avatar/utterance` | avatar | [ ] TODO |
| `POST` | `/api/avatar/text` | avatar | [ ] TODO |
| `GET` | `/api/candidates/{id}` | candidate | [ ] TODO |
| `PUT` | `/api/candidates/{id}` | candidate | [ ] TODO |
| `POST` | `/api/candidates/{id}/certifications` | certification | [ ] TODO |
| `GET` | `/api/candidates/{id}/matches` | matching | [ ] TODO |
| `POST` | `/api/jobs` | employer | [ ] TODO |
| `GET` | `/api/jobs/{id}/candidates` | matching | [ ] TODO |
| `POST` | `/api/jobs/{id}/crew` | employer | [ ] TODO |
| `POST` | `/api/applications` | candidate | [ ] TODO |
| `PUT` | `/api/applications/{id}/status` | employer | [ ] TODO |
| `GET` | `/api/schools/{id}/pipeline` | school | [ ] TODO |
| `POST` | `/api/ads/campaigns` | advertising | [ ] TODO |
| `POST` | `/api/compliance/background-check` | compliance | [ ] TODO |
| `GET` | `/api/compliance/payroll-export/{projectId}` | compliance | [ ] TODO |

---

### Annex C: State Certification Requirements Database

> Initial state coverage (Phase 1: 5 states).

| State | Electrician License | Plumber License | HVAC License | GC License | Notes |
|-------|-------------------|-----------------|-------------|-----------|-------|
| FL | State (journeyman + master) | State | State | State (DBPR) | No reciprocity |
| TX | State (TDLR) | State | State | State (TDLR) | Data center boom market |
| CA | State (CSLB) | State | State | State (CSLB) | Strictest requirements |
| NY | State + city (NYC separate) | State + city | State | State | Dual licensing |
| GA | State (non-residential) | State | State | State | Southeast expansion |

---

### Annex D: Compliance Requirements Matrix

| Requirement | Trigger | Implementation |
|-------------|---------|----------------|
| FCRA consent | Before background check | Written disclosure + signed consent flow |
| E-Verify | Federal construction contracts > $3,500 | E-Verify status field per worker |
| COPPA | Users under 13 | Age gate — platform requires 16+ |
| Davis-Bacon | Federal construction contracts > $2,000 | Job tag + wage determination display |
| OSHA recordkeeping | All construction employers | Safety cert tracking per worker |
| COI verification | Subcontractors on any GC site | Upload + expiration tracking |
| Drug test policy | Varies by employer/union/project | Status field with date + type |

---

### Annex E: Glossary Cross-Reference

> Maps industry jargon to specification terms. See Section 4 (Terms and Definitions) for full definitions.

---

*This specification skeleton follows the structure of OMG UML 2.5.1 (formal/2017-12-05), adapted for domain-specific platform requirements. Fill sections as design and implementation progress.*

*JobSiteLink — One platform. Everything you need. Nothing else required.*


DESIGN_OOP_TEMPLATE_v1.0.md
==========
# JobSite Link — Software Design Document (OOP Skeleton)

> Based on IEEE 1016-2009, Rational Unified Process (RUP), and Kruchten's 4+1 Architectural View Model.
> Adapted for JobSiteLink — the commercial layer of the skilled trades ecosystem.

---

## 1. Introduction

### 1.1 Purpose
This document provides a comprehensive architectural overview of the JobSiteLink platform using multiple views to depict different aspects of the system. It is intended to capture and convey the significant architectural decisions which have been made on the system.

### 1.2 Scope
- **System:** JobSiteLink — AI-powered vertical workforce platform for US skilled trades
- **Boundaries:** Candidate onboarding, certification tracking, job matching, employer dashboards, trade school pipeline, brand advertising, reentry pathways
- **Exclusions:** Payroll processing, benefits administration, time/attendance tracking

### 1.3 Definitions, Acronyms and Abbreviations
See `08-SPECIFICATION_OOP_TEMPLATE.md` Section 4 (Terms and Definitions).

### 1.4 References
| Document | Description |
|----------|-------------|
| `05-FEATURES.md` | Complete feature inventory with priority tiers |
| `08-SPECIFICATION_OOP_TEMPLATE.md` | Formal specification skeleton (UML 2.5 structure) |
| `04-BUSINESS_PLAN.md` | Business plan with market data and financial projections |
| `03-MY_CTO.md` | CTO tactical focus and technical roadmap |
| `02-FIN_INSIGHTS.md` | Financial intelligence and competitor analysis |

### 1.5 Document Overview
This document is organized using the **4+1 Architectural View Model** (Kruchten, 1995):

| View | Stakeholders | Concerns | UML Diagrams |
|------|-------------|----------|--------------|
| **+1 Scenarios** | All | Key use cases that drive architecture | Use Case Diagrams |
| **Logical** | Domain analysts, developers | Object model, design patterns | Class, Sequence, State |
| **Process** | Performance engineers | Concurrency, throughput, distribution | Activity, Sequence |
| **Development** | Programmers, build engineers | Module organization, layers, reuse | Package, Component |
| **Physical** | Ops, infrastructure | Deployment, availability, topology | Deployment Diagrams |

---

## 2. Architectural Representation

### 2.1 Views Used
This document uses all five views of the 4+1 model, plus two additional views:
- **Data View** — persistent data model and ORM strategy
- **Interface View** — external API contracts and third-party integrations

### 2.2 Modeling Conventions
- All diagrams follow UML 2.5.1 notation
- API contracts follow OpenAPI 3.1 specification
- Data models use PostgreSQL-compatible types
- Code examples use Python 3.12+ with type hints

### 2.3 Architecture Style
- **Phase 1–2:** Modular monolith with clean internal boundaries
- **Phase 3+:** Service extraction where scale demands it
- **API style:** RESTful with JSON payloads
- **Async pattern:** Event-driven for matching, notifications, cert expiration

---

## 3. Architectural Goals and Constraints

### 3.1 Quality Attributes

| Attribute | Requirement | Design Impact |
|-----------|-------------|---------------|
| **Performance** | Match score calculation < 500ms | Precomputed scores, Redis cache |
| **Availability** | 99.5% uptime (pilot), 99.9% (scale) | Load balancer, DB replica, health checks |
| **Scalability** | Support 10K candidates → 500K candidates | Horizontal API scaling, read replicas |
| **Latency** | Avatar response < 2s end-to-end | Streaming TTS, edge STT, model selection by latency |
| **Security** | PII encrypted at rest + transit | AES-256, TLS 1.3, HttpOnly cookies |
| **Bilingual** | Full English + Spanish support | i18n framework from day 1, bilingual content DB |

### 3.2 Technical Constraints
- [ ] Python 3.12+ (FastAPI backend)
- [ ] PostgreSQL 15+ (primary data store)
- [ ] Redis 7+ (cache, sessions, real-time matching)
- [ ] No heavy frontend framework — vanilla JS + HTML for portals (consistent with existing phil/elevated approach)
- [ ] Multi-LLM backend (GPT-4o, Claude, Azure — model-agnostic orchestration)
- [ ] Voice pipeline: Whisper (STT) → LLM → ElevenLabs/Azure (TTS)

### 3.3 Business Constraints
- [ ] $500K seed budget — lean MVP required
- [ ] CTO is sole technical architect (for now)
- [ ] American dev shop building through April — integration and handoff considerations
- [ ] Trade school pilots start Q2 — working product required
- [ ] 20-year relationship network is the distribution moat — tech must enable, not replace, human relationships

### 3.4 Regulatory Constraints
- [ ] FCRA compliance for background checks
- [ ] COPPA — platform targets 16+, age verification required
- [ ] Davis-Bacon Act — prevailing wage display on federal projects
- [ ] E-Verify — status tracking for federal construction contracts
- [ ] EEOC — matching algorithm must not introduce bias by protected class

---

## 4. Use-Case View (+1 Scenarios)

> The "+1" view drives and validates all other architectural views. These are the architecturally significant scenarios.

### 4.1 System Context Diagram

```
                    ┌─────────────────────────────┐
                    │                             │
   Candidate ──────►│                             │◄────── Employer
                    │                             │
                    │      JobSiteLink            │
                    │      Platform               │
   Trade School ───►│                             │◄────── Brand
                    │                             │        Advertiser
                    │                             │
                    └──────────┬──────────────────┘
                               │
              ┌────────────────┼──────────────────────┐
              │                │                      │
        External APIs     LLM Providers        Notification
        (OSHA, State      (OpenAI, Claude,     Services
         License DBs,     Azure)               (Twilio, SendGrid,
         Checkr, Stripe)                        Telegram)
```

### 4.2 Architecturally Significant Use Cases

These use cases exercise the critical architectural mechanisms and drive the design:

#### UC-01: Candidate Onboards via AI Avatar
- **Priority:** P0
- **Touches:** Avatar Engine, Profile Builder, Cert Engine, Matching Engine, DB
- **Architectural significance:** Defines the real-time voice pipeline, LLM orchestration, profile extraction pipeline, and the structured data model
- **Preconditions:** Candidate accesses platform (web or mobile)
- **Main flow:** Avatar greets → multi-turn conversation → profile extracted → certs identified → gaps detected → initial matches generated
- **Postconditions:** Verified candidate profile in DB, initial match scores computed
- **Quality requirements:** < 2s avatar response latency, bilingual support, session persistence

#### UC-02: Employer Searches and Hires
- **Priority:** P0
- **Touches:** Matching Engine, Candidate Service, Employer Service, Notification Service
- **Architectural significance:** Defines the search/filter infrastructure, ranking algorithm, real-time scoring
- **Preconditions:** Employer has active job posting
- **Main flow:** Search → filter → view ranked candidates with scores + gaps → shortlist → interview → offer → hire
- **Postconditions:** Candidate marked as placed, metrics updated
- **Quality requirements:** Search results < 1s, match score < 500ms

#### UC-03: Foreman Builds a Crew
- **Priority:** P1
- **Touches:** Matching Engine, Crew Builder, Notification Service, Trusted Workers Store
- **Architectural significance:** Defines batch operations, constraint satisfaction (ratio rules), fast outreach
- **Preconditions:** Job posting with crew size + requirements
- **Main flow:** Check trusted list → rank candidates per slot → enforce ratio constraints → propose crew → employer approves → batch outreach → accept/decline → fill gaps
- **Postconditions:** Full crew assembled, all members notified
- **Quality requirements:** Crew proposal < 3s, outreach within 1 minute

#### UC-04: Certification Expires and is Renewed
- **Priority:** P1
- **Touches:** Cert Engine, Notification Service, Matching Engine, External Cert Provider
- **Architectural significance:** Defines scheduled job infrastructure, cert verification pipeline, cascading score recalculation
- **Main flow:** Cron detects approaching expiry → notify candidate → candidate renews (on-platform or upload) → admin verifies → scores recalculated
- **Postconditions:** Cert status updated, all affected match scores refreshed

#### UC-05: Trade School Receives Qualified Lead
- **Priority:** P1
- **Touches:** Avatar Engine, School Service, Candidate Service, Notification Service
- **Architectural significance:** Defines the B2B pipeline, lead qualification criteria, CRM integration
- **Main flow:** Avatar identifies training interest → match to programs → candidate selects → school notified → school contacts → tracking through enrollment
- **Postconditions:** Lead in school pipeline with status tracking

#### UC-06: Brand Serves Targeted Ad
- **Priority:** P2
- **Touches:** Ad Engine, Candidate Service (career stage), Analytics
- **Architectural significance:** Defines career-moment detection, ad targeting pipeline, billing
- **Main flow:** Candidate reaches career moment → ad engine matches campaign → serve ad → track impression/conversion → report to brand
- **Postconditions:** Impression logged, brand billed

---

## 5. Logical View

> Object model, key abstractions, design patterns, and use-case realizations.

### 5.1 Overview — Package Hierarchy

```
jobsitelink/
├── core/                  # Layer 0: Foundation
│   ├── models.py          # Base entity, auditable entity
│   ├── auth.py            # Authentication, session management
│   ├── config.py          # Environment config, feature flags
│   ├── events.py          # Event bus, domain events
│   └── exceptions.py      # Domain exception hierarchy
│
├── candidate/             # Layer 1: Domain — Candidate
│   ├── models.py          # Candidate, WorkHistory, Portfolio
│   ├── service.py         # Candidate CRUD, profile management
│   └── schemas.py         # Pydantic request/response models
│
├── employer/              # Layer 1: Domain — Employer
│   ├── models.py          # EmployerOrg, JobPosting, CrewAssignment
│   ├── service.py         # Job posting, crew building, hiring workflow
│   └── schemas.py
│
├── certification/         # Layer 1: Domain — Certifications
│   ├── models.py          # Certification, StateRequirement, CertType
│   ├── service.py         # Upload, verify, expiration tracking
│   ├── state_db.py        # State-by-state licensing requirements
│   └── schemas.py
│
├── school/                # Layer 1: Domain — Trade Schools
│   ├── models.py          # TradeSchool, Program, PipelineLead
│   ├── service.py         # Pipeline management, metrics
│   └── schemas.py
│
├── matching/              # Layer 2: Intelligence
│   ├── engine.py          # Match score calculation
│   ├── gap_report.py      # Gap report generation
│   ├── ranker.py          # Candidate/job ranking
│   └── models.py          # MatchResult, GapReport, RankedCandidate
│
├── avatar/                # Layer 2: Intelligence
│   ├── engine.py          # Conversation orchestration
│   ├── profile_extractor.py  # LLM-driven profile extraction
│   ├── voice.py           # STT + TTS pipeline
│   └── models.py          # ConversationState, AvatarResponse
│
├── referral/              # Layer 1: Domain — Trust Network
│   ├── models.py          # Referral, Rating, TrustScore
│   ├── service.py         # Referral management, score aggregation
│   └── schemas.py
│
├── advertising/           # Layer 2: Monetization
│   ├── models.py          # AdCampaign, Impression, Conversion
│   ├── engine.py          # Targeting, matching, serving
│   └── schemas.py
│
├── compliance/            # Layer 1: Domain — Compliance
│   ├── background.py      # Background check integration (FCRA)
│   ├── everify.py         # E-Verify status tracking
│   ├── davis_bacon.py     # Prevailing wage, WH-347 export
│   └── models.py
│
├── notification/          # Layer 3: Infrastructure
│   ├── service.py         # Notification routing (SMS, email, push, Telegram)
│   ├── templates.py       # Message templates (EN + ES)
│   └── channels/          # Channel-specific adapters
│       ├── sms.py         # Twilio
│       ├── email.py       # SendGrid
│       ├── push.py        # Web push / FCM
│       ├── telegram.py    # Telegram Bot API
│       └── whatsapp.py    # WhatsApp Business API
│
└── analytics/             # Layer 3: Infrastructure
    ├── metrics.py         # Platform metrics
    ├── market_intel.py    # Trade shortage data, salary trends
    └── models.py
```

### 5.2 Domain Model — Key Abstractions

```
┌──────────────────┐         ┌──────────────────┐
│    Candidate     │         │    EmployerOrg    │
├──────────────────┤         ├──────────────────┤
│ trade            │         │ name             │
│ classification   │◄───────►│ type (GC/Sub)    │
│ years_experience │  match  │ locations[]      │
│ certs[]          │         │ union_status     │
│ travel_radius    │         │ coi              │
│ availability     │         └────────┬─────────┘
│ union_status     │                  │ posts
│ languages[]      │         ┌────────▼─────────┐
│ physical_caps[]  │         │   JobPosting     │
│ tools_owned[]    │         ├──────────────────┤
│ referrals[]      │         │ trade            │
│ trust_score      │         │ classification   │
└────────┬─────────┘         │ location         │
         │ holds              │ pay_range        │
┌────────▼─────────┐         │ project_dates    │
│  Certification   │         │ certs_required[] │
├──────────────────┤         │ prevailing_wage  │
│ type             │         │ union_only       │
│ issuing_body     │         │ per_diem         │
│ state            │         │ tools_provided   │
│ issue_date       │         └────────┬─────────┘
│ expiration_date  │                  │ generates
│ status           │         ┌────────▼─────────┐
│ verification     │         │   MatchResult    │
└──────────────────┘         ├──────────────────┤
                             │ match_score      │
┌──────────────────┐         │ cert_match_%     │
│   TradeSchool    │         │ skill_match_%    │
├──────────────────┤         │ exp_match_%      │
│ name             │         │ loc_match_%      │
│ programs[]       │         │ gap_report       │
│ locations[]      │         └──────────────────┘
│ accreditation    │
└────────┬─────────┘         ┌──────────────────┐
         │ receives           │     Rating       │
┌────────▼─────────┐         ├──────────────────┤
│  PipelineLead    │         │ from (employer)  │
├──────────────────┤         │ to (candidate)   │
│ candidate        │         │ project          │
│ school           │         │ punctuality      │
│ program          │         │ skills           │
│ status           │         │ safety           │
│ created_at       │         │ would_rehire     │
└──────────────────┘         └──────────────────┘
```

### 5.3 Design Patterns

| Pattern | Where Used | Purpose |
|---------|-----------|---------|
| **Repository** | All service modules | Abstract DB access, enable testing |
| **Strategy** | Matching engine | Swap scoring algorithms (keyword vs. semantic vs. hybrid) |
| **Observer / Event Bus** | Cert expiration, match recalc | Decouple triggers from handlers |
| **Factory** | Avatar engine | Create appropriate LLM client based on config |
| **Adapter** | Notification channels | Uniform interface across SMS, email, Telegram, etc. |
| **Chain of Responsibility** | Cert verification | Manual → API → OCR verification pipeline |
| **Template Method** | Profile extraction | Common extraction flow, trade-specific overrides |
| **Facade** | Compliance module | Unified API over background check, E-Verify, Davis-Bacon |
| **Specification** | Candidate search | Composable filter criteria (trade AND state AND cert AND available) |

### 5.4 Use-Case Realizations

> Sequence diagrams for architecturally significant use cases.
> See `08-SPECIFICATION_OOP_TEMPLATE.md` Section 17 (Interactions) for detailed sequences.

- [ ] `UC-01` Candidate Onboarding — sequence diagram
- [ ] `UC-02` Employer Search → Hire — sequence diagram
- [ ] `UC-03` Crew Building — sequence diagram
- [ ] `UC-04` Cert Expiration + Renewal — sequence diagram
- [ ] `UC-05` School Pipeline — sequence diagram
- [ ] `UC-06` Brand Ad Serving — sequence diagram

### 5.5 State Behavior of Key Objects
> See `08-SPECIFICATION_OOP_TEMPLATE.md` Section 14 (State Machines) for:
- Candidate Profile lifecycle
- Application lifecycle
- Certification lifecycle
- Job Posting lifecycle
- Crew Assembly lifecycle
- School Pipeline Lead lifecycle

---

## 6. Process View

> Concurrency, distribution, performance, fault tolerance.

### 6.1 Processes and Threads

| Process | Type | Purpose |
|---------|------|---------|
| **API Server** | Long-running (uvicorn) | Handle HTTP requests, serve web UI |
| **Avatar Worker** | Long-running | Manage active voice conversations (STT → LLM → TTS) |
| **Match Worker** | Background task | Batch recalculation of match scores on profile/cert changes |
| **Notification Worker** | Background task | Process notification queue (SMS, email, push, Telegram) |
| **Cert Expiration Cron** | Scheduled (daily) | Check for expiring certs, trigger alerts |
| **Job Scan Cron** | Scheduled (hourly) | Match new postings against candidate pool |
| **Analytics Aggregator** | Scheduled (nightly) | Compute platform metrics, market intelligence |

### 6.2 Inter-Process Communication

| Communication | Mechanism | When |
|---------------|-----------|------|
| API → Match Worker | Redis queue (task) | Profile updated, cert added, job posted |
| API → Notification Worker | Redis queue (message) | Any notification trigger |
| Cron → Match Worker | Redis queue (batch) | Daily cert expiration → score recalc |
| Avatar Worker → API | Internal HTTP / direct call | Profile extraction complete |
| API → External Services | Async HTTP (httpx) | LLM calls, OSHA API, Twilio, Stripe |

### 6.3 Synchronization and Concurrency

| Concern | Solution |
|---------|----------|
| Avatar conversation state | Per-session lock in Redis (one avatar session per candidate) |
| Match score consistency | Optimistic locking on candidate profile version |
| Cert upload race condition | File upload → DB record → queue verification (sequential) |
| Crew building slot reservation | Pessimistic lock on crew slots during assembly |
| Rate limiting | Token bucket per IP/user in Redis |

### 6.4 Performance Budget

| Operation | Target Latency | Strategy |
|-----------|---------------|----------|
| Avatar voice response | < 2,000ms | Streaming TTS, small STT model, fast LLM |
| Match score calculation | < 500ms | Precomputed cert index, cached candidate vectors |
| Candidate search | < 1,000ms | PostgreSQL full-text + GIN indexes, Redis cache |
| Job posting publish | < 200ms | Async match fan-out after response |
| Notification dispatch | < 5,000ms | Queue-based, non-blocking |

---

## 7. Development View (Implementation View)

> Module organization, layers, build configuration.

### 7.1 Layer Architecture

```
┌─────────────────────────────────────────────────────────┐
│  Layer 4: PRESENTATION                                  │
│  Web UI (vanilla JS/HTML), API routes (FastAPI)         │
├─────────────────────────────────────────────────────────┤
│  Layer 3: INFRASTRUCTURE                                │
│  Notification, Analytics, External API adapters,        │
│  File storage, Cache                                    │
├─────────────────────────────────────────────────────────┤
│  Layer 2: INTELLIGENCE                                  │
│  Matching engine, Avatar engine, Ad engine,             │
│  Profile extraction, Gap report generation              │
├─────────────────────────────────────────────────────────┤
│  Layer 1: DOMAIN                                        │
│  Candidate, Employer, Certification, School, Referral,  │
│  Compliance (models + services + schemas)               │
├─────────────────────────────────────────────────────────┤
│  Layer 0: CORE / FOUNDATION                             │
│  Base models, auth, config, events, exceptions, DB      │
└─────────────────────────────────────────────────────────┘
```

**Dependency rules:**
- Each layer MAY depend on layers below it
- Each layer SHALL NOT depend on layers above it
- Layer 2 (Intelligence) depends on Layer 1 (Domain) for data, never the reverse
- Layer 3 (Infrastructure) provides adapters consumed by Layer 1 and 2 via interfaces

### 7.2 Source Code Organization

```
src/
├── api/
│   ├── app.py                    # FastAPI application factory
│   ├── config.py                 # Environment configuration
│   ├── middleware/               # Auth, CORS, security, session
│   ├── routes/                   # Shared routes (static, health)
│   └── experts/
│       └── jobsitelink/
│           ├── __init__.py       # Router export
│           ├── routes.py         # HTTP route handlers
│           ├── candidate/        # Candidate domain module
│           ├── employer/         # Employer domain module
│           ├── certification/    # Cert domain module
│           ├── school/           # School domain module
│           ├── matching/         # Matching intelligence module
│           ├── avatar/           # Avatar intelligence module
│           ├── referral/         # Trust network module
│           ├── compliance/       # Compliance module
│           ├── advertising/      # Ad engine module
│           ├── notification/     # Notification infrastructure
│           └── analytics/        # Analytics infrastructure
│
├── web/
│   └── jobsitelink/
│       ├── index.html            # Main shell (gate + app)
│       ├── js/                   # Client-side JavaScript
│       ├── css/                  # Stylesheets
│       ├── img/                  # Images and icons
│       ├── tab_*.html            # Tab content pages
│       ├── portal_*.html         # Portal mockups
│       ├── slides.html           # Pitch deck
│       └── data/                 # Static data files
│
└── scripts/
    └── jobsitelink/
        ├── seed_data.py          # Seed DB with test data
        ├── smoke_test.sh         # Endpoint smoke tests
        └── cert_import.py        # Import state cert requirements
```

### 7.3 Build and Configuration

| Concern | Tool | Notes |
|---------|------|-------|
| Package management | pip + requirements.txt | Keep deps minimal |
| Code formatting | ruff format | Consistent with rest of slav_ai |
| Linting | ruff check | Enforce import ordering, unused imports |
| Environment config | .env + config.py | Never commit secrets |
| Database migrations | Alembic | Versioned schema changes |
| API documentation | OpenAPI 3.1 (auto-generated by FastAPI) | |

---

## 8. Physical View (Deployment View)

> See `08-SPECIFICATION_OOP_TEMPLATE.md` Section 19 (Deployments) for full topology diagram.

### 8.1 Deployment Overview

| Tier | Components | Technology |
|------|-----------|------------|
| **Edge** | CDN, SSL termination, static assets | Cloudflare |
| **Web** | API servers (2+), load balanced | FastAPI + uvicorn, nginx/ALB |
| **Voice** | Avatar voice processing | Dedicated instance(s) with GPU access |
| **Data** | PostgreSQL primary + replica, Redis | Managed DB (RDS/Cloud SQL) |
| **Storage** | Cert images, portfolio files | S3-compatible object storage |
| **Workers** | Match recalc, notifications, cron | Background processes on web tier (Phase 1), separate workers (Phase 2+) |

### 8.2 Environment Matrix

| Env | API Instances | DB | Redis | Voice | Purpose |
|-----|--------------|-----|-------|-------|---------|
| `local` | 1 (uvicorn) | Local PG | Local Redis | Mock/local | Development |
| `staging` | 1 | Shared PG | Shared Redis | Shared | Testing |
| `production` | 2+ (load balanced) | Managed PG (primary + replica) | Managed Redis | Dedicated | Live |

### 8.3 Scaling Strategy

| Phase | Users | API Instances | DB Strategy |
|-------|-------|--------------|-------------|
| MVP | < 1K | 1 | Single PG instance |
| Pilot | 1K–10K | 2 | PG primary + read replica |
| Growth | 10K–100K | 4+ | PG with read replicas, Redis cluster |
| Scale | 100K–500K | Auto-scaled | PG sharding or managed, dedicated Redis |

---

## 9. Data View

> Persistent data model, ORM strategy, data access patterns.

### 9.1 Database Technology
- **Primary:** PostgreSQL 15+ (structured data, full-text search, GIN indexes)
- **Cache:** Redis 7+ (sessions, match score cache, task queues)
- **Search:** PostgreSQL full-text search (Phase 1), pgvector for semantic matching (Phase 2+)
- **Object storage:** S3-compatible for cert images, portfolio media

### 9.2 Core Tables (Schema Skeleton)

```sql
-- Foundation
candidates          -- Core candidate profiles
candidate_work_history  -- Project-by-project work history
candidate_tools     -- Tools owned per candidate
candidate_physical_caps  -- Physical capability flags

-- Certifications
certifications      -- Cert instances per candidate
cert_types          -- Master list of certification types
state_requirements  -- State × trade × required certs matrix

-- Employer
employer_orgs       -- Employer organizations
job_postings        -- Structured job postings
crew_assignments    -- Crew slots per job posting
applications        -- Candidate applications to jobs

-- Matching
match_results       -- Precomputed match scores
gap_reports         -- Generated gap reports

-- Trust
referrals           -- Named referrals between workers/employers
ratings             -- Post-project ratings (bidirectional)

-- Schools
trade_schools       -- School profiles
school_programs     -- Program catalog
pipeline_leads      -- Student acquisition pipeline

-- Advertising
ad_campaigns        -- Brand ad campaigns
ad_impressions      -- Impression tracking
ad_conversions      -- Conversion tracking

-- Compliance
background_checks   -- FCRA-compliant background check records
everify_records     -- E-Verify status per worker
coi_records         -- Certificate of Insurance per employer

-- Platform
notifications       -- Notification log
audit_log           -- All data access and changes
```

### 9.3 Key Indexes

| Table | Index | Type | Purpose |
|-------|-------|------|---------|
| `candidates` | `(trade, classification, state)` | B-tree composite | Employer search |
| `candidates` | `(availability_from)` | B-tree | Seasonal availability queries |
| `candidates` | `(location)` | GiST (PostGIS) | Distance-based search |
| `certifications` | `(candidate_id, type, status)` | B-tree composite | Cert lookup |
| `certifications` | `(expiration_date)` | B-tree | Expiration cron scan |
| `job_postings` | `(trade, state, status)` | B-tree composite | Job search |
| `match_results` | `(candidate_id, job_posting_id)` | Unique B-tree | Score lookup |
| `match_results` | `(job_posting_id, score DESC)` | B-tree | Ranked candidate list |

### 9.4 Data Access Patterns

| Pattern | Frequency | Strategy |
|---------|-----------|----------|
| Candidate profile read | Very high | Redis cache (5 min TTL) |
| Match score lookup | Very high | Precomputed, Redis cached |
| Candidate search (employer) | High | PostgreSQL with GIN + composite indexes |
| Cert expiration scan | 1x/day | Sequential scan with date filter |
| Job-candidate batch matching | On publish | Async worker, fan-out |
| Analytics aggregation | 1x/night | Read replica, materialized views |

---

## 10. Interface View

> External API contracts and third-party integrations.

### 10.1 External REST API

See `08-SPECIFICATION_OOP_TEMPLATE.md` Annex B for full endpoint index.

**Authentication:**
- Gate login: session cookie via `/jobsitelink/session`
- API access: Bearer token (for employer/school/brand integrations)
- Internal: Session cookie with CSRF protection

**API versioning:** URL path prefix (`/api/v1/...`) when breaking changes occur.

### 10.2 Third-Party Integrations

| Integration | Provider | Protocol | Purpose |
|-------------|----------|----------|---------|
| **LLM (conversation)** | OpenAI, Anthropic, Azure | REST API | Avatar conversation, profile extraction |
| **STT** | Whisper (local), Azure Speech | REST/WebSocket | Speech-to-text for avatar |
| **TTS** | ElevenLabs, Azure Speech | REST/WebSocket | Text-to-speech for avatar |
| **SMS** | Twilio | REST API | Candidate notifications |
| **Email** | SendGrid | REST API | Digest emails, alerts |
| **Telegram** | Telegram Bot API | REST + Webhook | Job alerts, status updates |
| **WhatsApp** | WhatsApp Business API | REST | Spanish-language notifications |
| **Background checks** | Checkr / Sterling | REST API | FCRA-compliant checks |
| **Payment** | Stripe | REST API | Employer/school billing |
| **Object storage** | AWS S3 / compatible | S3 API | Cert images, portfolio files |
| **Geocoding** | Google Maps / Mapbox | REST API | Distance calculation |
| **State license DBs** | Per state (CSLB, TDLR, etc.) | Varies (scraping/API) | License verification |

### 10.3 Internal Service Interfaces

| Interface | Provided By | Consumed By | Contract |
|-----------|------------|-------------|----------|
| `IMatchEngine` | matching/ | employer/, candidate/, avatar/ | `calculateScore()`, `rankCandidates()`, `generateGapReport()` |
| `ICertVerifier` | certification/ | candidate/, matching/ | `verify()`, `checkExpiration()`, `getStateRequirements()` |
| `IAvatarEngine` | avatar/ | routes.py | `startConversation()`, `processUtterance()`, `extractProfile()` |
| `INotificationService` | notification/ | all modules | `send(channel, recipient, template, data)` |
| `IEventBus` | core/ | all modules | `publish(event)`, `subscribe(event_type, handler)` |

---

## 11. Design Decisions and Rationale

> Key architectural decisions recorded in ADR (Architecture Decision Record) format.

### ADR-001: Modular Monolith Over Microservices
- **Status:** Accepted
- **Context:** Small team (CTO + dev shop), $500K budget, speed to MVP critical
- **Decision:** Single deployable with clean internal module boundaries
- **Rationale:** Microservices add operational complexity (service mesh, distributed tracing, API gateways) that isn't justified at current scale. Module boundaries are designed for future extraction.
- **Consequences:** Faster development, simpler deployment. Risk of coupling if module boundaries aren't enforced.

### ADR-002: PostgreSQL + Redis Over Specialized Databases
- **Status:** Accepted
- **Context:** Need structured data, full-text search, geospatial queries, caching, and task queues
- **Decision:** PostgreSQL for all structured data + full-text search + PostGIS. Redis for caching, sessions, and task queues.
- **Rationale:** Minimizes operational complexity. PostgreSQL handles 90% of query patterns. pgvector extension available for semantic matching in Phase 2.
- **Consequences:** May need read replicas at 100K+ users. May need dedicated search (Elasticsearch) if full-text performance degrades.

### ADR-003: Multi-LLM Architecture
- **Status:** Accepted
- **Context:** Avatar conversation requires low latency; matching can use cheaper models; vendor lock-in is a risk
- **Decision:** Model-agnostic LLM orchestration layer. Select model per task type.
- **Rationale:** Different tasks have different latency/cost/quality tradeoffs. Avatar needs fast responses (GPT-4o mini or Claude Haiku). Profile extraction needs accuracy (GPT-4o or Claude Sonnet). Matching can use rules engine + small model.
- **Consequences:** Higher code complexity in LLM adapter layer. But: no vendor lock-in, cost optimization, resilience.

### ADR-004: Vanilla JS + HTML Over Frontend Framework
- **Status:** Accepted
- **Context:** Consistent with existing slav_ai platform (phil/elevated use same approach). Portals are primarily data display, not heavy interactivity.
- **Decision:** No React/Vue/Svelte. Vanilla JS with iframe-based tab architecture.
- **Rationale:** Faster to build, zero build tooling, consistent with team expertise. Tabs load independent HTML pages in iframes — isolation and simplicity.
- **Consequences:** Limited client-side state management. Acceptable for dashboard-style UIs. Avatar conversation widget may need a more structured approach (Web Components or lightweight lib).

### ADR-005: Event-Driven Matching Recalculation
- **Status:** Accepted
- **Context:** When a candidate adds a cert or an employer posts a job, all relevant match scores need updating
- **Decision:** Publish domain events → Redis queue → background worker recalculates affected scores
- **Rationale:** Keeps API responses fast. Score recalculation can be batched and prioritized. Eventual consistency is acceptable (scores update within minutes, not milliseconds).
- **Consequences:** Scores may be briefly stale after profile changes. Acceptable for this domain.

### ADR-006: [ ] SMS-First Communication for Trades Workers
- **Status:** Proposed
- **Context:** 35%+ of construction workforce is Hispanic, many without smartphones or reliable email. Referral culture is phone/text-based.
- **Decision:** (pending) SMS as primary notification channel. Email as secondary. Push/Telegram as opt-in.
- **Trade-offs:** SMS costs (Twilio ~$0.0079/message). But: highest reach and open rates in this demographic.

---

## 12. Size and Performance

### 12.1 Dimensioning (Phase 1 → Phase 3)

| Metric | Phase 1 (MVP) | Phase 2 (Pilot) | Phase 3 (Growth) |
|--------|--------------|----------------|------------------|
| Candidates | 500 | 5,000 | 50,000 |
| Employers | 20 | 200 | 2,000 |
| Schools | 5 | 50 | 200 |
| Job postings (active) | 50 | 500 | 5,000 |
| Match calculations/day | 2,500 | 250,000 | 25,000,000 |
| Notifications/day | 200 | 5,000 | 100,000 |
| Avatar conversations/day | 20 | 200 | 2,000 |
| Storage (certs + portfolios) | 5 GB | 50 GB | 500 GB |

### 12.2 Performance Targets

| Operation | P50 | P99 | Max |
|-----------|-----|-----|-----|
| API response (simple read) | 50ms | 200ms | 500ms |
| Candidate search | 200ms | 800ms | 2,000ms |
| Match score calculation | 100ms | 400ms | 1,000ms |
| Avatar voice round-trip | 1,200ms | 2,000ms | 3,000ms |
| Notification dispatch | 500ms | 2,000ms | 5,000ms |
| Page load (web UI) | 800ms | 2,000ms | 4,000ms |

---

## 13. Quality Attributes

| Attribute | Requirement | How Architecture Supports It |
|-----------|-------------|------------------------------|
| **Extensibility** | Add new trades, states, cert types without code changes | Data-driven config: trades, cert types, state requirements stored in DB, not code |
| **Reliability** | No data loss on crash | PostgreSQL WAL + regular backups. Redis persistence for queues. |
| **Testability** | All modules independently testable | Repository pattern abstracts DB. Interfaces for external services. Dependency injection. |
| **Security** | PII protected, no credential leakage | Encryption at rest (AES-256), transit (TLS 1.3), HttpOnly cookies, input sanitization |
| **Maintainability** | CTO + small team can maintain | Clean module boundaries, consistent patterns, minimal dependencies |
| **Portability** | Run on any cloud or VPS | Dockerized deployment, no cloud-specific APIs in core |
| **Accessibility** | WCAG 2.1 AA for web UI | Semantic HTML, keyboard navigation, contrast ratios, screen reader labels |
| **Internationalization** | Full English + Spanish | i18n keys for all UI strings, bilingual content storage, language preference per user |

---

## 14. Appendices

### 14.1 Glossary
See `08-SPECIFICATION_OOP_TEMPLATE.md` Section 4 (Terms and Definitions).

### 14.2 Requirements Traceability Matrix

| Requirement | Use Case | Logical View | Process View | Physical View |
|-------------|---------|-------------|-------------|---------------|
| AI Avatar onboarding | UC-01 | avatar/, candidate/ | Avatar Worker | Voice server |
| Match scoring | UC-02, UC-03 | matching/ | Match Worker | API server + Redis |
| Cert tracking | UC-04 | certification/ | Cert Cron | DB + Object storage |
| School pipeline | UC-05 | school/ | API server | DB |
| Brand ads | UC-06 | advertising/ | API server | CDN + DB |
| Crew building | UC-03 | employer/ | API server + Match Worker | API server |
| Notifications | All | notification/ | Notification Worker | External services |

### 14.3 Diagram Index
See `08-SPECIFICATION_OOP_TEMPLATE.md` Annex A for the full list of UML diagrams to be created.

### 14.4 Open Questions

| # | Question | Impact | Status |
|---|----------|--------|--------|
| 1 | Which LLM provider for avatar voice conversation in production? | Latency, cost, quality | Evaluating |
| 2 | Native mobile app timeline — Phase 2 or Phase 3? | Development scope | TBD |
| 3 | State license API availability — how many states have real APIs? | Cert verification automation | Research needed |
| 4 | COPPA implications for 16-year-old users? | Legal, UX | Legal review needed |
| 5 | Background check provider selection (Checkr vs. Sterling vs. other)? | Cost, integration effort | TBD |
| 6 | Union hiring hall integration — is API access possible? | Crew building feature | Research needed |
| 7 | White-label capability for large contractor chains — Phase 3 or later? | Architecture, multi-tenancy | TBD |

---

*This design document follows the 4+1 Architectural View Model (Kruchten, 1995) and IEEE 1016-2009 structure, adapted for the JobSiteLink platform.*

*JobSiteLink — One platform. Everything you need. Nothing else required.*
