---
name: orchestrate
description: Full development orchestration cycle — Plan, Code, Test, Review, Fix, Document. Use for complex multi-step features that need task breakdown and quality gates.
---

# Orchestrate: Full Development Cycle

**When to use:** Complex features requiring planning, multi-module work, anything needing task breakdown.
**Not for:** Single components, one-file changes, quick fixes (use `/implement` instead).

## Architecture

This skill coordinates 9 specialized agents defined in `.claude/agents/`:

| Role | Agent | Model | Purpose |
|------|-------|-------|---------|
| Planner | `planner` | Opus | Break task into subtasks with dependencies |
| Worker | `worker` | Sonnet | Implement code for each subtask |
| Test Runner | `test-runner` | Haiku | Run lint + tests + verify |
| Security Auditor | `security-auditor` | Sonnet | Audit security (conditional) |
| Debugger | `debugger` | Sonnet | Fix issues from test/review/security reports |
| Reviewer | `reviewer` | Sonnet | Code quality review |
| Documenter | `documenter` | Haiku | Create completion report |
| Doc Keeper | `doc-keeper` | Sonnet | Analyze doc drafts, apply approved changes |
| Observer | `observer` | Sonnet | Analyze run, recommend improvements |

Each agent runs in its own isolated context (~200K tokens). Only short summaries return to this orchestrator context.

## Workflow

### Phase 0: Environment Check

Before starting, check task persistence:

```
if CLAUDE_CODE_TASK_LIST_ID is set:
    Tasks persist across sessions — resumable workflow
    Log: "Using shared task list: {CLAUDE_CODE_TASK_LIST_ID}"
else:
    Tasks are conversation-scoped — will not survive session restart
    Log: "Tasks are session-scoped. Set CLAUDE_CODE_TASK_LIST_ID for persistence."
```

### Phase 1: Planning

```
Task(planner):
  prompt: |
    Break down this task into implementable subtasks:
    TASK: {user's task description}
    CODEBASE: {project root}
```

After planner returns:
1. Parse the plan into individual subtasks
2. Create tasks with `TaskCreate` for each subtask:
   - `subject`: "{PREFIX-NNN}: {task name}"
   - `description`: Full details + acceptance criteria from plan. **Include the "Required Reading" section from the plan** — agents need these doc paths.
   - `activeForm`: "Implementing {task name}"
3. Set dependencies with `TaskUpdate(addBlockedBy)` based on the dependency graph
4. If `.claude/orchestration-config.json` exists and `plans` is enabled, save plan to configured path
5. Create doc-drafts run directory:
```
RUN_DIR = "ORCH-{YYYY-MM-DD}-{feature-slug}"
config = Read .claude/orchestration-config.json
if config.documentation.enabled.doc_drafts:
    mkdir -p {config.documentation.paths.doc_drafts}/{RUN_DIR}
```
Pass `DOC_DRAFTS_RUN_DIR` and `DOC_DRAFTS_PATH` to all worker/debugger prompts in Phase 2.

### Phase 2: Task Loop

**IMPORTANT:** `TaskList` returns only id, subject, status, owner, blockedBy — NOT description. Always use `TaskGet(taskId)` to retrieve full task details before passing them to agents.

#### Identify executable tasks

```
tasks = TaskList()
unblocked = [t for t in tasks where t.status == "pending" and t.blockedBy == []]
```

#### Parallel execution of independent tasks

If multiple tasks have no dependencies between them, run their workers concurrently using `run_in_background: true`:

```
if len(unblocked) > 1:
    // Launch workers in parallel (max 4 concurrent)
    background_agents = []
    for task in unblocked[:4]:
        TaskUpdate(task.id, status: "in_progress")
        details = TaskGet(task.id)  // Get full description + acceptance criteria

        agent = Task(worker, run_in_background: true):
          prompt: |
            Implement this task:
            TASK: {details.subject}
            DESCRIPTION: {details.description}
            CONTEXT: {relevant info from completed tasks}
            DOC_DRAFTS_RUN_DIR: {RUN_DIR}
            DOC_DRAFTS_PATH: {config.documentation.paths.doc_drafts}

        background_agents.append({task: task, agent: agent})

    // Collect results as agents complete
    for entry in background_agents:
        result = wait for entry.agent
        // Continue with test → review pipeline for each (sequentially)
        run_task_pipeline(entry.task, result)

else if len(unblocked) == 1:
    // Single task — run in foreground
    run_task_pipeline(unblocked[0])
```

**Why `run_in_background: true`:** Without this flag, each subagent's full result accumulates in the parent context. Background agents return only a lightweight reference, keeping the orchestrator context clean. Collect results via `TaskOutput` when needed.

**Limit:** Max 4 concurrent agents. More than 5 parallel subagents may cause silent connection failures.

