# Integration surface — overview

This section describes **what** the BEAI platform must be able to do towards the outside, without prescribing **how** (protocols, formats, authentication).

## Goal

To let third-party systems (HR portals, LMSs, customer applications):
1. **Send** authenticated candidates into the assessment;
2. **Manage** (optionally through an API) tenants, projects and candidates;
3. **Receive** progress updates and results;
4. **Receive** the candidate back at the end of the interview.

## The four blocks

| Block | File | Purpose |
|--------|------|-------|
| Ingress | [01-sso-ingress.md](./01-sso-ingress.md) | Magic link / SSO to start a session |
| API | [02-api-capabilities.md](./02-api-capabilities.md) | Machine-to-machine operations |
| Webhooks | [03-webhook-events.md](./03-webhook-events.md) | Push notifications to external systems |
| Exit | [04-user-exit.md](./04-user-exit.md) | Post-assessment redirect |

## Design principles

- **Per-tenant/project configurability:** every customer can have different webhook and redirect URLs, with no mandatory intermediate components.
- **Opaque identifier:** a stable candidate ID travels through the whole cycle (ingress → webhook → exit).
- **Security:** strong authentication on APIs and notifications (mechanism of choice: HMAC, JWT, API key, mTLS, etc.).
- **Idempotency:** calling systems must be able to handle duplicate notifications without corrupting data.
- **OpenAPI documentation:** the supplier is expected to produce the definitive technical specification starting from this outline.

## What is NOT in this section

- Specific REST paths;
- The exact JWT format or headers;
- Compatibility with the APIs or webhooks of the previous version.
