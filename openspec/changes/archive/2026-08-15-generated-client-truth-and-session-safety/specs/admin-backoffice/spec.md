# Delta for Admin Backoffice

## MODIFIED Requirements

### Requirement: Generated Client Parity

`backoffice/types/api.ts`/`openapi.json` MUST be regenerated (`bun run
codegen`) in the same change as any new endpoint consumption; `codegen:check`
(drift check) MUST be green. Types are never hand-maintained.

The generated type for a field MUST match its actual runtime wire type, not a
type inferred from an example payload that disagrees with the model's cast.
`is_active` on `ApiClientResource` MUST be typed `boolean` (the model casts
it as such); `id` and `abilities` MUST match their real wire shapes. Test
fixtures exercising these fields MUST use real booleans, never the string
`'true'`/`'false'`.

Regenerating the client after `admin-read-api`'s Scramble Documentation
Parity fix corrects previously-`string`-typed fields to their real types —
`id: string` becomes `integer`, `status`/`role_code` become their real
string-literal unions, and translatable fields (previously exported as
`unknown[]`, not `string` — Scramble's actual default for a field whose only
static hint is an `array` cast it cannot resolve to an item type) become
`string`, per `admin-read-api`'s Scramble Documentation Parity requirement
and the `HasTranslations::getAttributeValue()` evidence recorded there. Every
call site the stricter type breaks MUST be corrected in the same change that
regenerates the client. A type assertion (`as string`, `as any`, or similar)
added solely to silence the resulting compiler error MUST NOT be used — that
reintroduces the original defect under a different name; it is a regression,
not a fix.

(Previously: covered drift-check-is-green for new endpoints and required
`is_active`'s cast-accurate type; silent on how a client-wide type-parity fix
interacts with existing call sites, and did not prohibit a suppressing cast.)

#### Scenario: Drift check is green after adding a new endpoint call

- GIVEN a new admin endpoint is consumed by a page/composable
- WHEN `bun run codegen:check` runs in CI
- THEN it exits 0 (no drift between `openapi.json` and hand-written types)

#### Scenario: is_active is typed and tested as a real boolean

- GIVEN `ApiClientResource`'s generated TypeScript type
- WHEN `is_active` is inspected
- THEN its type is `boolean`
- AND `ApiKeysPanel.spec.ts` fixtures set it to `true`/`false`, never `'true'`

#### Scenario: A stricter regenerated type is corrected, not cast away

- GIVEN a call site previously read `participant.id` as `string` and the regenerated client now types it `number`
- WHEN the TypeScript compiler reports the resulting type error
- THEN the call site is corrected to use the value as a number
- AND no `as string`/`as any` cast is introduced to silence the error

#### Scenario: The Nuxt CI type-check catches an uncorrected call site

- GIVEN a call site left unmigrated after the client regenerates with stricter types
- WHEN `nuxi typecheck` runs in CI
- THEN it fails, per `ci-pipeline`'s existing TypeScript Type-Check requirement

## ADDED Requirements

### Requirement: API-Keys Table Shows Every Key, Not Only The First Page

`ApiClientController::index` returns an UNPAGINATED, org-scoped list
(`orderByDesc('is_active')->orderByDesc('created_at')->get()`) — `{ data:
ApiClient[] }`, with no `links`/`meta` envelope. `ApiKeysPanel.vue` reading
`response.data` directly is therefore correct, not a bug: there is no second
page to miss. Every one of the organization's keys MUST be reachable from
the table without any paging interaction, at any count.

**Why unpaginated, not "read the pagination metadata"**: this requirement's
original text (drafted opposite this change's actual decision, D5) required
the panel to consume `links`/`meta` and page through the endpoint. Design.md
D5 rejected that: the panel answers a whole-set question ("what can
authenticate against my org, and what did I revoke"), and a page answers a
different one. Client-side pagination would also have kept the underlying
envelope-agreement bug class alive (a second place that must agree with
`paginate(20)`) instead of deleting it. `UserController::index` already sets
the precedent — an unpaginated, org-scoped `->get()` for the same class of
operator-managed collection. Recorded ceiling (design.md D5): if any org
passes roughly 200 keys, add a server-side `state` filter
(active/expired/revoked) BEFORE reaching for pagination — filtering answers
the operator's question; paging does not.

#### Scenario: A 21st key is reachable

- GIVEN an organization with 21 API keys
- WHEN the operator opens the API keys tab
- THEN all 21 keys are visible in the table, with no paging interaction

#### Scenario: The panel reads the unpaginated data array directly

- GIVEN the API-clients endpoint returns `{ data: ApiClient[] }` with no
  `links`/`meta` envelope
- WHEN `ApiKeysPanel.vue` requests the list
- THEN it assigns `response.data` directly to the table's rows

#### Scenario: An organization with 20 or fewer keys shows all of them

- GIVEN an organization with 5 API keys
- WHEN the tab renders
- THEN all 5 are visible without requiring pagination interaction
