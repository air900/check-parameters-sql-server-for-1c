# Issue Tracking Reference

Guidelines for creating and managing issue files during orchestration.

## When to Create an Issue

**DO create an issue when:**
- Non-critical problem found during implementation
- Enhancement idea discovered while working
- Tech debt identified that shouldn't block current work
- Minor bug that doesn't affect the current task

**DON'T create an issue when:**
- Critical bug — fix immediately via debugger agent
- Problem blocks current task — resolve now
- Simple fix (< 5 minutes) — just fix it
- Already tracked elsewhere

## Issue File Format

```markdown
# ISS-NNN: Brief Description

**Created**: YYYY-MM-DD
**Severity**: Critical P1 | High P2 | Medium P3 | Low P4 | Enhancement P5
**Status**: Open | In Progress | Resolved | Won't Fix

## Description
What the issue is.

## Impact
What happens if not fixed.

## Why Not Fixed Now
Why this was deferred (e.g., "Out of scope for current task", "Needs design discussion").

## Proposed Solution
How to fix it.

## Related
- Orchestration: {orch-id if applicable}
- Task: {task-id if applicable}
- Files: {affected files}
```

## Issue Naming

```
Format: ISS-NNN-description.md
Location: Read from .claude/orchestration-config.json → documentation.paths.issues

Examples:
- ISS-001-token-refresh-race.md
- ISS-002-add-2fa-support.md
- ISS-003-missing-input-validation.md
```

## Severity Levels

| Level | Label | Meaning |
|-------|-------|---------|
| P1 | Critical | System broken, data loss risk |
| P2 | High | Major feature impaired |
| P3 | Medium | Workaround exists |
| P4 | Low | Cosmetic or minor inconvenience |
| P5 | Enhancement | Nice-to-have improvement |

## ID Generation

1. Read existing issues from configured path
2. Find highest ISS-NNN number
3. Increment by 1
4. If no issues exist, start at ISS-001

## Cross-Referencing

When creating an issue during orchestration, include:
- The orchestration context (what feature was being built)
- The task that surfaced the issue
- Relevant file paths

This allows future developers to understand the discovery context.
