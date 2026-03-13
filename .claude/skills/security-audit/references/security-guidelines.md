# Security Guidelines

## 1. Authentication and Authorization

### DO
- Use bcrypt or argon2 for password hashing (never MD5/SHA for passwords)
- Implement rate limiting on login endpoints
- Use secure session management (httpOnly, secure, sameSite cookies)
- Add CSRF protection for state-changing operations
- Use JWT with short expiration and proper signature validation
- Implement account lockout after failed attempts
- Use MFA for sensitive operations

### DON'T
- Store passwords in plain text
- Expose internal user IDs in URLs
- Rely solely on client-side validation for auth
- Implement custom cryptographic algorithms
- Use the implicit OAuth flow
- Expose client secrets in frontend code

## 2. Input Validation and Sanitization

### DO
- Validate all input server-side (type, length, format, range)
- Use allowlists over denylists for validation
- Sanitize HTML output to prevent XSS
- Validate file uploads (type, size, content — not just extension)
- Use parameterized queries for all database operations

### DON'T
- Trust any data from the client
- Concatenate user input into SQL, shell commands, or code strings
- Skip validation because "the frontend validates it"

## 3. API Security

### DO
- Enforce HTTPS for all endpoints
- Implement rate limiting (per user, per IP, per endpoint)
- Validate Content-Type headers
- Configure CORS properly (specific origins, not wildcard in production)
- Return generic error messages to clients
- Log security events (failed logins, permission denied, unusual patterns)

### DON'T
- Expose stack traces or internal errors to clients
- Return sensitive data in error responses
- Use predictable API keys or tokens
- Allow unlimited request sizes

## 4. Secrets Management

### DO
- Use environment variables for all secrets
- Use dedicated secret management tools for production (AWS Secrets Manager, Vault)
- Rotate credentials regularly
- Use different secrets per environment
- Add .env files to .gitignore

### DON'T
- Commit secrets, API keys, or credentials to version control
- Hardcode secrets in source code
- Log secrets or include them in error messages
- Share credentials between environments

## 5. Data Protection

### DO
- Encrypt PII and payment data at rest
- Use HTTPS for all data in transit
- Implement role-based access control (RBAC)
- Minimize data collection (only what's needed)
- Implement secure data deletion when required

### DON'T
- Store more data than necessary
- Log sensitive information (PII, credentials, tokens)
- Share data without proper consent mechanisms

## 6. Dependencies and Supply Chain

### DO
- Run `npm audit` / `pip audit` regularly
- Use lock files (package-lock.json, requirements.txt)
- Review dependencies before adding them
- Pin dependency versions
- Use tools like Snyk or Dependabot

### DON'T
- Use packages with known vulnerabilities
- Install from untrusted sources
- Skip reviewing new dependency additions

## 7. Frontend Security

### DO
- Set Content Security Policy (CSP) headers
- Use Subresource Integrity (SRI) for CDN resources
- Escape and sanitize all dynamic output
- Use framework built-in XSS protection
- Validate on both frontend AND backend

### DON'T
- Render unsanitized user content as HTML
- Store secrets or tokens in localStorage
- Disable CSP or set it to allow everything
- Trust client-side-only validation

### CSP Header Example (Next.js)

```typescript
// next.config.ts — security headers
const securityHeaders = [
  {
    key: 'Content-Security-Policy',
    value: [
      "default-src 'self'",
      "script-src 'self' 'unsafe-inline'",  // tighten in production
      "style-src 'self' 'unsafe-inline'",
      "img-src 'self' data: https:",
      "font-src 'self'",
      "connect-src 'self' https://api.example.com",
      "frame-ancestors 'none'",
    ].join('; '),
  },
  { key: 'X-Frame-Options', value: 'DENY' },
  { key: 'X-Content-Type-Options', value: 'nosniff' },
  { key: 'Referrer-Policy', value: 'strict-origin-when-cross-origin' },
];
```

### HTML Sanitization Example

```typescript
import DOMPurify from 'dompurify';

// Always sanitize user-generated HTML before rendering
const safeHtml = DOMPurify.sanitize(userContent, {
  ALLOWED_TAGS: ['b', 'i', 'em', 'strong', 'a', 'p', 'br'],
  ALLOWED_ATTR: ['href', 'title'],
});

// In React: prefer text content over innerHTML
// If HTML rendering is unavoidable, always sanitize with DOMPurify first
```

## 8. WebSocket and SSE Security

### DO
- Authenticate WebSocket connections on handshake
- Validate and sanitize all incoming messages
- Implement per-connection rate limiting
- Set message size limits
- Use wss:// (TLS) in production

### DON'T
- Trust message content from clients
- Allow unauthenticated connections to sensitive channels
- Broadcast sensitive data to all connections without authorization

## OWASP Top 10 Quick Reference

| # | Vulnerability | Key Mitigation |
|---|--------------|----------------|
| 1 | Injection | Parameterized queries, input validation |
| 2 | Broken Authentication | MFA, rate limiting, secure sessions |
| 3 | Sensitive Data Exposure | Encryption at rest/transit, minimal collection |
| 4 | XML External Entities | Disable DTD processing, use JSON |
| 5 | Broken Access Control | RBAC, server-side checks, deny by default |
| 6 | Security Misconfiguration | Hardened defaults, remove unused features |
| 7 | Cross-Site Scripting | Output encoding, CSP, framework protections |
| 8 | Insecure Deserialization | Validate input types, integrity checks |
| 9 | Known Vulnerabilities | Dependency scanning, regular updates |
| 10 | Insufficient Logging | Centralized logging, alerting, audit trails |

## Security Checklists

### Authentication Feature
- [ ] Passwords hashed with bcrypt/argon2
- [ ] Rate limiting on login endpoint
- [ ] Secure session configuration
- [ ] CSRF protection
- [ ] Secure password reset flow
- [ ] Account lockout policy

### API Endpoint
- [ ] Input validation (server-side)
- [ ] Authentication required
- [ ] Authorization checks
- [ ] Rate limiting
- [ ] CORS configuration
- [ ] Generic error responses
- [ ] Security headers set

### Database Operation
- [ ] Parameterized queries only
- [ ] Sensitive data encrypted
- [ ] Access control enforced
- [ ] Audit logging enabled

### File Upload
- [ ] File type validation (content, not just extension)
- [ ] Size limits enforced
- [ ] Stored outside web root
- [ ] Access control on uploaded files
