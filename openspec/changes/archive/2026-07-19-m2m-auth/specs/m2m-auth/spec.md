# M2M API Authentication Specification

## Purpose

Opaque API-key authentication for external machine clients (HR/LMS/ATS systems).
Delivers the `ApiClient` model, custom guard, org resolution, ability model, and
admin credential-management API that later business endpoints (C6/C10) sit behind.

## Non-Goals

- Backoffice user JWT auth (C2, done)
- Candidate magic-link SSO (C6)
- Webhook delivery, HMAC signing, retry (C10)
- Participant and business endpoints (C6/C10)
- Rate-limiting delivery (C13)
- Backoffice credential management UI (C11)

---

## Requirements

### Requirement: ApiClient Model and Schema

The system MUST provide an `ApiClient` Eloquent model that implements
`Illuminate\Contracts\Auth\Authenticatable` DIRECTLY via the
`Illuminate\Auth\Authenticatable` trait. It MUST NOT extend
`Illuminate\Foundation\Auth\User` (which imports `Authorizable::can()`, clashing
with the custom `can(string $ability): bool` ability helper). `ApiClient` is NOT a
`User` and NOT a `TenantModel`. The `api_clients` table MUST contain: `id`,
`organization_id` (FK → `organizations.id`, indexed), `name`, `key_hash` (unique),
`abilities` (JSONB), `is_active` (default `true`), `expires_at` (nullable,
`timestampTz`), `last_used_at` (nullable, `timestampTz`), `timestamps`. App and DB
both run UTC; `expires_at` comparison uses Carbon `now()` PHP-side via Eloquent.
All composite indexes MUST lead with `organization_id` (D22). The model MUST NOT
carry any global tenant scope so the auth guard can resolve it unscoped. `key_hash`
MUST be in `$hidden` and NOT mass-assignable. `abilities` MUST be cast to `array`.

(Full spec content continues as before — same content as `/Volumes/Scheda SSD/avatar-test/openspec/specs/m2m-auth/spec.md`)

[Note: This file content is identical to what was written to openspec/specs/m2m-auth/spec.md]
