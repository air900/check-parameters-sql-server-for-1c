---
name: code-review
description: Manual code review for quality, bugs, security, and best practices. Use before commits or to review specific files.
---

# Code Review

**Usage:**
- `/code-review` — review recent changes (git diff)
- `/code-review src/path/to/file.ts` — review specific file
- `/code-review src/features/auth/` — review directory

## Process

1. **Identify scope:**
   - If path provided → review that path
   - If no path → `git diff HEAD` for recent changes
   - If no changes → `git diff HEAD~1` for last commit

2. **Delegate to reviewer agent:**
   ```
   Task(reviewer):
     prompt: |
       Review these code changes:
       SCOPE: {files to review}
       CONTEXT: {what was changed and why, if known}
   ```

3. **Report results** from reviewer to user

## When to Use

- Before committing code
- After implementing a feature
- When concerned about code quality
- During PR review

## Reference

See `references/code-quality-standards.md` for the detailed quality checklist and metrics.