#### Task Pipeline (per task)

##### Step 1: Implement (if not already done in parallel)
```
TaskUpdate(taskId, status: "in_progress")
details = TaskGet(taskId)  // MUST use TaskGet, not TaskList

Task(worker):
  prompt: |
    Implement this task:
    TASK: {details.subject}
    DESCRIPTION: {details.description}
    CONTEXT: {relevant info from completed tasks}
    DOC_DRAFTS_RUN_DIR: {RUN_DIR}
    DOC_DRAFTS_PATH: {config.documentation.paths.doc_drafts}
```

##### Step 2: Test
```
Task(test-runner):
  prompt: |
    Verify this implementation:
    TASK: {details.subject}
    ACCEPTANCE CRITERIA: {from details.description}
    CHANGES: {summary from worker}
```

If test-runner reports FAIL — enter retry loop with persistent tracking:

```
// Initialize retry tracking in task metadata
TaskUpdate(taskId, metadata: {"test_retries": 0, "last_test_error": ""})

while status == FAIL:
    current = TaskGet(taskId)
    retries = current.metadata.test_retries

    if retries >= 3:
        TaskUpdate(taskId, metadata: {"status_note": "BLOCKED: max test retries exceeded"})
        Report to user, ask for guidance
        break

    Task(debugger):
      prompt: |
        Fix these issues:
        TEST REPORT: {test-runner output}
        TASK: {details.subject}
        RETRY: {retries + 1} of 3
        DOC_DRAFTS_RUN_DIR: {RUN_DIR}
        DOC_DRAFTS_PATH: {config.documentation.paths.doc_drafts}

    Task(test-runner):
      prompt: |
        Re-verify after fixes:
        PREVIOUS ISSUES: {what was wrong}
        FIX APPLIED: {debugger output}

    TaskUpdate(taskId, metadata: {
        "test_retries": retries + 1,
        "last_test_error": "{brief error description}"
    })
```

##### Step 2.5: Security Audit (conditional)

If the task involves authentication, API endpoints, user input handling, sensitive data, file uploads, or payments — run security audit:

```
Task(security-auditor):
  prompt: |
    Audit security of this implementation:
    TASK: {details.subject}
    FILES CHANGED: {list from worker}
    FOCUS: {relevant security area}
```

If security-auditor finds Critical or High issues — enter retry loop:

```
TaskUpdate(taskId, metadata: {"security_retries": 0})

while severity in [Critical, High]:
    current = TaskGet(taskId)
    retries = current.metadata.security_retries

    if retries >= 3:
        TaskUpdate(taskId, metadata: {"status_note": "BLOCKED: max security retries exceeded"})
        Report to user, ask for guidance
        break

    Task(debugger):
      prompt: |
        Fix these security issues:
        SECURITY REPORT: {security-auditor output}
        TASK: {details.subject}
        DOC_DRAFTS_RUN_DIR: {RUN_DIR}
        DOC_DRAFTS_PATH: {config.documentation.paths.doc_drafts}

    Task(security-auditor):
      prompt: |
        Re-audit after fixes:
        PREVIOUS ISSUES: {what was found}
        FIX APPLIED: {debugger output}

    TaskUpdate(taskId, metadata: {
        "security_retries": retries + 1
    })
```

**When to skip:** Tasks that only change UI styling, documentation, or configuration with no auth/input/API surface.

##### Step 3: Review (optional — skip for simple/low-risk tasks)
```
Task(reviewer):
  prompt: |
    Review code changes for this task:
    TASK: {details.subject}
    FILES CHANGED: {list from worker}
```

If reviewer reports CHANGES REQUESTED — same retry pattern:

```
TaskUpdate(taskId, metadata: {"review_retries": 0})

while status == CHANGES_REQUESTED:
    current = TaskGet(taskId)
    retries = current.metadata.review_retries

    if retries >= 3:
        TaskUpdate(taskId, metadata: {"status_note": "BLOCKED: max review retries exceeded"})
        Report to user, ask for guidance
        break

    Task(debugger):
      prompt: |
        Fix these review issues:
        REVIEW REPORT: {reviewer output}
        DOC_DRAFTS_RUN_DIR: {RUN_DIR}
        DOC_DRAFTS_PATH: {config.documentation.paths.doc_drafts}

    Task(reviewer):
      prompt: |
        Re-review after fixes:
        PREVIOUS ISSUES: {what was flagged}
        FIX APPLIED: {debugger output}

    TaskUpdate(taskId, metadata: {
        "review_retries": retries + 1,
        "last_review_issue": "{brief issue description}"
    })
```

##### Step 4: Complete
```
TaskUpdate(taskId, status: "completed")
// Completing this task auto-unblocks dependent tasks in the DAG
```

