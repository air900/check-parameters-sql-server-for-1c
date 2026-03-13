# Task Tracking and State Management

## Task Lifecycle

```
pending → in_progress → completed
                      → (deleted if cancelled)
```

Tasks are managed through Claude Code's native system:
- `TaskCreate` — create a new task
- `TaskUpdate` — change status, add dependencies
- `TaskGet` — get full task details (description, metadata)
- `TaskList` — list all tasks (summary only, no descriptions)

**Important:** `TaskList` returns only id, subject, status, owner, blockedBy — NOT description. Use `TaskGet` for full details.

## DAG Dependencies

Tasks form a Directed Acyclic Graph (DAG) via `addBlockedBy` and `addBlocks`:

```
TaskCreate(subject: "AUTH-001: Create user model")     → id: 1
TaskCreate(subject: "AUTH-002: Add auth middleware")    → id: 2
TaskCreate(subject: "AUTH-003: Create login endpoint")  → id: 3

TaskUpdate(taskId: "2", addBlockedBy: ["1"])  // middleware needs model
TaskUpdate(taskId: "3", addBlockedBy: ["2"])  // endpoint needs middleware
```

When AUTH-001 completes → AUTH-002 auto-unblocks.
When AUTH-002 completes → AUTH-003 auto-unblocks.

**Parallelization:** Tasks without dependencies (e.g., AUTH-001 and UI-001) can run concurrently.

## Task Naming Conventions

### Task ID Prefixes

| Prefix | Domain |
|--------|--------|
| AUTH-NNN | Authentication/authorization |
| PAY-NNN | Payments/billing |
| API-NNN | API endpoints |
| UI-NNN | User interface |
| DB-NNN | Database/data layer |
| REF-NNN | Refactoring |
| TEST-NNN | Testing infrastructure |
| INFRA-NNN | Infrastructure/DevOps |

### TaskCreate Fields

```
subject: "AUTH-001: Create user model"           // imperative, with prefix
description: |                                    // full details
  Create the User model with fields: id, email, password_hash, role, created_at.
  File: src/models/user.ts
  Acceptance criteria:
  - User model exported with TypeScript types
  - Password field stores hash, never plain text
  - Role field uses enum (admin, user, viewer)
activeForm: "Creating user model"                 // present continuous
```

## Cross-Session Persistence

By default, tasks are scoped to the current conversation session. For cross-session persistence:

```bash
CLAUDE_CODE_TASK_LIST_ID=my-project-auth claude
```

This stores tasks in `~/.claude/tasks/my-project-auth/` and allows multiple sessions to share the same task list.

**Best practice:** Use specific IDs like `myproject-auth-feature` to avoid collisions.

## Task Progress Display

Toggle task list visibility: `Ctrl+T` (shows up to 10 tasks in terminal).

## Retry Tracking

Track retries in task metadata:

```
TaskUpdate(taskId: "2", metadata: {
  "test_retries": 1,
  "review_retries": 0,
  "last_error": "lint: unused import in auth.ts:5"
})
```

## Configuration-Based Documentation

If `.claude/orchestration-config.json` exists:

```json
{
  "documentation": {
    "paths": {
      "plans": "ai_docs/develop/plans",
      "reports": "ai_docs/develop/reports"
    },
    "enabled": {
      "plans": true,
      "reports": true
    }
  }
}
```

- Plans saved to `paths.plans` (if enabled)
- Reports saved to `paths.reports` (if enabled)
- If config doesn't exist or path is disabled → output in chat only

## v1 vs v2 Comparison

| Aspect | v1 (work-orch) | v2 (work-orch-v2) |
|--------|----------------|-------------------|
| Agent definitions | `references/prompts/*.md` | `.claude/agents/*.md` with YAML frontmatter |
| Context loading | "Read your prompt file" | Auto-loaded from agent definition |
| Model per agent | Hardcoded in SKILL.md | YAML `model:` field per agent |
| Tool restrictions | None | YAML `tools:`/`disallowedTools:` per agent |
| Task dependencies | Flat list | DAG with `addBlockedBy`/`addBlocks` |
| Pipeline hooks | None | `SubagentStop` for stage transitions |
| Background execution | Not used | `run_in_background: true` for workers |
