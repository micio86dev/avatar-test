# Design: Date Formatting and Destructive-Action Confirmation

## Technical Approach

The proposal's diagnosis is that the primitives exist and nothing forces their
use. The design therefore adds **two enforcement guards and two primitives**,
not a library:

- `FormattedDate` atom + `tests/unit/arch/date-render.spec.ts` (the render path,
  and the thing that fails when someone bypasses it).
- Widened `ConfirmDialog` + `tests/unit/arch/destructive-action.spec.ts` (the
  same shape, for the same reason).

Both guards follow the repo's existing arch-guard precedent verbatim:
`backoffice/tests/unit/arch/form-contract.spec.ts` — recursive `.vue` collection,
`readFileSync`, pattern rules, an `AllowlistEntry[]` carrying a written reason,
and a **detection fixture** proving the scanner can fail.

`Intl` is kept. `formatDate`'s signature is untouched.

Everything downstream of `is_active` waits on the schema being true first.

---

## Architecture Decisions

### D1 — Date enforcement: atom AND guard, not either

| Option | Catches | Does NOT catch |
|---|---|---|
| `FormattedDate` atom alone | nothing — it is opt-in. A convenience, not a guard | the next `{{ row.created_at }}` |
| Arch guard alone | every raw `*_at` mustache in `app/**/*.vue` | see below |
| **Both (chosen)** | the guard forces the atom | see below |

**Choice**: both. The atom is the single render path; the guard is what makes it
mandatory.

**Guard rule (R1)**: for each `app/**/*.vue`, every `{{ … }}` interpolation whose
expression matches `/\b\w+_at\b/` is a violation unless the same interpolation
contains `formatDate(`. Attribute bindings pass — `<FormattedDate :value="c.created_at" />`
is the intended shape. Scope excludes `app/components/ui/**` (vendored shadcn-vue,
already excluded from coverage in `vitest.config.ts:37`) and the atom itself.

**What R1 does NOT catch, stated plainly:**

- a date laundered through a computed or local (`{{ row.when }}` where
  `when = client.created_at`);
- a date field not named `*_at` (`expiry`, `timestamp`, `deadline`);
- a date rendered through an attribute that produces visible text — `:title`,
  `:aria-label`, `:placeholder`;
- anything in `frontend/` (guard is backoffice-scoped — the frontend renders zero
  dates, per the proposal);
- a raw date built in a `.ts` composable and returned pre-stringified.

Naming these is the point. A guard sold as total is worse than a guard with a
known edge, because the first one stops people looking.

**Constraint honoured**: `backoffice/app/utils/format.ts:6-11` is not modified.
`tests/unit/utils/format.spec.ts:13-26` re-computes
`Intl.DateTimeFormat(locale, { dateStyle: 'medium', timeStyle: 'short' })` and
12 call sites depend on that exact output. `FormattedDate` **wraps** `formatDate`;
the zone suffix is an additive prop, never a signature change.

---

### D2 — The `is_active` type defect: root cause and order of operations

**Verified root cause.** `ApiClient.php:34-44` *already* declares
`@property int $id` and `@property bool $is_active`, and `ApiClient.php:83` casts
to boolean. Scramble still emitted `string` for both
(`api/openapi.json:3646-3670`). The reason is `ApiClientResource.php:35-36`:

```php
/** @var ApiClient $client */
$client = $this->resource;
```

Scramble 0.13 does not honour a `@var` annotation on a local assignment, so every
`$client->x` fetch degraded to its default, `string`. `expires_at`/`last_used_at`
came out `string|null` only because `?->toISOString()` is a *method* call it could
resolve. `abilities` came out `string | array{minItems:0,maxItems:0}` — the union
of an unresolved property and the literal `[]` fallback.

**Choice**: an explicit `@return array{…}` shape docblock on
`ApiClientResource::toArray()`.

| Option | Verdict |
|---|---|
| **`@return array{…}` on `toArray` (chosen)** | Scramble's documented override. Declarative. Touches zero runtime code, so the security whitelist at `:38-49` is provably unchanged |
| Explicit casts (`(bool) $client->is_active`) | Also works, but adds runtime coercion that does nothing — the values are already correct — and buries the contract in expressions |
| Model `@property` docblocks | **Already present and already ineffective.** Not a lever |
| Hand-edit `openapi.json` | Violates `Generated Client Parity` (`admin-backoffice/spec.md:184-188`). Next `scramble:export` reverts it |

