# Proposal: Operator-Minted Interview Entry Link

## Intent

An operator in the backoffice has no way to start an interview for a candidate. Not a
missing button — a missing capability.

The **only** way to mint a candidate entry token today is
`POST /api/m2m/sso-link` (`api/app/Http/Controllers/M2m/SsoLinkController.php`), behind
`auth:api-m2m` + `ability:sso_link:generate`. That is an API-key surface built for an
external ATS. A backoffice operator holds a human JWT on `auth:api` and no M2M key, and
putting one in a browser would be wrong. Grep for `entry_url`, `inviteLink`, `copyLink`,
`entryUrl` across `backoffice/app` returns **nothing**.

Everything downstream already exists: `GET /api/sso/exchange` is public and swaps the
token for a candidate JWT; `frontend/app/pages/interview/[token].vue` serves the journey;
`frontend/tests/e2e/interview-flow.spec.ts` exercises it. The product can run an
interview. It just cannot start one from its own UI.

**Two verified properties reframe what we are building** and must be designed for, not
discovered:

1. **The token lives 30 minutes.** `CandidateTokenFactory::mintSsoLink` calls
   `setTTL(30)`; `openspec/specs/participant-sso/spec.md:135` fixes it as an invariant.
2. **The token is spent on first exchange — including a *refused* exchange.** The
   exchange consumes the jti *before* evaluating its gates (deliberate replay protection,
   documented at `SsoLinkController.php:99-112`).

So this is **not** an invitation you email on Monday for a Thursday interview. It is a
hand-off-now artifact. The change ships it as exactly that, and says so in the UI.

## Scope

### In Scope

| # | Deliverable |
|---|---|
| 1 | `EntryLinkMinter` support service — the mint logic extracted from `SsoLinkController`, single source of truth for gates, `role_code` inheritance and terminal-status refusal |
| 2 | `POST /api/entry-links` — human-facing mint on `auth:api` + `TenantContext`, authorised by `ParticipantPolicy::create` |
| 3 | `ParticipantPolicy::create` — admin + operator; viewer denied |
| 4 | `config('interview.frontend_url')` + `FRONTEND_URL` env — **does not exist today**, verified absent from `api/config/` |
| 5 | API composes the absolute `entry_url`; response is `{ entry_url, expires_at }` |
| 6 | Backoffice: mint action on participant detail (re-issue) and on the participants list (invite new), with a single-use + expiry disclosure before the copy |
| 7 | Action disabled with a stated reason when the project cannot produce a usable link |
| 8 | `it` + `en` locale keys; OpenAPI snapshot sync across all three copies |

### Out of Scope

- **Emailing the link from the product.** Open question below — evidence says this is a
  larger change than it looks.
- **A longer-lived invitation token.** Changing the 30-minute TTL is a change to the
  security posture of a public, unauthenticated exchange. It is the natural follow-up
  *if* the email path is chosen; it is not this slice.
- **Revoking an unspent link.** There is no mechanism — `consumeJti` runs only at
  exchange, and nothing invalidates a minted-but-unused jti. See Risks.
- **Creating the participant at mint.** The mint writes nothing; the participant row is
  created at exchange. Unchanged.
- **The M2M endpoint's request or response contract.** Byte-identical, snapshot-proven.

## Approach

### D1 — One endpoint, not two: `POST /api/entry-links`

**The mint writes nothing.** `SsoLinkController` only *reads* `Participant` (the
terminal-status gate at `:83-91`); the row is created at exchange. So for a *new*
candidate there is no participant to hang a sub-resource off, and for an *existing* one,
`POST /api/entry-links` carrying their `candidate_ref` is the identical operation. A
`POST /api/participants/{id}/entry-link` sibling would be a second route for the same
call, differing only in where the client read the body from.

Body mirrors the M2M mint exactly: `project_id`, `candidate_ref`, `display_name`,
`role_code?`, `lang?`. The backoffice pre-fills it from the participant row when
re-issuing and from a form when inviting new. Registered in its own
`['auth:api', TenantContext::class]` group, adjacent to the Admin Read API block
(`api/routes/api.php:196`) — a write, so not inside it.

The singular self-resolving precedent (`/organization`, `/profile`) does **not** apply:
those resolve their subject from the token. This one names a project and a candidate.

### D2 — Shared minter, because two mints will diverge

`app/Support/Sso/EntryLinkMinter.php` takes `(Project, candidate_ref, display_name,
role_code?, lang?)` and returns `token` + `expires_at`, or throws a typed
`EntryLinkRefused` carrying the reason (`gates` / `role_code` / `terminal`). Both
controllers become thin: each resolves the project scoped to *its own* org source
(`ApiClient->organization_id` vs. `TenantContext`) — that resolution stays in the
controllers, because it is the one thing genuinely different between them — then calls
the minter and maps the refusal to its own HTTP shape.

