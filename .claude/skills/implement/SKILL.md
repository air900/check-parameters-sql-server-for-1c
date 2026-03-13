---
name: implement
description: Simple implementation workflow — Code, Test, Document. Use for single components, functions, or endpoints that don't need planning or review.
---

# Implement: Simple Workflow

**When to use:** Single component, function, API endpoint, or simple feature addition.
**Not for:** Complex multi-part features, anything needing task breakdown (use `/orchestrate`).

## Agents Used

| Role | Agent | Model | Purpose |
|------|-------|-------|---------|
| Worker | `worker` | Sonnet | Implement the code |
| Test Runner | `test-runner` | Haiku | Run lint + tests |
| Debugger | `debugger` | Sonnet | Fix issues (if needed) |
| Documenter | `documenter` | Haiku | Create brief docs |

## Workflow

### Step 1: Implement

```
Task(worker):
  prompt: |
    Implement this task:
    TASK: {user's task description}
    CODEBASE: {project root}
```

### Step 2: Test

```
Task(test-runner):
  prompt: |
    Verify this implementation:
    TASK: {user's task description}
    CHANGES: {summary from worker}
```

If test-runner reports FAIL:
```
retry_count = 0
while status == FAIL and retry_count < 2:
    Task(debugger):
      prompt: |
        Fix these issues:
        TEST REPORT: {test-runner output}

    Task(test-runner):
      prompt: |
        Re-verify after fixes:
        FIX APPLIED: {debugger output}

    retry_count += 1
```

Max 2 retries (simpler workflow = fewer retries).

### Step 3: Document

```
Task(documenter):
  prompt: |
    Create brief documentation:
    TASK: {what was implemented}
    CHANGES: {summary from worker}
    TESTS: {summary from test-runner}
    CONFIG: Check .claude/orchestration-config.json for report path
```

### Step 4: Summary

Output to user:
```
## Implementation Complete

**Task:** {description}
**Status:** {Complete/Partial}

### Changes
- {file}: {what was done}

### Tests
{PASS/FAIL + details}

### Docs
{path to report or "See above"}
```

## Key Differences from /orchestrate

| Aspect | /implement | /orchestrate |
|--------|-----------|-------------|
| Planning | None | Planner agent breaks into subtasks |
| Code review | None | Reviewer agent checks quality |
| Security audit | None | Optional security-auditor check |
| Max retries | 2 | 3 |
| Tasks created | 0 | N (one per subtask) |
| Best for | Single items | Complex features |