**Order — non-negotiable, PR 1 in full:**

1. RED: `api/tests/Unit/C5/ApiClientResourceTest.php` gains `toBeBool()` /
   `toBeInt()` / `toBeArray()` wire-type assertions. (`:59` already asserts
   `toBeTrue()`, which passes today — it proves the *runtime*, which is correct;
   only the *schema* lies. The new assertions pin the docblock against drift.)
2. GREEN: `@return array{…}` added, including `state` (see D3).
3. `php artisan scramble:export` → `api/openapi.json`.
4. `cp api/openapi.json backoffice/openapi.json && bun run codegen`.
5. **`cp api/openapi.json frontend/openapi.json && bun run codegen` in `frontend` too.**
   `frontend/package.json:21` runs the same `check-client-drift.sh`, which diffs
   against `../api/openapi.json` (`:24-33`). Leaving it stale turns the frontend's
   `codegen:check` red for a change that never touches the frontend. The proposal
   does not name this; it is real.
6. Fixture correction in the same commit: `ApiKeysPanel.spec.ts:91,94,119,122` —
   `id: 1`, `is_active: true`.

**Risk to watch at step 3**: `scramble:export` regenerates the whole document. If
unrelated schemas move, that is pre-existing staleness surfacing, not this
change's work — flag it in the PR, do not silently absorb it.

No badge code, no truthiness check, exists before step 6 lands.

---

### D3 — Three-state derivation lives on the API

**Choice**: `ApiClientResource` exposes `state: 'active' | 'expired' | 'revoked'`,
derived by a new `ApiClient::state()` sitting immediately beside `scopeActive`
(`ApiClient.php:102-110`), pinned by an equivalence test.

**Alternative rejected — client-side from `is_active` + `expires_at`.**

The decisive argument is **whose clock**. Client-side derivation compares
`expires_at` against the *browser's* clock; the guard that actually accepts or
refuses the key compares against the *server's*. On a machine ten minutes slow
the badge says "Active" for a key the API is already rejecting — which is the
exact class of bug this change exists to remove (the operator believing the UI
over the system). Server-derived `state` is computed by the clock that decides.

Secondary: this session has already been bitten by two implementations of one rule
diverging (`extractConfigErrors` vs. the form's own parser,
`avatar-templates/index.vue:159-164`). Client-side derivation would make a *third*
implementation of `active()`, in a third language.

**Honest cost, and why it is accepted.** A SQL `WHERE` and a PHP boolean cannot
literally share code, so `state()` is still a second expression of the same rule —
it is merely *adjacent* and *pinned*:

> `api/tests/Unit/C5/ApiClientStateTest.php`: across five rows — active/no expiry,
> active/future expiry, active/past expiry, revoked/future expiry, revoked/past
> expiry — assert `state === 'active'` **iff** the row is returned by
> `ApiClient::active()->get()`.

That converts "hope they agree" into "CI fails when they stop agreeing".

**The expiry-passes-while-the-page-is-open question.** A server-computed `state` is
a snapshot; a page left open past an expiry keeps showing "Active" until the next
`load()`. **No ticking client-side recompute is added.** Reasons: (a) making one
column live while `name`, `last_used_at` and the row set itself are all snapshots
is incoherent, not safer; (b) the boundary is crossed once in a key's lifetime, and
a per-row timer is machinery for that; (c) the action is guarded server-side
regardless. The staleness window equals the table's existing staleness window.

**Schema consequence**: `state` is an additive field, so it ships in **PR 1** with
the type fix — one schema change, one regeneration, one drift-check event. The
badge that consumes it still ships in PR 4.

**Revoke guard**: `v-if="client.state === 'active'"`, following the repo's own
ratified reasoning at `avatar-templates/index.vue:85-90` — do not offer a control
whose only outcome is an error. The badge in the same row supplies the explanation
for the absence, which is what makes hiding legitimate here rather than mysterious.

---

### D4 — Widening `ConfirmDialog`

```ts
withDefaults(defineProps<{
  open: boolean
  title: string
  description: string
  confirmLabel?: string        // default: $t('users.confirm.action')
  cancelLabel?: string         // default: $t('projects.action.cancel')
  variant?: 'default' | 'destructive'
}>(), { confirmLabel: undefined, cancelLabel: undefined, variant: 'default' })
```

Template resolves the fallback **in the template**, not in a `withDefaults` factory:

