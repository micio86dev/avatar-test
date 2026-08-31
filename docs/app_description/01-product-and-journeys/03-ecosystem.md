# Ecosystem context

## Positioning

BEAI is the **assessment platform** (interview + evaluation). It is not the customer's HR portal.

Typically:
- The **customer portal** hosts already-authenticated users (email, name, internal ID);
- An action in the portal (e.g. "Start assessment") generates a link to BEAI;
- At the end, the candidate returns to the originating portal;
- The results reach the portal through **asynchronous notifications**.

## Information known about the candidate (on the calling side)

The calling system always knows at least:
- email;
- first and last name;
- the user identifier in its own system.

BEAI must be able to receive this information (or a subset of it) at ingress and associate it with the candidate record.

## Opaque candidate identifier

A **stable identifier** is essential. It:
- is passed in at ingress;
- is stored by BEAI and **echoed unchanged** in every outbound notification;
- lets the calling system tie events and results back to its own user.

The internal format of this identifier is **up to the new project**. Compatibility with legacy formats is not required.

## Multi-tenant and multi-portal

In production the following coexist:
- multiple **customer organizations** (companies);
- multiple **portals / calling systems** sending candidates;
- multiple **projects** per organization (different campaigns by role or type).

The new platform must support:
- data isolation per tenant;
- flexible configuration of return URLs and notification endpoints **per project or per tenant** (avoiding mandatory intermediaries such as a centralised "router").

## What NOT to reproduce from the current architecture

The current version uses an intermediary component (a "router") because the legacy platform did not allow configuring webhooks and return URLs for each portal/project.

**In the rebuild:** design natively for per-tenant or per-project configuration of:
- the destination webhook URL;
- the post-assessment redirect URL;
- the notification authentication secret.

This removes the need for routing based on parsing the candidate identifier.

## Responsibility boundaries

| Component | Responsibility |
|------------|----------------|
| Customer portal | User authentication, pre/post assessment UX, webhook reception |
| BEAI (this project) | Interview, assessment storage, evaluation, admin, API |
| AI engine | Adaptive conversation, scoring (may be an internal module or a separate service) |
| Audio services | Realtime TTS/STT (provider of choice) |
