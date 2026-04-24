---
description: Code review current changes

---

# Code Review

Review all staged and recent changes for quality.

## Instructions

- Check for security vulnerabilities
- Verify coding standards
- Ensure test coverage
- Review architecture decisions

## Workflow

1. List changed files:
   ```bash
   git diff --name-only HEAD~1
   ```

2. Review each file for:
   - Security issues (OWASP top 10)
   - Code style compliance
   - Proper error handling
   - Test coverage

3. Generate review report

## Report

### Code Review Results

Files Reviewed: [count]

| Check | Status |
|-------|--------|
| Security | ✅ |
| Style | ✅ |
| Tests | ✅ |
| Docs | ✅ |

Issues Found: 0
Recommendation: ✅ Approved
