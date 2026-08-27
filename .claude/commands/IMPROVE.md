---
description: Senior-engineer + UX + QA review of the slav-ai codebase — top 15 prioritized improvements. No code, just analysis.
---

# IMPROVE (slav-ai)

You are acting as a **senior staff engineer + UX architect + QA lead** reviewing the slav-ai codebase.

Your task is to analyze **slav-ai** (multi-expert FastAPI + Vite + Django auth + Hanoi-Trello CLI) and produce a prioritized improvement plan. Take as long as needed (10–20 minutes equivalent thinking time). Depth > speed.

**DO NOT** write or modify code. **DO NOT** refactor anything yet. Your ONLY output is a list of the **TOP 15** most important improvement tasks, based on evidence from the code.

## Rules

1. Base findings on actual slav-ai code (cite files/components/functions as evidence — e.g. `src/api/experts/studio/actions.py:215`).
2. Concrete + actionable > generic advice. "Add caching" = bad. "Memoize `extract_avatar_animations` regex; currently O(n²) in `studio/director.py:88`" = good.
3. Unclear → create an *investigate* task instead of guessing.
4. Cover both UX/UI (5 chat surfaces, embed iframes, changelog page) and engineering (FastAPI, Django auth, Vite, MCP, builder-API).
5. Respect slav-ai's own rules from CLAUDE.md: no fallbacks, no `/chat/` prefix, files ≤200 lines, trailing-slash-everywhere. Flag violations as findings.
6. No filler. Exactly 15 items.

## Output format (STRICT)

## Top 15 Improvement Tasks

For EACH of the 15 tasks include:
- **Rank** (1–15)
- **ID** (e.g. UX-01, UI-04, A11Y-02, PERF-03, CODE-12, AUTH-02, DX-01)
- **Category**: UX | UI | Accessibility | Performance | Architecture | Auth/Security | Error Handling | Testing | Dev Experience | Tech Debt
- **Title** (short and precise)
- **Evidence** (file:line, function/component/route)
- **Problem** (what's wrong, why it matters for slav-ai users or operators)
- **Proposed improvement** (conceptual, NOT implementation)
- **Impact**: Low / Medium / High
- **Effort**: Small / Medium / Large
- **Dependencies / Notes** (if any)

After the 15 tasks, add:
- **"Quick wins"** (subset: high impact + small effort)
- **"Foundational first"** (subset that should be done earliest)
- **"Riskiest changes"** (subset likely to break behavior — affecting auth, routing, or production traffic)

Stop after that. Do not ask questions. Do not propose writing code yet.
