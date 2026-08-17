# Design: Operator-Minted Interview Entry Link

## Technical Approach

Extract the mint from `SsoLinkController::store` into `App\Support\Sso\EntryLinkMinter`, add a
human-facing `POST /api/entry-links` on `auth:api` + `TenantContext` that composes the absolute
candidate-app URL, and surface it in the backoffice from two places: re-issue on participant
detail, create-and-invite from a project row. The M2M endpoint keeps its exact request body,
response bodies and exported schema.

---

## Architecture Decisions

### D1 — Extraction boundary: what moves, what stays

`EntryLinkMinter::mint(Project $project, string $candidateRef, string $displayName, ?string $roleCode, ?string $lang): MintedEntryLink`

| Moves into the minter | Stays per-caller |
|---|---|
| entry gates (`projectIsAccessible`) | `$request->validate([...])`, **inline and verbatim** |
| `role_code` validation (potential/standard) | project resolution + org source |
| `role_code` inheritance rule (`SsoLinkController.php:96-117`) | HTTP mapping of the refusal |
| `lang` resolution chain | the literal `response()->json([...], 201)` |
| terminal-status mint gate | |
| `CandidateTokenFactory::mintSsoLink` + `expires_at` | |

**Validation stays inline because Scramble infers the request body from that exact call site**
(`openapi.json:3320-3358` derives `maxLength`/`required` from it). A FormRequest or a minter-side
rule array rewrites the `/m2m/sso-link` `requestBody` node. Same for responses: Scramble derives
`"const": "Access denied."` and `"const": "Conflict: participant has already completed this
assessment."` from the literal arrays at `:70` and `:88-90`. Both controllers therefore catch
`EntryLinkRefused` and rebuild their own literal responses — the refusal carries a reason enum
(`gates` | `role_code` | `terminal`) plus, for `role_code`, the message string.

**The minter takes a `Project`, not a `project_id`.** The org source is the one genuine difference
between callers (`ApiClient->organization_id` vs. the `TenantScoped` global scope stamped by
`TenantContext`). A minter that accepted an id would have to be told which org to scope by — putting
the tenant filter inside a shared component with two callers, which is exactly where a wrong default
becomes a cross-tenant read. An already-resolved model makes the scoping unavoidably the caller's,
and makes the minter unit-testable with no HTTP.

**Byte-identity is proven, not asserted**, by three mechanical checks:
1. `api/tests/Feature/C6/SsoLinkMintTest.php` (18 cases) runs with **zero edits**. Editing it during
   apply invalidates the proof.
2. New `api/tests/Feature/C6/SsoLinkResponseGoldenTest.php` — `assertExactJson` + status on the
   201/403/409/422/404 paths, written and **green against the current controller before** the
   extraction starts.
3. `task openapi:sync` (`DB_CONNECTION=pgsql`), then `git diff api/openapi.json`: the
   `/m2m/sso-link` node must be untouched; the only change is an added `/entry-links` node.

`CandidateTokenFactory` gains `public const SSO_LINK_TTL_MINUTES = 30;` used by `setTTL()` — so the
minter derives `expires_at` from the same constant the token does, and a test asserts the decoded
`exp` claim equals the returned `expires_at`.

### D2 — Authorisation: new ability on `ParticipantPolicy`

`ParticipantPolicy::create(User $user): bool => admin || operator`. Viewer denied: minting starts an
assessment, and starting one is not a read.

| Option | Verdict |
|---|---|
| Reuse `ProjectPolicy::create` | **Rejected.** "May create projects" would gate "may start an interview"; the day the two diverge, who can start an assessment changes silently. |
| New `EntryLinkPolicy` | **Rejected.** No `EntryLink` model to bind, and `authorize()` needs a class. |
| `Gate::define('mintEntryLink')` | **Rejected.** Every RBAC rule here is a policy; `Gate::policy(Participant::class, ParticipantPolicy::class)` is already registered (`AppServiceProvider.php:79`) — no wiring change. |

**Failure order: `authorize('create', Participant::class)` runs first, before project resolution**
(403 before 404). This is not a deviation from `AdminParticipantReader`'s documented 404→403→409
order: that reader loads first because its `view($participant)` check needs the row. `create` takes
no model, so nothing needs loading, and a role check that runs first cannot leak cross-org
existence.

### D3 — `config('interview.candidate_app_url')`, fail-loud at mint time

