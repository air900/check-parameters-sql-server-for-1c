---
name: refactor-code
description: Guided code refactoring to improve structure without changing behavior. Use when code review finds issues, or code has smells like long functions or duplication.
---

# Refactor Code

**Usage:**
- `/refactor-code src/utils/helpers.ts` — refactor specific file
- `/refactor-code "Extract function from UserComponent"` — specific refactoring
- `/refactor-code "Apply repository pattern to data layer"` — pattern-based refactoring

## Process

1. **Analyze current state:**
   - Read the target code
   - Identify code smells (see reference)
   - Check for existing tests

2. **Plan refactoring:**
   - List specific changes to make
   - Verify tests exist (refactoring without tests is dangerous)
   - Decide on sequence (one refactoring at a time)

3. **Execute with refactor agent:**
   ```
   Task(refactor):
     prompt: |
       Refactor this code:
       TARGET: {file or component}
       REFACTORING: {specific change}
       CONSTRAINT: Do not change behavior. Tests must pass before and after.
       CURRENT CODE: {relevant code}
   ```

4. **Verify with test-runner:**
   ```
   Task(test-runner):
     prompt: |
       Verify refactoring didn't break anything:
       CHANGES: {what was refactored}
       TESTS: Run all tests for the affected module
   ```

5. **Report results:**
   ```
   ## Refactoring Complete

   **Target:** {file/component}
   **Type:** {Extract Function / Guard Clauses / etc.}

   ### Changes
   - {what was changed}

   ### Before/After
   - Complexity: {before} → {after}
   - Lines: {before} → {after}
   - Functions: {count before} → {count after}

   ### Tests
   {all passing / issues found}
   ```

## Golden Rules

1. **No behavior change** — tests must pass before AND after
2. **Small steps** — one refactoring at a time
3. **Keep working** — code should compile after each step
4. **Test coverage** — don't refactor without tests (write them first if needed)

## Reference

See `references/refactoring-patterns.md` for code smells, detection methods, and refactoring techniques.
