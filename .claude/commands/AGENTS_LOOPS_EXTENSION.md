# Autonomous Feedback Loop Protocol

> Add this section to the top of your CLAUDE.md (or use as standalone if no CLAUDE.md exists yet).
> This becomes active after running `.claude/commands/PRIME_FEEDBACK.md` once.

---

## Core Principle: You Are Not Done Until Logs Confirm It

Every code change you make must complete a full observe-act-reflect cycle before being declared done.
Never report success based on code review alone. Only logs and process output are truth.

---

## The Loop

After ANY code change, build, or configuration edit:

**1. Start / Restart affected service(s)**
Use the exact commands from `.claude/PROJECT_LOOP.md`.
If that file doesn't exist: run PRIME_FEEDBACK first.

**2. Read the logs**
Read every relevant log file from `.claude/PROJECT_LOOP.md`.
Do not guess what they say. Actually read them.
PRIME_FEEDBACK
**3. Evaluate state**

| What you find | What you do |
|---|---|
| Build error / compile failure | Fix the error, go to step 1 |
| Process crash / exit code != 0 | Read full stack trace, fix, go to step 1 |
| Unhandled exception in log | Fix it, go to step 1 |
| Warning that could cause issues | Assess, fix if risky, continue |
| Health check failing | Investigate, fix, go to step 1 |
| Browser console errors | Fix JS errors, go to step 1 |
| Logs are clean, service is up | Proceed to step 4 |

**4. If tests exist: run them**
Use the test command from `.claude/PROJECT_LOOP.md` or the project's standard test command.
Read test output. A passing test suite is required before declaring done.

**5. Declare done**
Only now can you report completion to the user.

---

## Log Reading Rules

- Always read logs from the BEGINNING of the current run, not just the tail
- A log file that hasn't been updated since your change means the service didn't restart — investigate
- "No errors found" is only valid if you actually read the file, not if it's absent or empty
- If a log file doesn't exist after starting a service: the service likely failed silently — check process state

---

## Multi-Service Awareness

If the project has multiple services (as defined in `.claude/PROJECT_LOOP.md`):
- A frontend compiling successfully does NOT mean the backend is healthy
- A backend starting does NOT mean the database connection succeeded
- Check ALL relevant services after changes, not just the one you edited

---

## When `.claude/PROJECT_LOOP.md` Does Not Exist

This means `PRIME_FEEDBACK` has not been run. Before doing any development work:
1. Tell the user: "Project feedback loop is not configured. Running `PRIME_FEEDBACK` first."
2. Execute `.claude/commands/PRIME_FEEDBACK.md`
3. Then proceed with the original task

---

## Failure Budget

You have unlimited attempts to fix a failing loop. Never give up and tell the user "it should work."
If you are stuck after 4 attempts on the same error:
1. Document exactly what you tried in your response
2. Show the exact log output that is confusing you
3. Ask the user for one specific piece of information
4. Do NOT rewrite unrelated code while blocked on a bug