Declared in the **existing** `api/config/interview.php` as `'candidate_app_url' => env('CANDIDATE_APP_URL')` —
no default, no `?: config('app.url')`. Docblock states it is the **candidate app** origin
(`frontend/`), not the backoffice.

`App\Support\Sso\EntryLinkUrlComposer` throws `App\Exceptions\Sso\EntryLinkUrlNotConfigured`
(a `RuntimeException`) when the value is null, empty, or not an absolute http(s) URL. Registered in
`bootstrap/app.php` to render `500 {"message":"Entry link URL is not configured."}` — **not**
suppressed from Sentry; being noisy is the point.

| Rejected mechanism | Why |
|---|---|
| Throw in `AppServiceProvider::boot()` | One unset feature var takes down login, `/health` and every unrelated endpoint. On the first Railway deploy after this change — where the var has never existed — a missing feature becomes a total outage. |
| Throw inside `config/interview.php` | Same blast radius, plus it breaks `config:cache`, `migrate` and every artisan command, so the deploy itself cannot complete. |

`CANDIDATE_APP_URL=http://localhost:3000` is added to `api/.env.example` (dev works from a fresh
checkout). That is not a code fallback: production Railway does not read `.env.example`, so the
first deploy breaks **this feature only, loudly**, until the var is set on the `api` service. Setting
it is a release dependency of the backoffice slice, and a post-deploy smoke mint is the acceptance
step.

**URL composition** (config-driven: `frontend_default_locale => 'it'`, `frontend_locales => ['it','en']`):

```
origin = rtrim(config('interview.candidate_app_url'), '/')
lang === 'it'                    → {origin}/interview/{token}
lang ∈ frontend_locales, non-default → {origin}/{lang}/interview/{token}
lang ∉ frontend_locales           → {origin}/interview/{token}   + Log::warning
```

The unsupported-locale fallback is unprefixed, not a 422. Three reasons: `/es/interview/...` is a
hard 404 (`nuxt.config.ts:51-54` serves only `it`/`en`); the camera/microphone `Permissions-Policy`
is declared for exactly `/interview/**` and `/en/interview/**` (`nuxt.config.ts:25-40`), so an
unlisted prefix loads the page and then cannot start the interview; and the interview's content
language comes from the token's `lang` claim, not the path — the fallback degrades chrome only.
A 422 would refuse a legitimately configured project, and pushing that rule into the shared minter
would change M2M behaviour.

### D4 — What the operator sees

One shared organism, `EntryLinkPanel.vue`, rendered by both surfaces — a security disclosure
duplicated is a security disclosure that drifts. DOM order is load-bearing:

```
[ Alert variant="destructive" ] single-use sentence + "testing it yourself spends it"
[ expiry line ]   <FormattedDate :value="link.expires_at" :locale="locale" show-zone />
[ <p class="bg-muted font-mono break-all"> ]  the URL, always selectable text
[ Copy ]  [ Generate new link ]
```

The warning renders **above** the URL and **before** the copy control. A toast after the copy is too
late by construction. Precedent: the raw-API-key reveal (`ApiKeysPanel.vue:169-198`) is exactly this
shape. `show-zone` gives the expiry in absolute terms with a locale-aware zone abbreviation; the
attribute binding satisfies `date-render.spec.ts` R1 by construction (mustache interpolation of
`expires_at` would fail it).

Wording is **"Generate new link"**, never "revoke"/"regenerate" — nothing invalidates the previous
token, and the UI must not imply otherwise.

**Surface A — re-issue:** a new `Card` in `pages/participants/[id].vue`, after the timeline card.
Payload pre-filled from the participant row (`project_id`, `candidate_ref`, `display_name`,
`role_code`, `language`), all already on `ParticipantDetailResource`.

**Surface B — create-and-invite:** a per-row "Invite candidate" button in `ProjectTable.vue`,
opening a `Dialog` with `EntryLinkForm.vue` (`candidate_ref` + `display_name`); on success the
dialog body swaps to `EntryLinkPanel`. Hanging this off the **project** (not the participants list,
as the proposal assumed) is what makes `project_id` known rather than a third field the operator has
to pick.

