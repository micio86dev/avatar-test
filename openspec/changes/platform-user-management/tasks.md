# Tasks: Managing BEAI's Own People

## Phase 1 — Prove the current failure

- [x] 1.1 RED — a superadmin with no acting client `POST /api/users` today: assert the
      500, so the fix has a before/after and not just an after
- [x] 1.2 GREEN — 409 `organization_context_required`
- [x] 1.3 A superadmin is still invisible to the org-scoped list and read (regression:
      `UserAdminReader`'s invariant must survive this change untouched)

## Phase 2 — `PlatformUserReader`

- [x] 2.1 RED — reaches only `organization_id IS NULL AND is_superadmin = true`; an org
      user's id 404s; a deactivated platform user IS listed
- [x] 2.2 GREEN

## Phase 3 — `PlatformUserGuards`

- [x] 3.1 RED — the last ACTIVE superadmin cannot be deactivated (`last_superadmin`)
- [x] 3.2 RED — self-deactivation of the last one reports `self_deactivation`
- [x] 3.3 RED — with two active, either may stand down
- [x] 3.4 RED — an already-deactivated superadmin does not count toward the survivor
- [x] 3.5 GREEN — transaction + `lockForUpdate`, mirroring `UserGuards`

## Phase 4 — `PlatformUserController` + routes

- [x] 4.1 RED — 403 for an org admin on every one of the five routes
- [x] 4.2 RED — create: `organization_id` null, `is_superadmin` true, no org role, invited
- [x] 4.3 RED — create ignores a crafted `organization_id` / `is_superadmin` in the body
- [x] 4.4 RED — update name/email/password; email uniqueness
- [x] 4.5 RED — deactivate / activate round trip
- [x] 4.6 GREEN — controller, requests, resource, routes
- [x] 4.7 OpenAPI re-export against Postgres (client drift gate)

## Phase 5 — Backoffice

- [x] 5.1 RED — `PlatformUsersPanel`: lists, creates, no role picker, deactivate confirmed
- [x] 5.2 RED — the settings `users` section renders the platform panel ONLY when
      `isSuperadmin && actingClientKnown && actingClientId === null`
- [x] 5.3 RED — an unknown acting client falls back to the ORGANIZATION panel (fails closed)
- [x] 5.4 RED — an org admin always gets the organization panel
- [x] 5.5 GREEN — panel, composable, section resolution
- [x] 5.6 i18n `en`/`it`, no literal strings
- [x] 5.7 The panel names its scope in its heading

## Phase 6 — Gates

- [x] 6.1 `pint`, `phpstan --memory-limit=1G`, `php artisan test --parallel`
- [x] 6.2 `bun run lint`, `typecheck`, `format:check`, `test:unit --coverage`
- [x] 6.3 Arch guards: `form-contract`, `destructive-action`, `cta-authorization`
- [ ] 6.4 E2E: the section switches with the client selection — NOT DONE. It needs a
      superadmin fixture with a live client switch, which no E2E spec sets up today;
      the unit coverage pins the resolution rule and its fail-closed branch.

## Follow-up, NOT in this change

- A lesser BEAI role (clients console without platform settings). It needs a new
  authorization concept — column or role table, ability set, and a decision about what it
  may not do. Nothing specifies it; inventing it here would be scope invention.

## Deviations, recorded

- **D5 was replaced by something better mid-implementation.** The plan added a fourth
  `fetchClients()` reader; the page's existing `noOrganizationInContext` already IS the
  signal, is derived from a response it already makes, and fails closed. design.md D5
  carries the reasoning.
- **One panel and one form with a `variant` prop, not two of each** (design.md D5b) —
  the opposite call from D1's on the API, for a stated reason.
- **Authorization moved into the FormRequest.** A controller-side superadmin check ran
  AFTER validation, so an org admin's POST came back 422 enumerating the field rules
  instead of 403. Caught by the RED tests; the controller still asserts it too, since the
  verbs without a FormRequest have nowhere else to put it.
- **`Feature/PlatformUsers` needed its own `RefreshDatabase` registration.** Without it
  the last-superadmin cases returned 204 and passed for the wrong reason: a superadmin
  left behind by an earlier test is a survivor the guard then declines to fire for.
- **`UserInvitationNotification` gained `role_superadmin` and `intro_platform`.** Reusing
  the existing copy would have told a platform administrator they can change nothing —
  the observer fallback is documented as safe precisely because it only ever understates.

## Verification

- `php artisan test --parallel` — 2946 tests, 2939 passed, 7 skipped, 0 failed.
- `pint --test`, `phpstan --memory-limit=1G` — clean.
- `scramble:export` against Postgres; all four platform paths in `openapi.json`; the
  backoffice snapshot re-synced and `check-client-drift.sh` green on both stages.
- `bun run test:unit` — 143 files, 1410 tests, all green; coverage 94.3% lines (gate 85%).
- `bun run lint`, `typecheck`, `format:check` — clean.