```vue
{{ confirmLabel ?? $t('users.confirm.action') }}
```

**Why**: `$t` is a template global, and a string captured at prop-default time
would not re-render on a locale switch. Keeping `??` in the template preserves the
locale reactivity the spec's i18n requirement demands.

Both existing call sites (`ApiKeysPanel.vue:189-195`, `UsersPanel.vue:75-89`)
compile unchanged — every new prop is optional and defaults to today's exact
string. They are then migrated to real verbs ("Revoke", "Deactivate") in the same
PR; the three existing `ConfirmDialog.spec.ts` tests never assert button text and
stay green untouched, which is the additive proof.

**`variant`: yes, needed.** It changes **the confirm button only** — applies
`buttonVariants({ variant: 'destructive' })` to `AlertDialogAction`. Not the title,
not the icon, not the backdrop. Without it "Revoke" and "Activate" are visually
identical, and distinguishing the irreversible one is the dialog's entire job.
Scoping it to one button keeps it a one-line change that cannot leak layout.

**`suppressNextCancel` (`:50-76`) is preserved verbatim.** It is defence. The
actual guarantee is the call-site contract:

> **Every `ConfirmDialog` call site MUST:**
> 1. hold a **single nullable ref** for the target (`revokeTarget`, `confirmTarget`) —
>    never a separate `showDialog` boolean;
> 2. bind `:open="target !== null"` — derived, never independently assigned;
> 3. handle `@cancel` with exactly `target = null` — no side effects, nothing async;
> 4. handle `@confirm` by reading the target into a local, **clearing the ref
>    first**, then acting — `onRevokeConfirmed` (`ApiKeysPanel.vue:368-374`) is the
>    reference implementation;
> 5. never mount two dialogs bound to the same ref.

Rule 4 is the one that matters: clearing first makes any late spurious `cancel`
idempotent instead of a race. The flag stops the emit; the contract makes the emit
harmless if it ever returns.

`ConfirmDialog.spec.ts` gains: default labels render; overridden labels render;
`variant="destructive"` puts the destructive class on confirm; and **the missing
regression test** — a confirm click emits `confirm` exactly once and `cancel`
**zero** times. That last one does not exist today and is the only test that would
catch the race coming back.

---

### D5 — Making the fifth destructive action confirmed by default

| Mechanism | Forces anything? |
|---|---|
| Convention in the spec | No |
| `useConfirmedAction` composable | No — a new `@click="remove(x)"` is still one line away |
| **Arch guard (chosen)** | Yes — CI turns red |

**Choice**: `tests/unit/arch/destructive-action.spec.ts`, two rules, plus the D4
call-site contract written into the spec. **No composable.**

- **R1** — a `app/**/*.vue` file that calls a destructive-looking method
  (`/\b(delete|remove|revoke|archive|destroy|import|activate|deactivate)[A-Z]\w*\(/`,
  plus a named list of known composable methods) MUST import `ConfirmDialog`.
  File-level, exactly like `form-contract.spec.ts`'s R3, and for the same
  documented reason.
- **R2** — `window.confirm` / `window.alert` / bare `confirm(` / `alert(` appear
  nowhere under `app/**` in **either** app. Precise, no meaningful false negatives.
  Turns the proposal's "intact by accident" into "intact by CI".

**What R1 misses, stated plainly:**

- a file that imports `ConfirmDialog` for action A and then adds unguarded action B
  — file-level, so it passes;
- a destructive verb outside the regex and the list (`swap`, `purge`, `reset`);
- a destructive call relocated into a composable and invoked under an innocuous
  name;
- anything not in a `.vue` file.

It does not prove the call is *behind* the dialog. It makes the omission **loud**,
and going green requires having thought about confirmation. That is the honest
ceiling of a text-level guard, and it is still the difference between four
unguarded actions shipping and zero.

**Why not the composable**: the four call sites differ materially — `ApiKeysPanel`
holds a row object, `ProjectForm` holds a status string *and* shares `saving`,
`TemplatePortability` holds a parsed document. A composable general enough for all
four becomes a config object with more surface than the five-line pattern it
replaces, and it still would not force adoption — which was the actual problem.
The guard forces the conversation; the contract says what to write.

Allowlist ships **empty**, same `AllowlistEntry[]` shape, reason required per entry.

---

### D6 — Rewriting the click-through tests: one pattern, applied mechanically

