# User ingress (SSO / magic link)

## Purpose

To let an external system send an **already identified** candidate straight into the interview experience, with no separate login on BEAI.

## Conceptual flow

1. The calling system generates a **secure link** (or redirect) to BEAI;
2. The link carries a **token** (or signed parameters) with the context information;
3. BEAI validates the token, creates or updates the candidate record, and starts the interview session.

## Minimum information to receive

| Field | Required | Description |
|-------|--------------|-------------|
| Candidate identifier | Yes | An opaque string, unique in the context of the calling system. BEAI stores it and echoes it in every notification. |
| Display name | Yes | The full name shown in the UI and used in the AI context |
| Project context | Yes | Reference to the assessment campaign/configuration (project ID or equivalent) |
| Organizational role | Yes | Role code (ICO, FLL, MLL, BUL, SRX) |
| Language | No (default `it`) | Interview language |
| Session expiry | No | Time validity of the link/token |

## Expected BEAI behaviour

- If the candidate **does not exist** for that project → the record is created on first access;
- If they already exist → resume or start a new session according to the business rules (retry, previous status);
- Expired or invalid token → a clear error, no interview start;
- After validation → redirect to the preparation screen (microphone) or straight to the interview.

## On-the-fly candidate creation

The calling system does **not** necessarily have to pre-create the candidate through the API. SSO ingress may be the only creation point.

## Security (a requirement, not an implementation)

- The token must be **non-forgeable** (cryptographic signature or equivalent);
- Transmission preferably over HTTPS;
- A short expiry is recommended (e.g. 15–60 minutes);
- A token must not stay reusable indefinitely after the assessment completes (except in an explicit retry flow).

## Narrative example

> Acme's HR portal generates a link for Mario Rossi (internal ID 672), project "Selezione FLL 2026", role FLL, Italian language. Mario clicks, lands on BEAI, grants microphone access and starts the interview. The identifier `acme-672-mrossi` appears in every subsequent webhook.

## Out of scope for this document

- The signature algorithm (HS256, RS256, etc.);
- URL parameter names (`token`, `session`, etc.);
- The internal format of the candidate identifier.
