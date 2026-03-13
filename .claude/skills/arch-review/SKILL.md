---
name: arch-review
description: Architecture review for design patterns, SOLID principles, dependencies, and scalability. Use when evaluating technical decisions or starting new features.
---

# Architecture Review

**Usage:**
- `/arch-review` — review full project architecture
- `/arch-review src/services/` — review specific module
- `/arch-review "Should we add Redis for caching?"` — evaluate a technical decision

## Process

1. **Identify scope:**
   - If path provided → focus on that area
   - If question → research and evaluate
   - If no args → review overall project architecture

2. **Review architecture with senior-reviewer agent:**
   ```
   Task(senior-reviewer):
     prompt: |
       Review the architecture of this project:
       SCOPE: {path or question}
       Focus on: project structure, design patterns, dependencies,
       separation of concerns, coupling, and scalability.
       Output health score and recommendations.
   ```

3. **Review against principles** from `references/architecture-principles.md`

4. **Report findings** with health score and recommendations

## Review Dimensions

1. **Project Structure** — organization, boundaries, separation of concerns
2. **Design Patterns** — appropriate usage, consistency, over/under-engineering
3. **Dependencies** — coupling, circular deps, abstraction levels
4. **Scalability** — bottlenecks, state management, caching
5. **Maintainability** — code organization, tech debt, ease of extension

## When to Use

- Starting a new feature or module
- Making architectural decisions (tech choices, patterns)
- Evaluating existing architecture before a major refactor
- Code review at the system level (not just file level)

## Reference

See `references/architecture-principles.md` for SOLID principles, design patterns, and anti-patterns.