Two implementations of a token mint diverge, and one of them is the thing that decides
whether a candidate can start an assessment. The `role_code` inheritance rule at
`:96-117` exists because getting it wrong returns a 201 carrying a token the exchange
will refuse *and spend*. That rule must exist once.

### D3 — The API composes the URL. Position, with reasons.

`{frontend_url}/interview/{token}` for `it`, `{frontend_url}/en/interview/{token}` for
`en` — `frontend/nuxt.config.ts:47-48` sets `defaultLocale: 'it'`,
`strategy: 'prefix_except_default'`.

1. **The locale prefix is a function of `lang`, and only the minter knows `lang`.** It
   is resolved inside the mint (`$validated['lang'] ?? $project->language ?? fallback`)
   and stamped into the token. If the backoffice composes the URL it must either
   re-derive that fallback chain or guess — and a mismatch lands the candidate on the
   wrong-language page or a 404.
2. **The backoffice does not know the candidate app's origin.** Its
   `runtimeConfig.public` holds `apiBase`, `gaMeasurementId`, `clarityProjectId` — no
   frontend origin. Adding one there puts a second per-deployment origin in a second
   service, set by a different deploy, validated by nobody.
3. **Repo precedent.** `EvaluationPayloadAssembler` roots outbound file URLs at
   `config('app.url')` rather than the request host, for this exact reason: an absolute
   URL leaving the system is composed from configuration, never from the caller.

**`FRONTEND_URL` does not exist in `api/config/` today.** It must be added, and it must
**fail loud when unset** — never fall back to `config('app.url')`, which is the *API's*
origin and would produce a link that 404s in production while looking fine in a
single-host dev setup. That is precisely the failure this decision exists to prevent.

The response returns `entry_url` and `expires_at`, not the bare token: a raw token in an
operator-facing payload is a second copyable artifact that goes in the wrong place.

### D4 — Who may mint

`ParticipantPolicy::create(User $user): bool` → `admin || operator`, mirroring
`ProjectPolicy::create` (`:44-49`) verbatim. `ParticipantPolicy` currently carries only
`viewAny`/`view`, both open to all three roles.

**Viewer is denied.** A viewer who can mint an entry link can start an assessment, and
starting an assessment is not a read.

### D5 — Single use, surfaced before it bites

An operator who copies the link, opens it to check it works, then sends it to the
candidate has burned it. All three, not one:

- The copy affordance states **single use** and the expiry **before** the copy, not in a
  toast after it.
- `expires_at` rendered through the existing date-render convention
  (`date-render.spec.ts`).
- A **Generate new link** action, worded as generating a *new* link — never "revoke" or
  "regenerate", because nothing invalidates the previous one.

### D6 — Never offer an action guaranteed to fail

`projectIsAccessible()` requires `status === 'active'`, `goes_live_at <= now()`,
`deadline_at > now()`. A draft, not-yet-live or expired project **cannot** produce a
usable link. The action renders disabled with the specific reason. If the current
backoffice payloads do not carry those three fields, adding them is in scope.

The API still returns 403 regardless — a disabled button is not authorization.

## Capabilities

### New Capabilities

None. Deliberately: the single-use, jti-consume and entry-gate invariants must stay in
**one** document. A separate `operator-entry-link` spec would be a second place to state
them and a second place for them to drift.

### Modified Capabilities

- `participant-sso`: new operator-facing mint requirement on `auth:api` +
  `TenantContext`; shared minter as the single source of the gate/`role_code` rules;
  `entry_url` composition, locale prefixing, and the `FRONTEND_URL` fail-loud
  requirement. Existing M2M mint and exchange requirements unchanged.
- `admin-backoffice`: new operator surface — mint action, single-use/expiry disclosure,
  disabled-with-reason states, `ParticipantPolicy::create` RBAC row.

## Affected Areas

| Area | Impact | Description |
|---|---|---|
| `api/app/Support/Sso/EntryLinkMinter.php` | New | Shared mint; typed refusals |
| `api/app/Http/Controllers/EntryLinkController.php` | New | `auth:api` mint; composes `entry_url` |
| `api/app/Http/Controllers/M2m/SsoLinkController.php` | Modified | Delegates to minter; response byte-identical |
| `api/app/Policies/ParticipantPolicy.php` | Modified | `create` — admin/operator |
| `api/config/interview.php`, `.env.example` | New/Modified | `FRONTEND_URL`, no fallback |
| `api/routes/api.php` | Modified | `POST /entry-links` |
| `backoffice/app/pages/participants/{index,[id]}.vue` | Modified | Mint action + disclosure |
| `backoffice/app/composables/useParticipants.ts` | Modified | Mint call |
| `backoffice/i18n/locales/{it,en}.json` | Modified | Both mandatory; no bare literals |
| `{api,frontend,backoffice}/openapi.json` | Modified | Move together |