`ConfirmDialog` renders through reka-ui's `AlertDialog`, which **teleports to
`document.body`** — `wrapper.find('[data-testid="confirm-dialog-confirm"]')` will
never match. `ConfirmDialog.spec.ts:23,40-42` and `ApiKeysPanel.spec.ts:82-84`
already prove the working shape.

New shared helper, `backoffice/tests/unit/support/confirm.ts`:

```ts
export async function confirmDialog(action: 'confirm' | 'cancel' = 'confirm') {
  const button = document.body.querySelector<HTMLButtonElement>(
    `[data-testid="confirm-dialog-${action}"]`
  )
  if (!button) throw new Error(`No open ConfirmDialog: confirm-dialog-${action} not found`)
  button.click()
  await flushPromises()
}
```

Every rewrite is then the same three lines, and the middle assertion is the
feature:

```ts
await wrapper.find('[data-testid="template-activate-1"]').trigger('click')
await flushPromises()
expect(api.activateTemplate).not.toHaveBeenCalled()   // ← the point of the change
await confirmDialog('confirm')
expect(api.activateTemplate).toHaveBeenCalledWith(1)
```

Two mechanical edits to each affected `mountPage` helper: add
`attachTo: document.body`, and `afterEach(() => { document.body.innerHTML = '' })`.
Both already precedented.

