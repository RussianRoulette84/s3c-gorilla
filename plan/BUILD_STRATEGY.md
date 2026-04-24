# Implementation guide for PLAN.md

1: use `develop` GIT branch. Never commit or push to `master` on your own.
2: Branch-per-phase. phase/0-kcli-probe, phase/1-fanout, phase/2-kpxc-push. Merge only after the phase's validation rows pass. Never let phases interleave on `develop`.
3: Red-first, one concern at a time. Tests already skip-stub most concerns. Pick a skip → remove it → ship the smallest diff that passes → commit → next. The 43-concern list IS your backlog — no separate tracker needed.
4: Parallel subagents for genuinely independent work. When Phase 1 starts, spin three in one turn: (a) install.sh refactor into src/install.sh + setup/*.sh, (b) Phase 0 keepassxc-cli probe research, (c) RSA harness. Zero dependency between them. See .claude/PARALLEL_AGENTS.md.
5: Do `/review` after every phase merge. De-slop first (CLAUDE.md's own rule — "no half-done, no imitations"), then code review. Don't carry Phase 1 cruft into Phase 2.
6: Dogfood as soon as it compiles. Moment touchid-gorilla fan-out works on one secret, wrap your real id_rsa and actually ssh with it. UX bugs surface in minutes instead of three phases later. Run on a test Mac / VM if the real one scares you.
7: Keep PLAN.md alive. Tick the checklist boxes and bump the success % every time a concern closes. Add rows for anything new that surfaces. A stale plan mid-build is worse than no plan.