Form contract, from the first commit: `<form novalidate>`, `Field`/`FieldLabel`/`FieldError` from
`@/components/ui/field`, per-field `aria-invalid` + `aria-describedby`, JS validation before submit
(both required, `max:255`), and `applyServerFieldErrors(error, { candidate_ref: 'candidateRef',
display_name: 'displayName' }, assign)` with unmapped messages (`project_id`, `role_code`, `lang`)
surfacing in the form-level `role="alert"` banner.

**No `ConfirmDialog`.** `generateEntryLink(` does not match `destructive-action.spec.ts`'s
`DESTRUCTIVE_CALL_REGEX` and must not be added to its allowlist: the mint writes nothing and
invalidates nothing. A confirm modal on a non-destructive action trains dismissal, and the actual
hazard — opening the link — happens after the copy, where the inline disclosure already sits.

### D5 — Unusable project: disabled with a stated reason

Follows the existing precedent verbatim (`ProjectForm.vue:363` — "an operator sees a disabled
control with a reason instead of an unexplained 422"; the same treatment BARS-uncovered
competencies get). Hidden is worse: the operator concludes the capability does not exist and files
the bug this change exists to close. A bare disabled control is a second defect, so the reason is
always rendered inline, in one of three distinct strings: `notActive`, `notYetLive` (with the
`goes_live_at` date through `FormattedDate`), `expired`.

The predicate is a pure `backoffice/app/utils/project-accessibility.ts` mirroring
`projectIsAccessible()` exactly, unit-tested against the same three gates.

Data source:
- **Project surface:** `ProjectResource` already carries `status`, `goes_live_at`, `deadline_at`
  (`ProjectResource.php:54,72-73`) — verified; **no API change needed**, contrary to the proposal's
  contingency.
- **Participant surface:** `ParticipantDetailResource` carries `project_id` but none of the gate
  fields. Add nested `project: { id, name, status, goes_live_at, deadline_at }`. Rejected: a second
  org-wide `GET /projects` from a detail page, and enabling the button blindly to explain the 403
  afterwards (that is precisely the "action guaranteed to fail" this decision forbids).

The API still returns 403 on every gate regardless. A disabled button is not authorization.

**Scramble:** `ParticipantDetailResource` already carries an explicit `@scramble-return`
(`:45`) — the local-assignment defect is fixed there, as it is in `ProjectResource`. The obligation
is that the new `project` key be added to **both** the `@return` and the `@scramble-return` shapes in
lockstep, plus a runtime assertion in `tests/Feature/Api/ResourceContractTruthTest.php`, or the
exported schema lies. No other resource in this change is affected: `/entry-links` returns a literal
`response()->json()` and is inferred from the literal, exactly as `/m2m/sso-link` is today.

### D6 — Clipboard: the failure is designed out, not handled

`navigator.clipboard.writeText` in a try/catch (`ApiKeysPanel.vue:379-388`). The URL is **always**
rendered as selectable text before the Copy button exists, so a denied or unavailable clipboard
degrades to manual selection with nothing lost.

Two additions over the ApiKeysPanel precedent: the catch is not silent — it sets `copyFailed` and
renders an inline hint ("Copy was blocked — select the link above and copy it manually"); and
`navigator.clipboard === undefined` (insecure context, an `http://` staging host) renders the button
disabled with that same hint rather than throwing on click.

Rejected: a `document.execCommand('copy')` fallback — deprecated, requires a hidden-textarea
selection dance, and silently no-ops in several browsers. A fallback that fails silently is worse
than none.

---

## Data Flow

```
Backoffice                    API                                     Candidate app
──────────                    ───                                     ─────────────
[Invite candidate]
   │ POST /api/entry-links  (Bearer human JWT)
   ▼
        auth:api ──► TenantContext (stamps TenantResolver / TenantScoped)
           │
           ▼ authorize('create', Participant::class)   ── viewer ──► 403
           │
           ▼ Project::findOrFail($id)   (org-scoped by TenantScoped)  ── cross-org ──► 404
           │
           ▼ EntryLinkMinter::mint(Project, ...)
               ├─ gates ─────────► EntryLinkRefused(gates)     ──► 403
               ├─ role_code ─────► EntryLinkRefused(role_code) ──► 422
               ├─ terminal ──────► EntryLinkRefused(terminal)  ──► 409
               └─ CandidateTokenFactory::mintSsoLink  (TTL 30m, no Redis write)
           │
           ▼ EntryLinkUrlComposer::compose(token, lang)
               └─ candidate_app_url unset ──► EntryLinkUrlNotConfigured ──► 500
           │
           ▼ 201 { entry_url, expires_at }
   │
   ▼ EntryLinkPanel: disclosure ▸ URL ▸ Copy
   │
   └────────── operator hands the URL over ──────────────────────►  GET /{lang?}/interview/{token}
                                                                       │
                                                                       ▼ GET /api/sso/exchange
                                                                         (consumes jti — unchanged)
```