Affected: `avatar-templates-page.spec.ts:116` ("reloads the list after
activating"), `:129` (persona-sync warning), `:145` ("reloads after deleting").
Each also gains its mirror: **cancel performs nothing** — the assertion that
actually proves the feature and does not exist anywhere today.

**Disagreement with the proposal, recorded**: it names
`avatar-template-form.spec.ts` as affected. A search of that file for
`delete|activate|confirm` returns nothing. It renders the form, not the list
actions. Verify at implementation time rather than budgeting a rewrite that
appears not to be needed.

---

### D7 — `ProjectForm` archive: never set `saving`, rather than remember to reset it

**Choice**: the archive button stops calling `onTransition` and instead sets
`archiveConfirm = true`. `@cancel` sets it back to `false` and touches nothing else.
`@confirm` sets it `false`, then calls `onTransition('archived')` **completely
unchanged** (`:656-667`).

Because the only assignment of `saving = true` lives inside `onTransition`, and
`onTransition` is now reachable only from confirm, the cancel path **structurally
cannot** strand `saving`. The proposal's mitigation ("cancel path must reset
`saving`") fixes it by remembering; this fixes it by never setting it. Structural
beats remembered — and it keeps the diff to the template plus one ref.

Activate (`:319-326`) stays unconfirmed: consequence-driven, and activating a
project destroys nothing.

Test: click archive → `saving` still `false`, `updateProject` not called; cancel →
still `false`; confirm → called with `{ status: 'archived' }`, `saving` `false`
after settle.

---

### D8 — Import: preview, not a bare confirmation

**Choice**: a preview. The dialog names the file's contents.

The file is **already fully parsed before any network call**
(`TemplatePortability.vue:95`), and the export document is
`{ schema: string, templates: [{ name, … }] }` — confirmed against
`AvatarTemplatePortabilityController.php:61-78`. The names are in hand at zero
extra cost.

A dialog reading "Import templates? This will overwrite configuration." while the
operator cannot see which file the OS picker actually handed over can only be
answered "yes". It asks for consent without disclosing what is being consented to
— precisely the failure mode the proposal names. This is the one action where the
content *is* the confirmation.

`onImport` splits:

- `onFileChosen` — read, `JSON.parse`, validate that `templates` is an array, hold
  `pendingImport = { document, names }`. A file that fails either step **never
  reaches a dialog**: it reports through the existing `message` banner, so a parse
  error is not disguised as a scary confirmation.
- `onImportConfirmed` — the existing POST + result banner + `emit('imported')`,
  unchanged.
- `@cancel` — `pendingImport = null` and clear the picker (`picker.value.value = ''`,
  already at `:117`), so re-picking the same file fires `change` again.

Dialog description: count plus the first N names, remainder as "+N more".

---

### D9 — Timezone: two places, one surface

**Written down in exactly two places:**

1. `backoffice/app/utils/format.ts` module docblock (`:1-5`) — operational, where
   the next person edits.
2. `openspec/specs/admin-backoffice/spec.md`, the `i18n and Locale-Aware Formatting`
   requirement (`:171-182`) — normative, with a scenario.

Not CLAUDE.md, not AGENTS.md, not DESIGN.md, not `docs/`. A convention repeated in
five places goes stale in four.

**Convention**: the API emits UTC ISO 8601 (`ApiClientResource.php:43-45`;
`api/config/app.php:68` hardcodes UTC). Display is the viewer's browser zone. No
user or organization timezone concept exists.

**Which surfaces state their zone: `expires_at` in the API-keys table only.**
A deadline is the one date where "which zone?" changes what the reader *does*;
`created_at` and `last_used_at` are observational ("recently or long ago"). A
suffix on all twelve sites is noise that makes the one that matters invisible.

Mechanism — opt-in `show-zone` prop on `FormattedDate`, `Intl`-only, no change to
`formatDate`:

```ts
new Intl.DateTimeFormat(locale, { timeZoneName: 'short' })
  .formatToParts(date).find((p) => p.type === 'timeZoneName')?.value
```

`formatToParts` rather than string surgery, and `timeZoneName: 'short'` rather than
`resolvedOptions().timeZone`, because the former is locale-aware ("CEST" / "GMT+2")
and the latter is not.

---

### D10 — Pagination: out of scope, with a caveat the proposal does not carry

**Out**, but not for "diff size". The fix is not one line: `ApiClientListResponse`
(`useApiClients.ts:12-14`) types `{ data: ApiClient[] }` while the real envelope
carries `links`/`meta` (`openapi.json:147+`), so doing it properly means a
paginated response type, a page control, and a decision about where a revoke
returns you. That is a UI feature. Doing it improperly (`paginate(100)`) hides the
same bug further out.

**Caveat this change introduces**: revoked keys stay in the list by design
(`ApiClientController.php:124-126` does not filter), and once operators can *see*
state they have a reason to keep them. The 20-row ceiling is therefore reached
sooner **because** of this change. It moves from latent to arriving-faster. Record
it on the deferred item; do not let it disappear.

---

## Data Flow

```
PR1  ApiClient::state() ──┐
     scopeActive (SQL) ───┴─ equivalence test pins them
                │
     ApiClientResource @return array{…}  ──→ scramble:export
                │                              │
     api/openapi.json ──┬──→ backoffice/openapi.json ──→ types/api.ts
                        └──→ frontend/openapi.json  ──→ types/api.ts

PR2  *_at ──→ <FormattedDate> ──→ formatDate() ──→ Intl
                    ▲
       date-render.spec.ts scans app/**/*.vue

PR4  click ──→ target = row ──→ :open ──→ ConfirmDialog
                                    │ cancel → target = null   (nothing else)
                                    └ confirm → local = target
                                                target = null  (FIRST)
                                                await action()
                                                await load()
                    ▲
       destructive-action.spec.ts scans app/**/*.vue
```

---

## File Changes

| File | Action | Description |
|---|---|---|
| `api/app/Http/Resources/ApiClientResource.php` | Modify | `@return array{…}` shape; `state` field |
| `api/app/Models/ApiClient.php` | Modify | `state()` beside `scopeActive` |
| `api/tests/Unit/C5/ApiClientResourceTest.php` | Modify | wire-type assertions |
| `api/tests/Unit/C5/ApiClientStateTest.php` | Create | 5-row `state` ⇔ `active()` equivalence |
| `api/openapi.json`, `backoffice/openapi.json`, `frontend/openapi.json` | Modify | regenerated |
| `backoffice/types/api.ts`, `frontend/types/api.ts` | Modify | regenerated |
| `backoffice/app/components/atoms/FormattedDate.vue` | Create | single date render path; `show-zone` |
| `backoffice/app/components/atoms/ApiKeyStateBadge.vue` | Create | 3-state badge; mirrors `UserStateBadge.vue` |
| `backoffice/app/components/molecules/ConfirmDialog.vue` | Modify | `confirmLabel`/`cancelLabel`/`variant` |
| `backoffice/app/components/organisms/ApiKeysPanel.vue` | Modify | `:29-31` dates; state column; Revoke `v-if` |
| `backoffice/app/components/organisms/UsersPanel.vue` | Modify | real verbs on `:75-89` |
| `backoffice/app/components/organisms/TemplatePortability.vue` | Modify | split parse/confirm; preview dialog |
| `backoffice/app/components/organisms/ProjectForm.vue` | Modify | archive behind confirm; `onTransition` untouched |
| `backoffice/app/pages/avatar-templates/index.vue` | Modify | confirm activate + delete |
| `backoffice/app/utils/format.ts` | Modify | timezone convention in the docblock only |
| `backoffice/i18n/locales/{it,en}.json` | Modify | verbs, consequence copy, badge labels, zone label |
| `backoffice/tests/unit/arch/date-render.spec.ts` | Create | R1 + detection fixture |
| `backoffice/tests/unit/arch/destructive-action.spec.ts` | Create | R1/R2 + detection fixture |
| `backoffice/tests/unit/arch/fixtures/RawDateTemplate.vue` | Create | deliberately non-compliant |
| `backoffice/tests/unit/arch/fixtures/UnconfirmedDestructive.vue` | Create | deliberately non-compliant |
| `backoffice/tests/unit/support/confirm.ts` | Create | `confirmDialog()` helper |
| `backoffice/tests/unit/**` (4 specs) | Modify | fixtures, dialog rewrites, cancel mirrors |

---

## Interfaces / Contracts

```php
// ApiClientResource::toArray — Scramble reads THIS, not the array literal.
/** @return array{id: int, name: string, abilities: list<string>,
 *      is_active: bool, state: 'active'|'expired'|'revoked',
 *      expires_at: string|null, last_used_at: string|null, created_at: string} */
```

```vue
<!-- FormattedDate: wraps formatDate; NEVER changes its signature -->
<FormattedDate :value="client.expires_at" show-zone />
```

---

## Testing Strategy

| Layer | What | How |
|---|---|---|
| Arch (unit) | raw-date rule; destructive-without-dialog; no `window.confirm`/`alert` | glob + `readFileSync` + regex, `form-contract.spec.ts` shape |
| Arch — **detection** | that each guard *can* fail | fixtures under `tests/unit/arch/fixtures/`, **outside `APP_ROOT`** so the repo-wide rules never scan them; fed directly to the rule functions, mirroring `form-contract.spec.ts:164-177` |
| Unit (PHP) | `state` correctness; `state ⇔ active()`; wire types | Pest, 5-row table |
| Unit (Vue) | `FormattedDate` (null, locale, zone); `ConfirmDialog` labels/variant/**no double-emit**; per-action nothing-on-click, nothing-on-cancel, act-on-confirm; import preview; `ProjectForm` `saving` never set on cancel | Vitest + `attachTo: document.body` + `confirmDialog()` |
| Contract | `codegen:check` green in **both** backoffice and frontend | existing `check-client-drift.sh` |
| E2E | revoked key shows badge and offers no Revoke; cancelling archive leaves the project active | 2 thin specs; **run `bun run test:e2e -- --workers=1`** on this machine (`playwright.config.ts:20` leaves local workers `undefined` = one per core) |

**RED-first order.**

- **PR 1** — RED wire-type + `state` Pest tests → GREEN docblock + `state()` → RED
  equivalence test → GREEN → export/copy/codegen ×2 → fixtures → both drift checks.
- **PR 2** — RED `date-render.spec.ts` detection fixture (fails: no scanner) → RED
  repo-wide R1 (fails: `ApiKeysPanel.vue:29-31`) → RED `FormattedDate.spec.ts` →
  GREEN atom + 3 call sites + convention.
- **PR 3** — RED labels/variant/no-double-emit → GREEN widen → migrate both call
  sites; the 3 pre-existing `ConfirmDialog.spec.ts` tests stay green untouched.
- **PR 4** — RED `destructive-action.spec.ts` fixture, then R1/R2 (fails on 4
  files) → RED per-action click/cancel/confirm triples + badge + Revoke-absent →
  GREEN.

Coverage gate stays at 85% lines (`vitest.config.ts:38-40`).

---

## Migration / Rollout

No migration. No schema change to the database, no persisted state, no API
behaviour change — PR 1 corrects only the *description* of a payload that was
already correct at runtime. Each PR reverts independently, per the proposal.

---

## Open Questions

- [ ] **Q1 (dayjs) is answered**: keep `Intl`. Recorded here as ratified; the
      design assumes it and would need rewriting under a reversal.
- [ ] Confirmation copy for `it` and `en` — the activate sentence must name the
      template it replaces org-wide. Needs review, not invention.
- [ ] Preview cutoff N for the import dialog (proposed: 5 names + "+N more").
- [ ] Whether `state` should also be filterable server-side. Out of scope; noted
      because it is the natural follow-on to the deferred pagination fix.