## Risks

| Risk | Likelihood | Mitigation |
|---|---|---|
| 30-minute TTL makes the feature feel broken — operator mints, emails, candidate opens it tomorrow | **High** | Framed and worded as a hand-off-now link, expiry stated before the copy; a longer-lived invitation is an explicit, separate decision |
| Operator tests the link and burns it | **High** | D5 — disclosure before copy, plus a new-link action |
| `FRONTEND_URL` unset in production → link 404s while dev works | **High** | Fail loud; no `app.url` fallback; smoke-check the composed URL post-deploy |
| Unspent links cannot be revoked; a superseded link stays valid for its remaining TTL | Med | Accepted — 30-minute blast radius, single use. UI never claims otherwise |
| Refactor changes M2M behaviour | Med | OpenAPI snapshot + existing C6 feature tests unchanged; response asserted byte-identical |
| Locale prefix wrong → wrong-language interview | Med | Composition owned by the minter, which owns `lang`; covered for both `it` and `en` |
| Backoffice arch guards fail the new form/action | Med | `form-contract.spec.ts`, `destructive-action.spec.ts`, `date-render.spec.ts` all apply from the first commit |

## Rollback Plan

Route-level and cleanly separable. Remove the `POST /entry-links` route and the
backoffice action; the M2M surface and the exchange are untouched by that revert.

**The minter extraction reverts separately and must be reverted second**, or first if it
alone is at fault — `SsoLinkController` returning to its inline implementation restores
C6 exactly, and its tests are the proof. No migrations, no data. `FRONTEND_URL` becomes
inert, not harmful.

## Dependencies

- `FRONTEND_URL` set per environment before the feature is enabled anywhere.
- `task openapi:sync` requires `DB_CONNECTION=pgsql`.
- Tests run as `./vendor/bin/pest <exact-file>` or full runs — **never**
  `php artisan test --filter`, which was observed fabricating passes in this repo.
  Playwright runs `--workers=1`.

## Success Criteria

- [ ] An operator mints a working interview link from the backoffice with no M2M key.
- [ ] Viewer receives 403; admin and operator succeed.
- [ ] Cross-org `project_id` returns 404, matching M2M behaviour.
- [ ] `entry_url` is absolute, correctly locale-prefixed for both `it` and `en`, and opens `interview/[token].vue`.
- [ ] Unset `FRONTEND_URL` fails loudly; it never silently composes from `config('app.url')`.
- [ ] Draft / not-yet-live / expired project: action disabled with a stated reason, **and** the API returns 403.
- [ ] Operator sees "single use" and the expiry before copying.
- [ ] The M2M `POST /api/m2m/sso-link` response is byte-identical and its C6 tests pass unchanged.
- [ ] `it` and `en` complete; no bare literals; three arch guards green.
- [ ] Three OpenAPI snapshots in sync.

## Proposal Question Round

Not asked interactively (delegated execution). **Recorded for the spec phase — not
decided here.**

1. **Should the product email the link, or is copy-to-clipboard the whole feature?**
   The "a mail path partly exists" reading is weaker than it looks, and three findings
   say so:
   - **`Participant` has no email column.** `$fillable` is `project_id`, `candidate_ref`,
     `display_name`, `role_code`, `language`, `status`. The product holds no candidate
     address anywhere. Emailing means a new field, plus a GDPR question about storing it.
   - **`SendOperatorNotificationJob` is operator-alerting plumbing, not candidate mail.**
     `NotificationType` has exactly two values — `WebhookDeliveryDead` and
     `ScoringFailed` — and recipients come from
     `OperatorRecipientResolver::forOrganization`, i.e. internal users only. Nothing
     addresses a candidate.
   - **`notification_logs` dedupes on `(type, subject_type, subject_id)`**, one
     notification per subject. A re-issuable invite violates that shape directly.
   - **And the 30-minute TTL makes an emailed link mostly dead on arrival**, so choosing
     "yes" almost certainly drags the TTL decision in with it.

   Assumed **out of scope** for this slice on that evidence. Confirm, or open it as its
   own change with the TTL question attached.

2. **Where should the "invite a new candidate" entry point live** — participants list, or
   project detail? This proposal assumes the participants list, since that is where an
   operator already goes to look for a candidate. The mint payload needs `project_id`
   either way, so from the project page it is pre-filled and from the list it is chosen.
   Cheap to move; worth confirming before the UI is built.
