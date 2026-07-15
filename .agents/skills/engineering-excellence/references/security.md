# Security

Security is built in, not bolted on. Use secure defaults and fail closed.

Core practices:

- Validate and sanitize all input; never trust the client.
- Protect secrets — never commit them; load them from the environment (see
  references/environments.md).
- Apply the principle of least privilege.
- Use safe, well-maintained dependencies (see references/dependencies.md).
- Practice defensive programming and handle errors without leaking internals.

## Web hardening

For web-facing applications, when applicable:

- Set appropriate security headers.
- Define a Content Security Policy (CSP).
- Enforce HTTPS and secure cookie attributes.

These are part of shipping to production — see references/production-readiness.md.