The same minter serves `POST /api/m2m/sso-link`, which resolves its project via
`Project::where('organization_id', $client->organization_id)->findOrFail(...)` — kept verbatim — and
returns `{ token }`, never a URL.

---

## File Changes

| File | Action | Description |
|---|---|---|
| `api/app/Support/Sso/EntryLinkMinter.php` | Create | Shared mint; takes `Project`; returns `MintedEntryLink{token, expires_at, lang}` |
| `api/app/Support/Sso/MintedEntryLink.php` | Create | Readonly DTO |
| `api/app/Support/Sso/EntryLinkUrlComposer.php` | Create | Origin + locale-prefix composition; fail-loud |
| `api/app/Exceptions/Sso/EntryLinkRefused.php` | Create | Typed refusal: `gates` \| `role_code` \| `terminal` |
| `api/app/Exceptions/Sso/EntryLinkUrlNotConfigured.php` | Create | Misconfiguration; 500, Sentry-visible |
| `api/app/Http/Controllers/Api/EntryLinkController.php` | Create | `auth:api` mint; authorize → resolve → mint → compose |
| `api/app/Http/Controllers/M2m/SsoLinkController.php` | Modify | Delegates; validation + response literals unchanged |
| `api/app/Support/Jwt/CandidateTokenFactory.php` | Modify | `SSO_LINK_TTL_MINUTES = 30` constant, used by `setTTL()` |
| `api/app/Policies/ParticipantPolicy.php` | Modify | `create` — admin/operator |
| `api/app/Http/Resources/Admin/ParticipantDetailResource.php` | Modify | Nested `project` gate fields; both docblocks |
| `api/config/interview.php` | Modify | `candidate_app_url`, `frontend_default_locale`, `frontend_locales` |
| `api/.env.example`, `api/routes/api.php`, `api/bootstrap/app.php` | Modify | Env sample; route group; exception render |
| `backoffice/app/composables/useEntryLinks.ts` | Create | `generateEntryLink(payload)` |
| `backoffice/app/components/organisms/EntryLinkPanel.vue` | Create | Disclosure ▸ URL ▸ Copy; shared by both surfaces |
| `backoffice/app/components/organisms/EntryLinkForm.vue` | Create | `candidate_ref` + `display_name`, full form contract |
| `backoffice/app/utils/project-accessibility.ts` | Create | Pure gate predicate + reason |
| `backoffice/app/pages/participants/[id].vue` | Modify | Re-issue card |
| `backoffice/app/components/organisms/ProjectTable.vue`, `pages/projects/index.vue` | Modify | Row action + dialog |
| `backoffice/i18n/locales/{it,en}.json` | Modify | Both mandatory; no bare literals |
| `{api,frontend,backoffice}/openapi.json`, `backoffice/types/api.ts` | Modify | Move together |

---

## Interfaces / Contracts

```php
// POST /api/entry-links  — auth:api + TenantContext
// body: { project_id: int, candidate_ref: string, display_name: string, role_code?: ?string, lang?: ?string }
// 201:  { "entry_url": "https://app.example.com/en/interview/<jwt>",
//         "expires_at": "2026-08-17T15:32:00.000000Z" }
// 403 policy | 403 gates | 404 cross-org | 409 terminal | 422 role_code | 500 misconfigured
```

`entry_url` is absolute and locale-prefixed. The raw token is never returned to an operator — a
second copyable artifact is a second thing that ends up in the wrong place.

---

## Testing Strategy

`strict_tdd: true`. Runners: `./vendor/bin/pest <exact-file>` or a full `./vendor/bin/pest` run —
**never** `php artisan test --filter`, observed fabricating passes in this repo. Playwright
`--workers=1`. OpenAPI sync needs `DB_CONNECTION=pgsql`.

