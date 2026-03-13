---
name: deploy-orchestration
description: Interactive orchestration setup — Phase 2 after deploy.sh. User provides initial task context, then skill asks clarifying questions, discovers skills via find-skills, and generates CLAUDE.md. Use when setting up orchestration in a new project.
---

# Deploy Orchestration — Phase 2 (Interactive)

**Prerequisite:** `deploy.sh` has already copied agents, skills, config, and hooks to this project.

**Usage:**
```
/deploy-orchestration [initial context]
```

The initial context is a brief description of what the project is about. It sets the direction — then the skill asks follow-up questions to configure everything properly.

**Examples:**
```
/deploy-orchestration develop wordpress plugin for SEO optimization
/deploy-orchestration build REST API for user management with FastAPI
/deploy-orchestration create React dashboard with charts and auth
/deploy-orchestration collection of automation scripts for data processing
```

**If no context provided**, show these examples and ask:
```
What will you be building in this project? Describe briefly — I'll ask follow-up questions.
```

## Workflow

### Step 1: Read Initial Context & Scan Project

Take the user's description as starting context. Then scan the project:

```
1. Read package.json / pyproject.toml / go.mod / Cargo.toml (whichever exists)
2. Read README.md if it exists
3. Scan directory structure (ls top-level + src/ if exists)
4. Note what deploy.sh already set up (check .claude/agents/, .claude/skills/, settings.json)
```

Combine user input + detected info. Output a brief summary:
```
Got it — "{user's description}".
Detected: {language/framework if found, or "fresh project, no code yet"}
```

### Step 2: Ask Clarifying Questions

**This is the key step.** Ask the user focused questions to understand the project well enough to pick the right skills and generate a useful CLAUDE.md.

Use the AskUserQuestion tool. Ask **2-4 questions** depending on how much was already clear from the initial context.

#### Question 1: Project structure (always ask)

```
How is this project organized?

  1. Single project — one app/plugin/API/library in this repo
  2. Multiple sub-projects — several related but independent things
     (e.g., scripts + plugins + tools, or themes + plugins + blocks)
```

If user selects "Multiple sub-projects", follow up:
```
List the sub-projects with short descriptions.
Example: "scrapers: web scrapers, parsers: data parsers, reporters: report generators"
```

#### Question 2: Tech stack (ask if not obvious from context + detected files)

```
What tech stack will you use?

Examples:
  - PHP + WordPress
  - TypeScript + React + Next.js
  - Python + FastAPI + PostgreSQL
  - Go + gRPC
  - Vanilla JS, no framework
```

Skip this if the tech stack is already clear from:
- The user's initial description ("FastAPI" → Python + FastAPI)
- Detected files (package.json with react → React)

#### Question 3: Key features or domains (ask to improve skill search)

```
What are the main areas this project will cover?
This helps me find the right skills for your stack.

Examples for a WordPress SEO plugin:
  - SEO meta tags, sitemaps, schema markup, performance optimization

Examples for a React dashboard:
  - Auth, data tables, charts, form validation, API integration
```

#### Question 4: Development conventions (optional, ask for non-trivial projects)

```
Any specific conventions or requirements?

  1. Standard — I'll set up sensible defaults
  2. I have preferences — (describe: testing framework, code style, commit conventions, etc.)
```

### Step 3: Discover & Install Skills

Based on collected answers, extract search keywords and find relevant skills:

```bash
# Build keyword list from:
# - Tech stack answer (react, nextjs, fastapi, wordpress...)
# - Feature areas (auth, charts, forms, seo...)
# - Detected language

npx skills find [keyword1]
npx skills find [keyword2]
npx skills find [keyword3]
# ... up to 3-4 targeted searches
```

Present results to user:
```
Found skills for your project:

1. vercel-labs/agent-skills@vercel-react-best-practices
   React/Next.js performance optimization from Vercel Engineering

2. giuseppe-trisciuoglio/developer-kit@shadcn-ui
   Complete shadcn/ui component library patterns

Which ones should I install? (select from list)
```

For each selected skill:
```bash
npx skills add {package} -y
```

Create symlinks for Claude Code visibility:
```bash
ln -sf ../../.agents/skills/{name} .claude/skills/{name}
```

If no relevant skills found:
```
No additional skills found for [keywords]. The 7 base skills cover
code quality, security, and orchestration — you're good to start.
```

### Step 4: Set Up Multi-Purpose Structure (if applicable)

For multi-purpose projects, create sub-project directories from Step 2 answers:

```bash
mkdir -p src/{sub-project-1}
mkdir -p src/{sub-project-2}
# ...
```

### Step 5: Generate CLAUDE.md

Build CLAUDE.md from all collected information. The content should be specific to THIS project, not generic.

