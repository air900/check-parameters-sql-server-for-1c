# Documentation Drafts Reference

How agents record documentation-impacting changes during orchestration for the doc-keeper to process.

## Overview

During orchestration, code-modifying agents (worker, debugger, refactor) evaluate whether their changes impact project documentation. If yes, they create draft files in a shared run directory. After all tasks complete, the doc-keeper agent collects and processes these drafts.

## Run Directory

Each orchestration run creates a directory for its drafts:

```
{paths.doc_drafts}/ORCH-{YYYY-MM-DD}-{feature-slug}/
```

Example: `ai_docs/develop/doc-drafts/ORCH-2026-02-16-auth-system/`

The orchestrator creates this directory in Phase 1 and passes the path to all agents.

## Draft File Naming

```
{TASK_ID}-{agent-name}.md
```

Examples:
- `AUTH-001-worker.md` — worker's draft for task AUTH-001
- `API-002-debugger.md` — debugger's draft for task API-002
- `UI-003-refactor.md` — refactor agent's draft for task UI-003

One file per agent per task. If a debugger fixes a worker's task, both may create separate draft files.

## Draft File Format

```markdown
# Doc Draft: {TASK-ID}
**Agent**: {agent-name}
**Task**: {task description}
**Date**: {YYYY-MM-DD}

## Entries

### Entry 1
- **Change**: {what was changed in code — factual}
- **Context**: {why it was changed — business reason}
- **Impacts**: {which docs: FEATURES.md, COMPONENTS.md, ARCHITECTURE.md, etc.}
- **Suggestion**: {specific text or section to add/modify in the target doc}

### Entry 2
...additional entries if multiple doc-impacting changes in one task
```

## When to Create Drafts

### CREATE a draft when:
| Change Type | Example | Target Doc |
|-------------|---------|------------|
| New component added | `UserProfile.tsx` created | COMPONENTS.md, FEATURES.md |
| Component API changed | New prop `onSubmit` added | COMPONENTS.md |
| New feature/module | `features/notifications/` created | FEATURES.md |
| File structure changed | Moved `utils/` to `lib/` | ARCHITECTURE.md, import examples |
| Architecture pattern | Introduced event bus pattern | ARCHITECTURE.md |
| Config/setup changed | New env variable required | README.md, setup guides |
| New API endpoint | `POST /api/users` added | API docs |

### DO NOT create a draft when:
| Change Type | Why Not |
|-------------|---------|
| Bug fix (same API) | No external interface changed |
| Internal refactoring | No documented paths/names affected |
| Style/formatting | No conceptual change |
| Test additions | Tests document themselves |
| Comment updates | Comments are code, not docs |

## How Doc-Keeper Processes Drafts

1. **Collect** — Reads all `*.md` files in the run directory
2. **Parse** — Extracts structured entries from each draft
3. **Verify** — Greps target docs to check if info already exists
4. **Group** — Organizes changes by target document
5. **Recommend** — Creates specific, actionable recommendations with exact text
6. **Present** — Shows recommendations to user via orchestrator
7. **Apply** — On user approval, edits target docs using Edit/Write tools

## Configuration

Draft paths are controlled by `.claude/orchestration-config.json`:

```json
{
  "documentation": {
    "paths": {
      "doc_drafts": "ai_docs/develop/doc-drafts"
    },
    "enabled": {
      "doc_drafts": true
    }
  }
}
```

If `enabled.doc_drafts` is `false`, agents skip draft creation entirely.
