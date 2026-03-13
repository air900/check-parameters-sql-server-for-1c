# Documentation Structure Reference

How orchestration agents should organize and create documentation artifacts.

## Configuration-Based Paths

**Always read paths from `.claude/orchestration-config.json`**. Never hardcode paths.

```javascript
config = readJSON(".claude/orchestration-config.json")
paths = config.documentation.paths
enabled = config.documentation.enabled

// Only write to a path if enabled[type] === true
if (enabled.plans) {
  savePlan(paths.plans + "/filename.md")
}
```

## Directory Purpose

| Directory | Purpose | Created By |
|-----------|---------|------------|
| `plans/` | What to build — task breakdown, dependencies, acceptance criteria | planner agent |
| `reports/` | What was built — completion summary, files changed, test results | documenter agent |
| `issues/` | What to fix later — non-blocking problems, tech debt, enhancements | any agent |
| `features/` | Feature descriptions and implementation details | manual or documenter |
| `api/` | API endpoint documentation | manual or documenter |
| `components/` | Component documentation | manual or documenter |
| `architecture/` | Architecture decisions and patterns (ADRs) | manual or documenter |
| `design/` | UI/UX designs, style guides | manual |
| `changelog/` | Version history | manual (or disabled — use `git log`) |
| `doc-drafts/` | Temporary draft files recording doc-impacting changes | worker, debugger, refactor |
| `observer-reports/` | Orchestration analysis and improvement recommendations | observer agent |

## Which Agent Creates What

| Agent | Creates | Location |
|-------|---------|----------|
| planner | Plan files | `paths.plans` |
| documenter | Completion reports | `paths.reports` |
| any agent | Issue files | `paths.issues` |
| documenter | Architecture decision records (from senior-reviewer output) | `paths.architecture` (if enabled) |
| worker, debugger, refactor | Doc draft files | `paths.doc_drafts` |
| doc-keeper | Updates to project docs (on approval) | target docs (e.g., FEATURES.md) |
| observer | Observation reports | `paths.observer_reports` |

## File Naming Conventions

| Type | Format | Example |
|------|--------|---------|
| Plans | `YYYY-MM-DD-feature-name.md` | `2026-02-10-auth-system.md` |
| Reports | `YYYY-MM-DD-feature-implementation.md` | `2026-02-10-auth-implementation.md` |
| Issues | `ISS-NNN-description.md` | `ISS-001-token-refresh-race.md` |
| Features | `feature-name.md` (kebab-case) | `authentication.md` |
| Components | `ComponentName.md` (PascalCase) | `AppSidebar.md` |
| Doc Drafts | `{TASK_ID}-{agent-name}.md` | `AUTH-001-worker.md` |
| Observer Reports | `YYYY-MM-DD-{feature}-observation.md` | `2026-02-16-auth-observation.md` |

## Enabled vs Disabled Types

Some documentation types are disabled by default in `.claude/orchestration-config.json` to prevent AI agents from overwriting hand-written documentation. Check the `enabled` flags before writing.

If a type is disabled but you need to create a file there, output the content in the chat response instead — let the user decide where to save it.

## Guidelines

1. **One topic per file** — don't mix concerns
2. **Always include dates** — when the file was created/updated
3. **Link to code** — reference actual file paths
4. **Keep it current** — archive old/completed items
5. **Cross-reference** — link related docs (plans ↔ reports ↔ issues)