**For atomic projects**, generate:

```markdown
# {Project Name}

{Purpose — from user's context + clarifying answers}

## Tech Stack

{Language, framework, key libraries — from Step 2 answers}

## Commands

```bash
{Detected or standard commands for the stack}
# Example for Python: pip install -e ., pytest, ruff check
# Example for Node: npm install, npm run dev, npm test
```

## Project Conventions

{From Step 2 Q4 answers, or sensible defaults}

## Claude Automations

### Skills

**Workflow:**
- `/orchestrate` — Full development cycle (Plan > Code > Test > Review > Fix > Document). For complex multi-step features.
- `/implement` — Simple workflow (Code > Test > Document). For single components or endpoints.
- `/012-update-docs` — Post-task documentation verification.

**Quality:**
- `/code-review` — Manual code review for quality, bugs, security, best practices.
- `/arch-review` — Architecture review for design patterns, SOLID, dependencies.
- `/security-audit` — Security vulnerability audit (OWASP Top 10).
- `/refactor-code` — Guided code refactoring without behavior change.

{FOR EACH INSTALLED EXTERNAL SKILL:}
**External:**
- `/{skill-name}` — {skill description}

### Agents

**Pipeline** (used by `/orchestrate` and `/implement`):
- `planner` — Break task into subtasks with dependencies
- `worker` — Implement code for each subtask
- `test-runner` — Run lint + tests + verify
- `debugger` — Fix issues from test/review/security reports
- `reviewer` — Code quality review
- `security-auditor` — Security vulnerability scanning
- `documenter` — Create completion report
- `doc-keeper` — Analyze doc drafts, recommend and apply doc updates
- `observer` — Analyze orchestration run, identify improvements

**Quality** (used by standalone quality skills):
- `senior-reviewer` — Architecture review with health scores (used by `/arch-review`)
- `refactor` — Code refactoring specialist (used by `/refactor-code`)

### Hooks

- **SubagentStop**: Pipeline transition hints for all 9 agents
- **PreToolUse**: Safety guard blocking `rm -rf`, `git push --force`, `git reset --hard`
{IF LANGUAGE HOOKS:}
- **PostToolUse:Edit**: {language}-specific type/lint check after edits
- **PostToolUse:Write|MultiEdit**: Auto-format for {language} files

### Config

- `.claude/orchestration-config.json` — Paths and toggles for AI-generated artifacts (plans, reports, issues, doc-drafts, observer-reports)
```

**For multi-purpose projects**, add after the Config section:

```markdown
---

## Sub-Projects

| Name | Path | Description |
|------|------|-------------|
{FOR EACH SUB-PROJECT from Step 2:}
| {name} | src/{name}/ | {description} |

{FOR EACH SUB-PROJECT:}
### Sub-Project: {name}

**Path:** `src/{name}/`
**Description:** {description}
**Tech stack:** {from Step 2 answers}
**Build/Run:** {detected or TBD}

**Conventions:**
- {from answers or placeholder for user to fill in}
```

### Step 6: Apply to CLAUDE.md

If CLAUDE.md exists:
1. Check if it already has a `## Claude Automations` section (grep for it)
2. If yes: ask user whether to replace or append
3. If no: append the generated section at the end

If CLAUDE.md does not exist:
1. Create it with the full generated content from Step 5

### Step 7: Output Summary

```
Orchestration setup complete!

Project: {name}
Type: {atomic | multi-purpose}
Purpose: {from conversation}
Tech stack: {from answers}
Base skills: 7 (orchestrate, implement, code-review, arch-review, security-audit, refactor-code, 012-update-docs)
External skills: {count} ({list names})
Agents: 11

CLAUDE.md: {created | updated}
Config: .claude/orchestration-config.json

Ready to use:
  /orchestrate [complex task]  — Full pipeline with planning
  /implement [simple task]     — Quick implementation
  /code-review                 — Review recent changes
```

## Key Rules

1. **Initial description is context, not final answer** — always ask clarifying questions
2. **Ask smart questions** — skip what's already obvious from context + file detection
3. **2-4 questions max** — don't interrogate, ask focused questions that improve the outcome
4. **Always ask about project structure** (atomic vs multi) — don't auto-detect this silently
5. **Always ask before modifying existing CLAUDE.md** — never silently overwrite
6. **Install skills locally** (no `-g` flag) — keep project self-contained
7. **Create symlinks** for installed skills — ensures `.claude/skills/` visibility
8. **Don't install base skills via npx** — they were already copied by deploy.sh
9. **Verify .claude/orchestration-config.json exists** before finishing — it's required by agents
10. **If no initial context provided**, show usage examples and ask user to describe the project