| Proves | Test |
|---|---|
| M2M behaviour unchanged | `tests/Feature/C6/SsoLinkMintTest.php` — 18 cases, **zero edits** |
| M2M wire shape unchanged | `tests/Feature/C6/SsoLinkResponseGoldenTest.php` — `assertExactJson` on 201/403/409/422/404; green before the extraction |
| M2M schema unchanged | `git diff api/openapi.json` after sync: `/m2m/sso-link` node untouched |
| Viewer refused | `tests/Feature/EntryLink/EntryLinkPolicyTest.php` — viewer 403, operator 201, admin 201, cross-org 404, no token 401 |
| Locale prefix correct | `tests/Unit/Sso/EntryLinkUrlComposerTest.php` (it → unprefixed, en → `/en`, `es` → unprefixed, trailing slash normalised) + a feature test on a `language=en` project |
| Fail-loud config | Same unit file with `candidate_app_url => null` → `EntryLinkUrlNotConfigured`; and an explicit assertion that the output never derives from `config('app.url')` when `app.url` is set and `candidate_app_url` is not |
| `expires_at` truthful | `tests/Unit/Sso/EntryLinkMinterTest.php` — decoded `exp` claim === returned `expires_at` |
| Minter refusals | `EntryLinkMinterTest` — gates / role_code / terminal as typed reasons, `Project` model in |
| Resource contract | `tests/Feature/Api/ResourceContractTruthTest.php` — runtime shape of the new `project` key |
| Arch guards | `bun run test:unit` — `form-contract`, `date-render`, `destructive-action` green from the first backoffice commit |
| Disabled reason | `tests/unit/utils/project-accessibility.spec.ts` + a component test asserting the control is disabled **and** a reason node is present |
| Clipboard fallback | Component test: `writeText` rejects → hint rendered, URL still selectable; `navigator.clipboard` undefined → button disabled with the hint |
| End to end | `backoffice/tests/e2e/entry-link.spec.ts` — mint from a project row, disclosure visible before copy (`--workers=1`) |

### RED-first order of work — API before frontend

| # | Step | Slice |
|---|---|---|
| 1 | Golden M2M wire test against the **current** controller (regression net, green from the start) | 1 |
| 2 | RED: `EntryLinkMinterTest`, `EntryLinkUrlComposerTest`, fail-loud test | 1 |
| 3 | GREEN: config keys, composer, minter, DTO, both exceptions, TTL constant | 1 |
| 4 | REFACTOR: `SsoLinkController` delegates; re-run 1 + `SsoLinkMintTest` unedited | 1 |
| 5 | RED: `EntryLinkPolicyTest` + endpoint feature tests | 2 |
| 6 | GREEN: `ParticipantPolicy::create`, `EntryLinkController`, route, exception render | 2 |
| 7 | `ParticipantDetailResource.project` + both docblocks + contract-truth test | 2 |
| 8 | `task openapi:sync`, three snapshots, regenerate `backoffice/types/api.ts` | 2 |
| 9 | RED: accessibility predicate, panel disclosure order, clipboard failure, form contract | 3 |
| 10 | GREEN: `useEntryLinks`, `EntryLinkPanel`, `EntryLinkForm`, page wiring, `it` + `en` | 3 |
| 11 | E2E | 3 |

Slice 1 ships with no new surface and reverts alone — matching the rollback plan's "the minter
extraction reverts separately and must be reverted second".

---

## Migration / Rollout

No migrations, no data. One deployment dependency: `CANDIDATE_APP_URL` must be set on the Railway `api`
service. With this change delivered as a single branch (no PR chaining), the slice-boundary framing
above is moot — `CANDIDATE_APP_URL` is already set on the Railway `api` service in production
(`https://frontend-production-5cb6.up.railway.app`, verified serving the candidate app and answering
200 on `/interview/x`), so Phase 0 of the deployment gate is satisfied before this apply begins.

## Open Questions

- [x] Env var name: **Decided — `CANDIDATE_APP_URL`.** The proposal's original `FRONTEND_URL` was kept
      for continuity with the spec being written in parallel, but on a Railway `api` service with three
      deployed apps, `FRONTEND_URL` is ambiguous enough to invite pasting the backoffice origin — which
      yields a plausible-looking link that 404s. `CANDIDATE_APP_URL` cannot be misread. Renamed across
      this design, both spec deltas, `api/config/interview.php`, and `api/.env.example` before the
      first environment set it.
- [ ] Proposal open question #1 (email the link) remains out of scope, unchanged by this design.
