---
name: security-audit
description: Security vulnerability audit against OWASP Top 10. Use when code handles authentication, user input, APIs, or sensitive data.
---

# Security Audit

**Usage:**
- `/security-audit` — audit recent changes
- `/security-audit src/auth/` — audit specific directory
- `/security-audit src/api/payments.ts` — audit specific file

## Process

1. **Identify scope:**
   - If path provided → audit that path
   - If no path → `git diff HEAD` for recent changes
   - Focus on security-sensitive code paths

2. **Delegate to security-auditor agent:**
   ```
   Task(security-auditor):
     prompt: |
       Audit this code for security vulnerabilities:
       SCOPE: {files to audit}
       CONTEXT: {what this code does, if known}
   ```

3. **Report findings** with severity levels

## When to Use

- Code handling authentication or authorization
- API endpoints processing user input
- File upload handling
- Sensitive data processing (PII, payments)
- External API integrations
- Session/cookie management

## Reference

See `references/security-guidelines.md` for OWASP Top 10 checklist and security best practices.
