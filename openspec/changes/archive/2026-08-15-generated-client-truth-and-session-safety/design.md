# Design: Generated-Client Truth and Session Safety

## Technical Approach

Five independent deliverables held together by one rule: **a published contract must be
true at runtime, and CI must be able to prove it.** The ten resources get
`@scramble-return` — but annotations alone would only move the lie from the generator to
the docblock, so every integer field is *also* backed by an explicit `(int)` cast at the
resource, the same discipline `ApiClientResource`'s `array_values()` already uses to back
`list<string>`. The regeneration gate then makes the committed snapshot un-stale-able. The
remaining four (admin revocation, per-knob config errors, the API-key list, test noise) are
local and independent.

Multi-tenancy: **no query in this change takes an id from a request.** The ten resources
serialize already-scoped models; `UserController::update` reaches its target exclusively
through `UserAdminReader::read()` (org filter + `is_superadmin = false`); the API-key list
keeps its explicit `where('organization_id', $user->organization_id)` — `api_clients` is not
a `TenantModel`, so that filter is the only scope and it stays.

---

## D1 — The `@scramble-return` shape for ten resources

### The annotation form (from the two precedents)

`ApiClientResource:43-45` and `AvatarTemplateResource:33-35` both carry **two tags**:
`@return` for PHPStan/IDE and `@scramble-return` with byte-identical content for the
generator. `ApiClientResource`'s docblock records that a plain `@return` alone does **not**
change `scramble:export`'s output — verified empirically. Keep both, keep the
`/** @var X $y */` local assignment (it is what PHPStan reads), keep `@mixin`.

### The `(int)` cast — the decision that makes the annotation true

| Option | Tradeoff | Verdict |
|---|---|---|
| Annotate `id: int`, trust the driver | `Project.php:86-88` records in this repo's own words that **pdo_pgsql returns bigint as string**, which is why `framework_version_id` carries an explicit `'integer'` cast. If that is still true on PHP 8.5, `id: int` is a *new* lie pointing the other way, and a client comparing `id === 1` breaks in production while every test stays green | **Rejected** |
| Annotate `id: int` **and** write `(int) $model->id` | One token per field. The contract is backed by code, not by a PDO detail nobody should have to know. `is_int($json['data']['id'])` becomes a meaningful RED assertion | **Chosen** |

Applies to every `id`, foreign key, `position`, `session_count`, `pause_every_n_competencies`,
`nudge_min_chars` and `competency_count` in the ten. Nullable integers use
`$x === null ? null : (int) $x`, never `(int) $x` (which would turn `null` into `0`).

### Enum-like strings: union or plain string

The rule: **emit a union only where the value set is closed by CODE in this repository and
a change to that set cannot compile without also changing this annotation.** Everywhere else
emit a plain string, because a wrong union is worse than a loose one — a client narrowing a
`switch` on a stale union silently drops a new value instead of rendering it.

| Field | Verdict | Why |
|---|---|---|
| `Participant.status` | **Union** `'in_attesa'\|'in_corso'\|'in_valutazione'\|'completato'\|'errore'` | `Participant::$allowedTransitions` (`Participant.php:110-116`) is a private static map and the `updating` guard **throws** on anything outside it. Adding a state means editing that map; the CI gate then forces this annotation to move with it. Already mirrored client-side in `PARTICIPANT_STATUSES` |
| `Project.status` | **Union** `'draft'\|'active'\|'archived'` | Model lifecycle guard (`Project.php:147-150`) allows exactly `draft→active` and `active→archived` and throws otherwise |
| `Project.assessment_type` (and the nested one in `ParticipantResource.project`) | **Union** `'standard'\|'potential'` | Validated at the FormRequest, immutable once active, documented on the model |
| `Admin/UserResource.role` | **Union** `'admin'\|'operator'\|'viewer'\|null` | `Rule::in(OrgRole::values())` — a PHP **enum**, and `StoreUserRequest`'s docblock records the deliberate refusal to make the set data (`Rule::exists` was rejected). `assignRole()` resolves via `firstOrFail()`, so an unlisted role cannot be assigned. `null` because `getRoleNames()->first()` returns null for a role-less user |
| `role_code` (Participant, Project, nested project) | **Plain `string\|null`** | Looks closed (`ICO/FLL/MLL/BUL/SRX`) and is not. The set lives in `framework_roles`, seeded from `docs/app_description/02-domain/framework/roles.json` — **data owned by the wrapper superproject**. No DB enum, no model guard, no `in:` rule on the column. A sixth role is a data change in another repository, and this annotation would not even be recompiled |
| `language` | **Plain `string`** (`string\|null` on Participant) | `config('app.supported_locales')` — configuration, not code. Same argument |
| `Competency.type` | **Plain `string`** | Documented `standard\|potential`, but there is **no enforcement point at all**: no `in:` rule, no model guard, no DB check, cast is `'string'`. A union here would be an assertion the code cannot keep |

### Translatable fields — a correction to the direction

**They are strings, not JSON objects.** Three independent pieces of evidence:

1. `HasTranslations::getAttributeValue()`
   (`vendor/spatie/laravel-translatable/src/HasTranslations.php:42-49`) intercepts every
   property read and returns `getTranslation($key, $locale)` — a scalar. The `array` cast
   that `initializeHasTranslations()` merges in (`:21-26`) is what Scramble *reads*, and it
   is exactly why the current client says `unknown[]`; it is bypassed for property reads.
   The map is only produced by `mutateAttributeForArray()` (`:51-60`), which runs on
   `$model->toArray()` — and **none of these resources call `toArray()` on the model**; all
   four are explicit whitelists built from `$model->name` property fetches.
2. The models say so: `Competency.php:22-23`, `Role.php:20-21`, `BarsIndicator.php:30-33` all
   declare `@property string $name (resolved via current locale)`.
3. The backoffice already carries a written diagnosis of exactly this:
   `ProjectForm.vue:566-573` wraps `competency.name` in `String()` with the comment
   *"Scramble types `CompetencyResource.name` as `unknown[]` … `FrameworkController` already
   resolves it to a single localized string server-side."*

So `name`, `definition`, `responsibilities`, `text`, `anchor_5/3/1` are **`string`**, and
`String(competency.name)` is deleted as part of this change. This position is contested, so
it is made falsifiable in the first RED task: `expect($json['data'][0]['name'])->toBeString()`.
If that goes red, this decision is wrong and the union/object question reopens before a line
of annotation is written.

### The ten shapes

`created_at`/`updated_at`/`*_at` are **`string|null`** everywhere, including where the Carbon
object is non-nullable — `Carbon::toISOString(): ?string` is itself nullable and PHPStan
level 8 rejects a non-nullable claim. This is the `ApiClientResource:62-69` precedent,
already argued there; do not re-litigate it per resource.

| Resource | Corrected fields (only those whose type or nullability changes, or that must be pinned) |
|---|---|
| `Admin/OrganizationResource` | `id: int`; `default_webhook_url: string\|null` (nullable `string(2048)`); `default_webhook_events: list<string>\|null` (nullable `jsonb`, `'array'` cast, `Organization.php:47`); `has_default_webhook_secret: bool`; timestamps `string\|null` |
| `Admin/UserResource` | `id: int`; `role: 'admin'\|'operator'\|'viewer'\|null`; `is_deactivated: bool` |
| `Admin/ParticipantResource` | `id: int`; `project_id: int`; `role_code: string\|null`; `language: string\|null`; `status: <union>`; `candidate_ref`/`display_name`: `string` (NOT NULL) |
| `Admin/ParticipantDetailResource` | as above, plus `timeline: array{started_at: string\|null, completed_at: string\|null, session_count: int}` and `files: array{transcript: array{type: 'text/plain', ref: 'transcript', url: string}, evaluation_raw: array{type: 'application/json', ref: 'evaluation', url: string}}` |
| `ParticipantResource` (candidate) | as `Admin/ParticipantResource`, plus `project: array{id: int, role_code: string\|null, language: string, assessment_type: 'standard'\|'potential', exit_redirect_url: string\|null, error_redirect_url: string\|null}\|null` |
| `ProjectResource` | `id`/`organization_id`/`framework_version_id`: `int`; `assessment_type`/`status`: unions; `role_code: string\|null`; `language: string`; `pause_every_n_competencies: int\|null`; `nudge_min_chars: int\|null`; `exit_redirect_url`/`webhook_url`: `string\|null`; `webhook_events: list<string>` (`jsonb` NOT NULL, default `["progress","evaluation"]`); `has_webhook_secret: bool`; `pin_context: array{id: int, version: string, label: string\|null, is_locked: bool}\|null`; `competencies: list<array{id: int, code: string, type: string, position: int}>` with `(int)` on the pivot value |
| `FrameworkVersionResource` | `id`/`organization_id`: `int`; `version: string`; `label: string\|null`; `is_locked: bool` |
| `CompetencyResource` | `id: int`; **`name: string`**; **`definition: string`**; `type: string`; `bars_available: bool` |
| `BarsIndicatorResource` | `position: int`; **`text`/`anchor_5`/`anchor_3`/`anchor_1`: `string`**; `translation_gap: bool` |
| `RoleResource` | `code: string`; **`name: string`**; **`responsibilities: string`**; `competency_count: int` |

**Why annotate the ones that already look right.** The committed `backoffice/types/api.ts`
shows `FrameworkVersionResource` and `OrganizationResource.id` as already correct — which is
exactly why the earlier audit cleared them, and exactly why an audit against a stale
committed file is not an audit (finding 2). Two things follow. First, the design does **not**
specify a delta against the committed snapshot; it specifies the correct type per field from
casts and migrations, and the annotation overrides whatever the generator infers. Second,
the annotation's value is not only fixing today's wrong types — it **pins** the contract, so
a Scramble upgrade cannot silently re-degrade a field that happens to be right today. That
is the argument for all ten, including the two that look fine.

---

## D2 — Export determinism and the CI gate

### What was actually observed

**I could not run `scramble:export`.** This phase had no shell tool available, so the
proposal's "verify determinism by two consecutive local exports" is **not done** and is not
reported as done. What *was* done is a code-level reading, which narrows what the empirical
run has to look for:

| Source of variance | Reading | Verdict |
|---|---|---|
| Serialization | `ExportDocumentation.php:26` — `json_encode($doc, JSON_PRETTY_PRINT \| JSON_UNESCAPED_SLASHES)`, written with `File::put`. No timestamp, no uuid, no hash | Deterministic. Matches the committed files' 4-space format byte-for-byte |
| Operation order | `Generator.php:101` sorts by `groupWeight`, `weight`, first tag, then registration `index`; PHP 8 sorts are stable; `RouteFacade::getRoutes()` is registration order from `routes/api.php` | Deterministic |
| `info.version` | `config/scramble.php:49` → the `VERSION` file | Deterministic |
| **`servers[0].url`** | `Generator.php:175-185` builds it from `url('/')`, i.e. **`APP_URL`**. The committed value is `http://localhost/api` — Laravel's default | **Environment-coupled.** `api/.github/workflows/ci.yml`'s `env:` block does **not** set `APP_URL`. It passes today by accident of the default |
| Trailing newline | `File::put` writes no trailing `\n` | Must be confirmed against the committed file, or `git diff` reports a permanent one-byte delta |

### Decisions

1. **Pin `APP_URL: http://localhost` in `api/.github/workflows/ci.yml`'s `env:` block**,
   next to `APP_ENV`. Without it the new gate can go red on a server URL rather than on a
   contract change — the worst possible failure for a gate whose credibility is the point.
2. **The two-run determinism check is a blocking prerequisite task, not an assumption.**
   `php artisan scramble:export && cp openapi.json /tmp/a && php artisan scramble:export && diff /tmp/a openapi.json`.
   If it is byte-stable, the gate is the one line the proposal specifies:
   `git diff --exit-code openapi.json` after `scramble:export` at `ci.yml:114`.
3. **Pre-specified fallback if it is not byte-stable**: do not weaken the gate to a
   grep. Reuse `wrapper-ci.yml:155-183`'s canonicalisation verbatim — recursive key sort,
   parsed-JSON comparison, via Bun (already provisioned in the wrapper job; the API job
   would need a Bun step, which is the cost of the fallback and the reason byte comparison
   is preferred). **Do not** use `JSON.stringify(v, Object.keys(v).sort())`: that file
   already records that the replacer-array form reported "identical" against a deliberately
   corrupted spec.
4. `wrapper-ci.yml` gains a comment only: mutual equality of three copies is not freshness.
   No behaviour change there — it is good at what it does.

---

## D3 — Blast radius of regenerating the clients

**The rule the implementation must follow:** a cast added to silence the compiler is a
regression, not a fix. Every site is corrected where the wrong assumption lives — if a `ref`
was typed off a `string` id, the `ref` changes; if a prop contract says `string`, the prop
contract changes. `String(...)`, `as`, and `?? ''` on a now-nullable field are all forbidden
as fixes. The four *existing* silencing casts are deleted by this change, because they are
the visible scar tissue of the defect.

Not compiler-verified (`nuxi typecheck` could not be run here). Census by reading:

**Compiler-hard breakage — 9 sites in 4 files**

| # | Site | Break |
|---|---|---|
| 1 | `pages/projects/index.vue:82` | `ref<'new' \| string \| null>` → `'new' \| number \| null` |
| 2 | `pages/projects/index.vue:86` | `project.id === editing.value` → TS2367, no overlap |
| 3 | `pages/projects/index.vue:106` | `onEdit(id: string)` receives a number |
| 4 | `components/organisms/ProjectTable.vue:60` | `defineEmits<{(e:'edit', id: string)}>` emits `project.id: number` |
| 5 | `ProjectForm.vue:422` | `ref(props.project?.framework_version_id ?? '')` → `Ref<number \| ''>` |
| 6 | `ProjectForm.vue:424` | `pauseEveryNCompetencies` → `Ref<number \| ''>`, then fed to string validators |
| 7 | `ProjectForm.vue:425` | `nudgeMinChars`, same |
| 8 | `UsersPanel.vue:29` | after deleting `String(user.role)`, `null` is not assignable to `AccessLevelBadge`'s `role: string` |
| 9 | `UserForm.vue:151` | `props.user?.role as (typeof ACCESS_LEVELS)[number]` — resolves cleanly **iff** `ACCESS_LEVELS` equals `['admin','operator','viewer']`; if it does not, that disagreement is a finding, not a cast to keep |

**Silencing casts to delete — 4, in 3 files**: `ProjectForm.vue:419` (`as 'standard'|'potential'`),
`ProjectForm.vue:573` (`String(competency.name)`), `UsersPanel.vue:29` (`String(user.role)`),
`UserForm.vue:151` (`as`). `profile.vue:52`'s `String(profile.role)` is the same species but
belongs to `ProfileResource`, which is not one of the ten — note it, leave it.

