---
description: Find and prioritize `!important` usage across the codebase and generate a deimporting plan/report
---

# De-Important Command (DEIMPORTER)

Search the entire codebase for `!important`, prioritize the worst offenders, and generate a report:
`./reviews/DEIMPORTER_REPORT_YYYY-MM-DD__HH-MM-SS.md`

The goal is to reduce `!important` usage by fixing root-cause cascade issues (layers, scoping, selector strategy), not by swapping it for even higher specificity. This aligns with the project's CSS policy in `AGENTS.md` which states that `!important` should only be used when overriding third-party CSS or inline styles that cannot be changed, and must be properly documented.

## Scope

- Scan the whole repo for `!important`
- Primary focus: `src/web/css/` (slav-ai stylesheet directory)
- Exclude: `node_modules`, `.git`, build artifacts (`dist`, `build`, `.venv`, `__pycache__`), backup files (`*.backup`), lockfiles, logs, `.Trash-*`, `phil-ai/` submodule
- Include: `.css` files in `src/web/css/`, inline `<style>` in `src/web/*.html`, and style blocks in JS files

## Project Context

- **CSS Location**: `src/web/css/` (slav-ai stylesheet directory)
- **Build System**: Vite (outputs to `src/web/dist/`)
- **Backend**: FastAPI serves `src/web/` directly via static-route mount in `src/api/app.py`
- **Policy Reference**: See `CLAUDE.md` section "CSS" — `!important` only when overriding third-party / inline; must prove cascade reason; scope to component boundary; comment with upstream cause

## Search Commands

Use ripgrep if available:

```bash
rg -n --hidden --no-ignore-vcs "\!important" \
  -g'!.git/**' \
  -g'!node_modules/**' \
  -g'!dist/**' \
  -g'!build/**' \
  -g'!.venv/**' \
  -g'!__pycache__/**' \
  -g'!*.backup' \
  -g'!*lock*' \
  -g'!logs/**' \
  -g'!*.log' \
  .
```

Or focus on the slav-ai CSS directory only:

```bash
rg -n "\!important" src/web/css/*.css
```

## Report Format

The report should include:

1. **Executive Summary**: Total count, files affected, worst offenders (prioritized by selector scope - high-level selectors like `button`, `div` are most critical)
2. **Metrics**: Breakdown by file, by property type, by severity
3. **Prioritization**: Priority is determined by selector scope/level, not just the property:
   - **Highest priority**: Broad, high-level selectors (e.g., `button`, `div`, `*`, `input`) - these affect many elements and create cascade conflicts
   - **High priority**: Medium-level selectors (e.g., `.class`, `#id`, element.class) that can be fixed with cascade layers or scoping
   - **Medium priority**: Specific selectors (e.g., `.component .child`, `.component.is-active`) that override third-party CSS and need documentation
   - **Low priority**: Very specific, scoped selectors (e.g., `.my-component .nested .button`) that are legitimate third-party overrides (already documented)
   
   Example: `button { padding-left: 8px !important; }` is HIGHEST priority because it affects all buttons globally, while `.chat-input button { padding-left: 8px !important; }` is lower priority because it's scoped to a specific component.
4. **File-by-File Analysis**: For each file with `!important`:
   - Count of instances
   - Selector scope/level (broad vs. specific) - prioritize high-level selectors
   - Context (what it's overriding)
   - Suggested fix (cascade layer, scoping, or justification)
5. **Action Plan**: Prioritized list of fixes with estimated effort