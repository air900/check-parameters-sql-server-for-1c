---
name: 012-update-docs
description: Post-task documentation verification. Use after completing code changes to verify documentation accuracy. Core question is "Did my changes make docs INCORRECT?" — not "should I add docs?" Requires grep evidence for every claim.
---

# Documentation Verification Skill

**After code changes, verify that existing documentation is still CORRECT.**

## Core Question

> "Did my changes make any documentation statement INCORRECT?"

This is NOT about adding documentation. This is about ensuring existing docs don't contain lies.

---

## Phase 1: Identify Affected Docs

List all documentation files that could be affected by your changes:

```bash
# Find docs that reference files you changed
grep -rn "CHANGED_FILE_NAME" docs/ --include='*.md'
grep -rn "CHANGED_FILE_NAME" CLAUDE.md
```

Output:
```
═══════════════════════════════════════════════════════════════
                📋 DOCS VERIFICATION
═══════════════════════════════════════════════════════════════

Changed files:
- src/features/hr-dashboard-v2/xxx/components/YYY.tsx
- src/lib/chart-colors.ts

Potentially affected docs:
- CLAUDE.md (references chart-colors.ts)
- docs/hr-dashboard/CHART-STYLE-GUIDE.md (references chart patterns)
- docs/DEVELOPMENT-RULES.md (references chart-colors.ts)

═══════════════════════════════════════════════════════════════
```

## Phase 2: Verify Each Claim

For each affected doc, verify **specific claims** against the actual codebase.

**Minimum 3 grep checks per document.**

### Verification Pattern

For each doc, identify concrete claims and verify them:

```bash
# Claim: "CHART_COLORS has 5 entries"
grep -c "var(--chart-" src/lib/chart-colors.ts
# Expected: 5. If different → doc is wrong.

# Claim: "Badge has variant status-success"
grep -n "status-success" src/components/ui/badge.tsx
# Expected: found. If not found → doc is wrong.

# Claim: "CardFooter is used in chart cards"
grep -rn "CardFooter" src/features/hr-dashboard-v2/ --include='*.tsx' | head -5
# Expected: multiple results. If 0 → doc is wrong.
```

## Phase 3: Output Verdict

```
═══════════════════════════════════════════════════════════════
                📋 DOCS VERIFICATION RESULT
═══════════════════════════════════════════════════════════════

## Checks Performed

| # | Doc | Claim | Grep Command | Result |
|---|-----|-------|-------------|--------|
| 1 | CHART-STYLE-GUIDE.md | 5 chart colors | grep -c "var(--chart-" chart-colors.ts | ✅ 5 found |
| 2 | DEVELOPMENT-RULES.md | No banned terms | grep "подразделени" dashboard/ | ✅ 0 found |
| 3 | CLAUDE.md | CardFooter required | grep "CardFooter" dashboard/ | ✅ 12 found |

## Verdict: ✅ DOCS ACCURATE / ⚠️ DOCS NEED UPDATE

[If updates needed, list specific lines to change]

═══════════════════════════════════════════════════════════════
```

## Phase 4: Fix Inaccuracies (if any)

If a doc claim is wrong:

1. **Fix the doc** — update the incorrect statement
2. **Don't duplicate** — link to SSOT instead of copying values
3. **Verify the fix** — grep again to confirm new claim is accurate

## Anti-Patterns

### ❌ "Should I add docs?"
Wrong question. Only ask "Are existing docs still correct?"

### ❌ Copying values into docs
If the code is the source of truth, link to it. Don't copy lists, enums, or configuration.

### ❌ Skipping grep verification
Every claim about code must have a grep command backing it. "I checked visually" is not evidence.

### ❌ Documenting implementation details
Types, props, mock data structures — these belong in code, not docs. Docs explain concepts and patterns.

## SSOT Principle

```
If it's defined in code → docs LINK to code
If it's a pattern/concept → docs EXPLAIN the pattern
If it will change with code → don't document it
If it's a list/catalog → stays in code only
```

**Test:** If changing the code requires updating docs → you duplicated. Fix the doc to link instead.

## Quick Checklist

```
□ Identified all docs referencing changed files
□ Minimum 3 grep checks per affected doc
□ Each check has: claim, grep command, expected result, actual result
□ No raw values duplicated from code
□ No stale references to deleted/renamed files
□ Verdict output with evidence table
```