**Fixtures the compiler will NOT catch — 8 files.** Every one returns
`Record<string, unknown>`, so `mount()` accepts them and `nuxi typecheck` stays green while
the fixture asserts a contract that no longer exists — precisely the "green suite certifying
broken code" this change exists to stop. They must be corrected by hand:
`tests/unit/components/organisms/{ProjectTable,ProjectForm,CandidateTable}.spec.ts`,
`tests/unit/pages/{projects/index,participants/detail}.spec.ts`,
`tests/unit/composables/useParticipants.spec.ts` (`{ data: { id: '42' } }`),
`tests/e2e/{admin-flow,projects-crud}.spec.ts`.

**`frontend/`: zero.** `frontend/tsconfig.app.json:9` excludes `types/api.ts` and no app
source imports it; the only reference is `tests/unit/api-client.spec.ts`, which touches
`/health`. The regenerated file and the drift check still have to land there — the wrapper's
cross-stack job requires all three copies identical — but there is no call-site work.

**Genuinely ambiguous — flag, do not guess.** `ProjectForm.vue:424-425`: the refs currently
hold `string | ''` and feed `<input>` `v-model` plus `isPauseEveryNCompetenciesValid`. With
`int | null` from the server there are two honest shapes — keep the ref a string and format
on read (`String(props.project?.pause_every_n_competencies ?? '')`, which is a *conversion at
a boundary*, not a silencing cast), or make the ref `number | null` and adapt the validators.
Design leans to the first (an `<input>`'s value is a string; that is the DOM's contract, not
the API's) but the validators' signatures decide it, and they are read at apply time.

---

## D4 — Admin password reset revocation

### Where `password_changed_at` is set

| Option | Tradeoff | Verdict |
|---|---|---|
| Eloquent model event / observer on `password` dirty | Catches every writer including future ones. Also catches: `UserFactory` (every factory-made user in the suite), `ProvisionOrganizationCommand`, `app:create-superadmin`, `RolesAndPermissionsSeeder`, `DemoWriter`, and — the one that would be unambiguously **wrong** — any future transparent rehash on login (`Hash::needsRehash`), which would log out every user in the system on a bcrypt-cost change. A bulk anonymisation job would revoke as an invisible side effect nobody wrote down | **Rejected** |
| Explicit assignment in `UserController::update()` and `store()` | Two writers, both places where a human deliberately changes a credential. Matches the file's existing shape: `deactivated_at` is set inline in `deactivate()`, and `ProfileController` sets `password_changed_at` inline. Honours `User.php`'s documented "controller-written, not `$fillable`" invariant | **Chosen** |

Revocation is an **authorization policy**, not a data invariant. `password_changed_at` means
"retire tokens issued before this instant" — a decision, not a fact about the row. A model
event silently rewrites that rule into "any code that touches the password column revokes
sessions", which a seeder, a factory, a console command and a rehash all satisfy by accident.

**Stated ceiling, not papered over:** nothing structural stops a third writer. The guard is
a Pest test at the HTTP boundary, not a mechanism. If a third password-writing route appears,
the answer is a test on that route.

`store()` is included, but **not for revocation** — a user who did not exist has no tokens.
It is included so the column's meaning is uniform for every row this surface creates ("the
instant the current credential was established") instead of a mix of `NULL` and timestamps.
One line, zero risk.

### The second-precision window

`now()->startOfSecond()`, compared with a strict `iat < password_changed_at` — **the same
formula as the self-service path**, deliberately. The residual is worse here: on the
self-service path an attacker needs the old password *and* the same wall-clock second; on the
admin path the attacker *has* the old password (that is why it is being reset) and is
plausibly logging in right now.

Considered and rejected: `now()->startOfSecond()->addSecond()`, which would close the window
completely on this path at no cost (there is no acting session on the target to preserve).
Rejected because it puts a **second, subtly different formula** on one column — the column
would hold a future timestamp for up to a second, and any surface rendering it as "password
last changed" would lie. Two formulas for one column is how the next person gets it wrong.
If the residual is ever judged unacceptable, the fix is a per-user token registry applied to
**both** paths — the thing `profile-self-service` D3 verified does not exist.

### An admin resetting their OWN password through the admin route

**The acting session is not preserved. Chosen deliberately.**

1. It cannot be preserved honestly. Preserving means re-minting and returning an
   `access_token`, making `PATCH /api/users/{id}`'s response shape depend on *who the target
   is* — a resource endpoint that sometimes returns credentials. That is the `api_key`-on-
   create special case, recreated for a flow that already has a dedicated endpoint.
2. The admin route accepts a new password with **no `current_password` proof**;
   `PUT /api/profile/password` requires `current_password:api`. Routing a self-password-change
   through the admin surface to keep the session would be using the weaker proof to earn the
   stronger outcome. Being logged out and signing in again re-proves possession.
3. The failure mode is mild and already built: `401 {"error":"credentials_changed"}` →
   `useApi.ts`'s existing `isCredentialsChanged()` branch (placed before `isUnauthorized()`)
   clears the session and redirects to `/login`. Tested path, correct wording.
4. No self-branch keeps `UserPolicy`'s "admin-only on every verb, no self-branch" invariant
   that `user-profile-self-service` D1 preserved on purpose.

### Sequence

    admin ──PATCH /api/users/{target}  {password}──▶ auth:api ─▶ TenantContext
                                                        │
                            UserAdminReader::read(id)   │  org filter + is_superadmin=false
                                                        ▼
                            $target->update(only(name,email,password))
                            $target->password_changed_at = now()->startOfSecond()
                            $target->save()
                                                        │
                                                200 UserResource   (no token, ever)

    target's live token ─▶ auth:api ─▶ RejectStaleCredentials
                                          iat < password_changed_at
                                          └─▶ 401 {"error":"credentials_changed"}
                                              └─▶ useApi clears session → /login

    target's refresh    ─▶ same 401 — buildRefreshClaims() preserves the original iat,
                           so a revoked session cannot refresh its way back

---

## D5 — The API-key list

| Option | Tradeoff | Verdict |
|---|---|---|
| Add pagination UI to `ApiKeysPanel` | Page state, controls, i18n, a11y and tests for a table that in practice holds fewer than twenty rows — and it makes the new three-state badge *worse*: "do I have any expired keys?" becomes a paging exercise | Rejected |
| Raise `per_page`, have the client follow `meta.last_page` | Keeps the envelope-agreement bug class and adds a loop | Rejected |
| **Unpaginated org-scoped list**: `->orderByDesc('is_active')->orderByDesc('created_at')->get()` | The panel answers a whole-set question ("what can authenticate against my org, and what did I revoke"); a page answers a different one. Deletes the envelope-agreement bug class instead of adding a second place that must agree with `paginate(20)` | **Chosen** |

Consistency argument: `UserController::index` already returns an unpaginated org-scoped
`->get()` for the same class of operator-managed collection. Two adjacent settings panels
should not disagree about whether their list is paginated.

Client cost is zero: `useApiClients.ApiClientListResponse` is already hand-declared as
`{ data: ApiClient[] }`, which is the unpaginated shape. `ApiKeysPanel.vue:308`'s
`clients.value = response.data` becomes correct rather than accidentally-correct-for-page-one.
`autocomplete-hygiene.spec.ts`'s mock keeps its `meta` — extra keys are ignored — but should
be trimmed for honesty.

**At a thousand keys, plainly.** The query is fine and the payload is ~200 KB. What degrades
is the **render**: a thousand `TableRow`s with a badge and a button, unvirtualised, in a
desktop-only SPA — visible jank, not a crash. There is no attacker-reachable growth vector:
creation is admin-only, org-scoped, one deliberate POST per key, and the list is already
filtered by `organization_id`. A thousand keys means an automation problem the panel should
*surface*, not hide behind page one — and `is_active desc` puts the rows that matter first
even in that degenerate case. **Recorded ceiling:** if any org passes ~200 keys, add a
server-side `state` filter (active/expired/revoked) *before* adding pagination. Filtering
answers the operator's question; pagination does not.

---

## D6 — Per-knob avatar-template config error keys

### The new shape

`ConfigValidator::validate()` is unchanged — it already returns
`list<array{key: string, code: string}>`. Only `AvatarTemplateController::assertConfigValid`
(`:224-240`) changes:

```php
throw ValidationException::withMessages(
    collect($errors)
        ->mapWithKeys(fn (array $e): array => ["config.{$e['key']}" => $e['code']])
        ->all()
);
```

```json
{ "message": "...", "errors": { "config.avatarId": ["required"], "config.temperature": ["range"] } }
```

**`config.{knob}`, not `{knob}`.** A bare `avatarId` would collide with a future top-level
field and would not say where to look. `config.avatarId` is Laravel's own nested-attribute
convention (`competency_ids.0`), which is what the backoffice already understands.

**Unknown keys.** `ConfigValidator:44-48` emits `['key' => 'wat', 'code' => 'unknown']` for a
knob no spec declares — there is no control to attach it to. It is emitted under
`config.wat` uniformly, **no special case**. The client's rule is unchanged in substance:
`config.X` where `X` is a field this provider currently renders → attach to that control;
otherwise → the summary. That total fallback is what makes a knob a since-changed spec no
longer exposes still reach the operator.

**Whole-config failure.** The bare `config` key survives and means something different:
`$request->validate(['config' => ['required','array']])` produces it when the object itself is
missing or not an array. `assertConfigValid` only runs *after* that passes, so **`config` and
`config.{knob}` are disjoint by construction** and can never appear in one response. The
client keeps handling bare `config` as a summary message.

### Client-side deletion

**`backoffice/app/utils/avatar-template-config-error.ts` is deleted outright**, along with
`backoffice/tests/unit/utils/avatar-template-config-error.spec.ts`. Its whole content is
`parseConfigError`, whose only job is undoing the server's flattening; with per-knob keys the
key *is* the knob. Keeping it for a `key.slice('config.'.length)` is not worth a module, a
spec file and a cross-file comment contract.

`AvatarTemplateForm.vue:445-490` keeps its watcher — it must, because
`applyServerFieldErrors` splits at the first `.` and would collapse every `config.X` back into
one `config` bucket, re-creating the defect. The watcher's `parseConfigError(message)` call is
replaced by a `config.` prefix match on the **key**; the `activeKeys` decision and the
summary fallback stay exactly as they are. The reciprocal comments in
`AvatarTemplateController` and the deleted util (each naming the other) go with it — the
cross-file contract they guarded no longer exists. The `avatar_templates.error.config.{code}`
i18n keys are untouched: the code is still the message.

**Sequencing note:** this deliverable edits `AvatarTemplateController.php` and
`AvatarTemplateForm.vue`, which the in-flight `avatar-provider-templates` change owns. That
change's task 3.2 (`ConfigValidator`) is `[x]` and its only open tasks (7.2, 7.3) are marked
out-of-scope-by-decision, so the collision risk is low — but its `tasks.md` must be re-read
before apply, and this is the deliverable to drop first if it has moved.

---

## D7 — Test noise, diagnosed before prescribed

### `TenancyTest.php:31-35` — the risky flag

`->throwsNoExceptions()` restates what an uncaught exception already does (fail the test);
its only real effect is silencing PHPUnit's no-assertion detector. Delete it and add the
assertion the test's own name claims: **the ambient tenant context is `null` before the
command and `null` after it.**

```php
$resolver = app(TenantResolver::class);
expect($resolver->getOrgId())->toBeNull();
$this->artisan('beai:demo-seed', ['--org' => 'acme'])->assertExitCode(0);
expect($resolver->getOrgId())->toBeNull();
```

That is the actual D7 claim — the command establishes its **own** `TenantContextScope::runFor`
boundary and restores it (`TenantContextScope.php:62-68`) rather than leaking a global tenant
context into the process — and no other test in the file covers it. Asserting "9 participants
exist" instead would be a tautology: the very next test already does that.

### `unsupported-gate.spec.ts:78` and `autocomplete-hygiene.spec.ts:132` (webkit)

| Spec | Diagnosis | Prescription |
|---|---|---|
| `autocomplete-hygiene.spec.ts:132` | **A test that depends on timing it should not.** `expectEveryInputToDeclareAutocomplete` (`:115-129`) does a one-shot `inputs.count()` and then one-shot `getAttribute()` calls — neither retries. It runs against `ProjectForm`, which is a `defineAsyncComponent` (a separate chunk) whose `onMounted` fires `loadCompetencyOptions()` against `/framework/roles/{code}/competencies` — an endpoint `mockAdminApi` **does not mock**, so it goes to the real dev server with non-deterministic latency and a `catch` that empties the options. `getByTestId('project-form')` becoming visible does not mean the control set has settled | Mock the endpoints the form actually calls; then replace the one-shot reads with retrying assertions — `await expect(inputs).toHaveCount(N)` followed by `await expect(input).toHaveAttribute('autocomplete', /.+/)` per input. Both changes are required: the mock removes the variance, the retrying assertion removes the class of bug |
| `unsupported-gate.spec.ts:78` | **Not diagnosable from source, and it must not be guessed.** Every assertion in it auto-retries, so the obvious mechanisms are absent; the one non-retrying dependency is `addInitScript` writing `sessionStorage` on the pre-navigation document, whose origin semantics differ in WebKit. `getByRole('navigation').toHaveCount(0)` is separately a **false-pass** risk (it is satisfiable before hydration), which is worth fixing regardless | **First task is to reproduce and capture the failure** (`--project=webkit --repeat-each=10`, trace on). Only then prescribe. Independently and unconditionally: replace the `toHaveCount(0)` with an assertion ordered *after* a positive settle signal, so it cannot pass by arriving early. Note `retries: 2` in CI is already masking whatever this is |

### `ProvisionOrganizationCommandTest` — a production defect, not test noise

`ProvisionOrganizationCommand.php:202` writes the generated password with `$this->line()`,
which routes through **Symfony's `OutputFormatter`** — and `Str::password(20)`'s symbol
alphabet contains `<`, `>` and `\`, all three of which the formatter assigns meaning to. The
test at `ProvisionOrganizationCommandTest.php:114-136` round-trips that output through
`preg_match('/Password:\s*(\S+)/')` and then `Hash::check`. So the test passes or fails **as
a function of the random draw** — the signature of an irreproducible flake.

This is not only test noise: an operator's printed credential can be mangled, so the string
on screen is not the string in the database, for the one account that bootstraps a
deployment.

- **Fix:** `$this->output->writeln("Password: {$password}", OutputInterface::OUTPUT_RAW)` —
  bypasses the formatter, exact bytes reach the operator.
- **Deterministic RED, because a random test cannot prove this:** extract the generation
  behind a `protected function generatePassword(): string` seam, override it in the test with
  a password containing `<info>`, `<`, `>` and `\`, and assert `Artisan::output()` contains it
  **byte-exact**. Red today, green after, and it never depends on a draw again.
- Honest caveat: not reproduced here. If the capture shows a different mechanism, this is
  wrong — but the seam and the `OUTPUT_RAW` write are correct on their own merits.

---

## D8 — Testing strategy (strict TDD, RED first)

**Runner discipline.** `php artisan test --filter=X` was observed returning fabricated passes
in this environment and was never reproduced across two later probes. Regardless: use
`./vendor/bin/pest <exact-file>` while iterating and a full unfiltered `./vendor/bin/pest`
before the PR. Playwright is `--workers=1` in CI — do not add E2E files; extend existing ones.

| Claim to prove | Layer | Test |
|---|---|---|
| **Translatable fields are strings** (this design's contested call) | Pest Feature | `GET /api/framework/roles` → `expect($json['data'][0]['name'])->toBeString()`; same for `responsibilities`, `CompetencyResource.name`/`definition`, and all four BARS fields. **If red, D1 is wrong — stop and re-decide** |
| Ids are integers at runtime, not just in the docblock | Pest Feature | `expect($json['data'][0]['id'])->toBeInt()` on participants, projects, framework versions; `project_id`, `organization_id`, `framework_version_id`, `pin_context.id`, `competencies.*.position` too. This is what the `(int)` casts exist for |
| Nullability is real | Pest Feature | A project with `role_code`/`exit_redirect_url`/`webhook_url`/`pause_every_n_competencies` null → those keys present and `null`, not `""`/`0`. An org with no webhook defaults → `default_webhook_url` null, `default_webhook_events` null |
| **The schema is fresh** | CI | `php artisan scramble:export && git diff --exit-code openapi.json` at `ci.yml:115`. Proven by a **deliberate red run first**: on a scratch branch, revert one annotation, push, watch it fail — then restore. A gate never seen red is a gate nobody has tested |
| The three copies still agree | CI | Existing `wrapper-ci.yml` cross-stack job, unchanged |
| The clients are regenerated, not hand-edited | CI | Existing `check-client-drift.sh` in both Nuxt repos |
| **Admin reset revokes the target** | Pest Feature (`Feature/UserManagement`) | Mint a token for the target; admin `PATCH /api/users/{target}` with `password`; target's token on `GET /api/auth/me` → `401 credentials_changed`; target's token on `POST /api/auth/refresh` → `401` too (closes the refresh escape). Use `resetAuthGuardState()` between the two tokens — `Pest.php:295-315` documents why |
| The admin's own token is unaffected when resetting **someone else** | Pest Feature | Same test: admin's token still `200` afterwards |
| An admin resetting **their own** password through the admin route IS logged out | Pest Feature | Admin `PATCH /api/users/{self}` with `password` → `200`; the acting token → `401 credentials_changed`; the response body contains **no** `access_token` |
| `store()` sets the column | Pest Feature | `POST /api/users` → `$user->password_changed_at` not null |
| Nothing else revokes | Pest Feature | Create a user via factory, mint a token, `PATCH /api/users/{id}` with **only** `name` → token still valid. This is the test that would fail if someone later adds the model event |
| Cross-tenant | Pest Feature | Admin of org A `PATCH /api/users/{orgB user}` → 404 (unchanged, `UserAdminReader`), and org B user's token still valid |
| **Per-knob keys arrive where the client expects** | Pest Feature + Vitest | API: `POST /api/avatar-templates` with two bad knobs → `422`, `assertJsonValidationErrors(['config.avatarId','config.temperature'])`, and `assertJsonMissingValidationErrors(['config'])`. Unknown knob → `config.wat` present. Non-array `config` → bare `config` present and **no** `config.*`. Client: `AvatarTemplateForm.spec.ts` feeds that exact error object and asserts `aria-invalid` + `aria-describedby` on the two matching controls and the unknown one in the summary |
| The parser is gone | Vitest | `avatar-template-config-error.spec.ts` deleted; `AvatarTemplateForm.spec.ts` green without it |
| The API-key table shows every key | Pest Feature + Playwright | Pest: 25 org-scoped clients → `data` has 25 and the body has no `meta`. Playwright: `admin-flow`/`settings` mock returns 25 → 25 rows |
| Demo's three states render | Pest Feature | The `beai:demo-seed` fixture's 3 clients (`OperationalFixtureConformanceTest:101`) all appear in `GET /m2m/clients` |
| No risky flags | CI | Full `./vendor/bin/pest` reports zero risky tests |
| Webkit specs are stable | Playwright | `--project=webkit --repeat-each=10` green on both specs, run **with `retries: 0`** so retries cannot hide it |

### RED-first order of work

1. **RED (API, D1)** — string/int/nullability assertions on all ten resources, plus the
   translatable-is-a-string assertion. Red against today's code.
2. **GREEN (API, D1)** — `@return` + `@scramble-return` + the `(int)` casts on the ten.
3. **The determinism probe** — two consecutive exports, diffed. Blocking; decides step 5.
4. **RED (API, D4/D6)** — revocation matrix, `store()`, the nothing-else-revokes test,
   per-knob error keys. **RED (API, D5)** — 25-client list, no `meta`.
5. **GREEN (API, D4/D5/D6)** — `UserController` two lines, `ApiClientController::index`,
   `assertConfigValid`. Then the CI gate + `APP_URL` pin, after its deliberate red run.
6. **The sync commit** (see below).
7. **RED/GREEN (client)** — `AvatarTemplateForm` watcher + delete the util and its spec;
   `ApiKeysPanel` (no change needed beyond trimming the mock).
8. **D7** — `TenancyTest` assertion; `ProvisionOrganizationCommand` seam + `OUTPUT_RAW`;
   capture the webkit failures, then fix.

### What MUST land in one commit

**Commit S — the snapshot and every consumer of it.** The ten resource files,
`task openapi:sync` (export + both copies + both `types/api.ts`), the 9 call-site
corrections, the 4 cast deletions, and the 8 fixture files. There is no intermediate green
state: the wrapper's cross-stack job requires all three `openapi.json` to be identical, so a
partial sync is a red `main`; and `nuxi typecheck` breaks the instant the snapshot lands
without its call sites. A snapshot and its consumers cannot disagree, so they cannot be two
commits.

Everything else is independently revertible and should be its own commit: the CI gate,
`UserController`, `ApiClientController` + panel, `assertConfigValid` + the client parser
deletion, and each test-noise fix.

---

## File Changes

| File | Action | Description |
|---|---|---|
| `api/app/Http/Resources/{Admin/Organization,Admin/ParticipantDetail,Admin/Participant,Admin/User,BarsIndicator,Competency,FrameworkVersion,Participant,Project,Role}Resource.php` | Modify | `@return` + `@scramble-return` per D1; `(int)` casts backing every integer field |
| `api/.github/workflows/ci.yml` | Modify | `APP_URL: http://localhost` in `env:`; `git diff --exit-code openapi.json` after `:114` |
| `.github/workflows/wrapper-ci.yml` | Modify | Comment only: mutual equality ≠ freshness |
| `api/app/Http/Controllers/Api/UserController.php` | Modify | `password_changed_at = now()->startOfSecond()` in `update()` (when `password` present) and `store()` |
| `api/app/Http/Controllers/M2m/ApiClientController.php` | Modify | `paginate(20)` → `orderByDesc('is_active')->orderByDesc('created_at')->get()` |
| `api/app/Http/Controllers/AvatarTemplateController.php` | Modify | `assertConfigValid` → `config.{knob}` keys; drop the reciprocal client comment |
| `api/app/Console/Commands/ProvisionOrganizationCommand.php` | Modify | `generatePassword()` seam; password line via `OUTPUT_RAW` |
| `api/tests/Feature/Demo/TenancyTest.php` | Modify | Drop `->throwsNoExceptions()`; assert ambient tenant context null before **and** after |
| `api/app/Support/AvatarTemplates/ConfigValidator.php` | **Unchanged** | Already returns `list<array{key, code}>` — only the controller flattened it |
| `api/app/Http/Resources/ApiClientResource.php` | **Unchanged** | The precedent; touching it would blur what this change proves |
| `{api,frontend,backoffice}/openapi.json`, `{frontend,backoffice}/types/api.ts` | Regenerate | One `task openapi:sync`, inside commit S |
| `backoffice/app/pages/projects/index.vue`, `components/organisms/{ProjectTable,ProjectForm,UsersPanel,UserForm}.vue` | Modify | D3 — 9 sites + 4 cast deletions |
| `backoffice/app/components/organisms/ApiKeysPanel.vue` | Modify | Comment only — `response.data` becomes correct rather than accidental |
| `backoffice/app/components/organisms/AvatarTemplateForm.vue` | Modify | Watcher matches the `config.` key prefix instead of parsing messages |
| `backoffice/app/utils/avatar-template-config-error.ts` | **Delete** | Nothing left to parse |
| `backoffice/tests/unit/utils/avatar-template-config-error.spec.ts` | **Delete** | With its subject |
| `backoffice/tests/{unit,e2e}/…` (8 fixture files) | Modify | String ids → integers; not compiler-caught |
| `backoffice/tests/e2e/autocomplete-hygiene.spec.ts` | Modify | Mock the framework endpoints; retrying assertions; trim the `meta` from the client mock |
| `backoffice/tests/e2e/unsupported-gate.spec.ts` | Modify | After capture; the `toHaveCount(0)` ordering fix regardless |
| `frontend/app/**` | **Unchanged** | `tsconfig.app.json:9` excludes `types/api.ts` and nothing imports it |

## Open Questions

- [ ] `ProjectForm.vue:424-425` — string-typed refs with boundary conversion, or
      `number | null` refs with adapted validators? Decided by
      `isPauseEveryNCompetenciesValid`/`isNudgeMinCharsValid`'s signatures, read at apply time.
- [ ] Does `UserForm.vue`'s `ACCESS_LEVELS` equal `['admin','operator','viewer']`? If not,
      the disagreement with `OrgRole` is a finding, not a cast to preserve.
- [ ] `avatar-provider-templates` is unarchived. Re-read its `tasks.md` before D6; drop D6
      from this change if it has moved onto `AvatarTemplateController`.
- [ ] **`ext-intl` is deliberately NOT added to `api/Dockerfile`** (ratified). `php artisan
      db:show` crashes on `Number::fileSize` in the production image. Diagnostics only, never
      the application. Recorded here so the next person who hits it finds the decision instead
      of re-opening it.