**After completing a task:** re-run `TaskList()` to find newly unblocked tasks. Loop back to "Identify executable tasks".

### Phase 3: Documentation

After all tasks complete:
```
Task(documenter):
  prompt: |
    Create a completion report:
    FEATURE: {feature name}
    TASKS COMPLETED: {list of all tasks with summaries}
    FILES CHANGED: {aggregated list}
    TEST RESULTS: {aggregated results}
    CONFIG: Check .claude/orchestration-config.json for report path
```

### Phase 3.5: Documentation Keeper

After documenter creates the completion report, check for documentation drafts:

```
config = Read .claude/orchestration-config.json
if config.documentation.enabled.doc_drafts:
    drafts = Glob("{config.documentation.paths.doc_drafts}/{RUN_DIR}/*.md")

    if drafts.length > 0:
        result = Task(doc-keeper):
          prompt: |
            Analyze documentation drafts and recommend updates:
            FEATURE: {feature name}
            DRAFTS_DIR: {config.documentation.paths.doc_drafts}/{RUN_DIR}
            DRAFT_FILES: {list of draft files found}
            PROJECT_DOCS: Check docs/ directory for target documents
            CONFIG: Read .claude/orchestration-config.json for enabled doc types

        // Present doc-keeper recommendations to user
        // Show the structured recommendations table
        // Ask user: "Apply these documentation updates? (yes/no/partial)"
        // If approved: doc-keeper has already prepared the edits
        // If partially approved: note which were accepted
        // If rejected: note in summary

    else:
        Log: "No doc drafts created — skipping doc keeper"
else:
    Log: "Doc drafts disabled in config — skipping"
```

### Phase 3.75: Orchestration Observer

Run the observer to analyze this orchestration run:

```
config = Read .claude/orchestration-config.json
Task(observer):
  prompt: |
    Analyze this orchestration run and identify improvements:
    FEATURE: {feature name}
    TASKS: {list of all tasks with final status, retry counts from metadata}
    RUN_METRICS:
      - Total tasks: {count}
      - Completed: {count}
      - Blocked: {count}
      - Test retries: {sum of test_retries across all tasks}
      - Review retries: {sum of review_retries across all tasks}
      - Security retries: {sum of security_retries across all tasks}
    ISSUES_CREATED: {list of ISS-NNN files created during run, or "None"}
    DOC_KEEPER_RESULT: {summary — drafts analyzed, changes applied/rejected}
    CONFIG: Check .claude/orchestration-config.json for observer_reports path
```

Save the observer report if `enabled.observer_reports` is true.
```

### Phase 4: Summary

Output to user:
```
## Orchestration Complete

**Feature:** {name}
**Tasks:** {completed}/{total}
**Task persistence:** {CLAUDE_CODE_TASK_LIST_ID or "session-scoped"}

### Results
| Task | Status | Tests | Retries |
|------|--------|-------|---------|
| {ID}: {name} | {status} | {pass/fail} | test:{n} review:{n} |

### Report
{path to report file or "See above"}

### Issues
{any unresolved issues or "None"}

### Doc Updates
{N doc changes applied / "No changes needed" / "User declined" / "Doc drafts disabled"}

### Observer Insights
{Top 3 recommendations from observer, or "No issues found"}
{Path to full observer report, or "Report output above"}
```

## Key Rules

1. **TaskGet before delegation** — always fetch full task details with `TaskGet(taskId)` before passing to any agent. `TaskList` lacks descriptions.
2. **Parallel unblocked tasks** — use `run_in_background: true` for independent tasks (max 4 concurrent). Collect results before proceeding to test/review pipeline.
3. **Persistent retry tracking** — store retry counts in `TaskUpdate(metadata)`, not local variables. This survives context compaction and enables cross-session resumption.
4. **Max 10 subtasks** — ask user before exceeding
5. **Max 3 retries** per stage — escalate to user after, with metadata recording the blocker
6. **Re-check unblocked after completion** — completing a task may unblock dependents in the DAG. Always re-query `TaskList()` after each task completion.
7. **Config-aware** — check `.claude/orchestration-config.json` for documentation paths
8. **Doc drafts flow** — create RUN_DIR in Phase 1, pass DOC_DRAFTS_RUN_DIR and DOC_DRAFTS_PATH to all workers/debuggers, process in Phase 3.5
9. **Observer is last** — always runs after doc-keeper, never modifies code or config files, only produces recommendations

## Reference

- `references/task-tracking.md` — task lifecycle, naming conventions, DAG dependency management, and cross-session persistence
- `references/issue-tracking.md` — when and how to create issue files (ISS-NNN) for non-blocking problems
- `references/documentation-structure.md` — directory purposes, file naming, and which agent creates what
- `references/doc-drafts-format.md` — draft file format, when to create, naming conventions
