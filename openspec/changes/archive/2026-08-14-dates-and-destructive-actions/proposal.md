# Proposal: Date Formatting and Destructive-Action Confirmation

## Intent

Three requests, one root cause: **the backoffice has safety and formatting
primitives that nothing forces anyone to use.** `formatDate` exists and three
columns bypass it. `ConfirmDialog` exists and four state-changing actions bypass
it. `is_active` is serialised by the API and the table throws it away.

The reported symptom — DELETE returned 204, the row did not change, the operator
believed nothing happened — is not a bug in revocation. Revocation worked. The
table simply never rendered the outcome.

## Verified current state

Read from code, not documentation.

**Dates.** One formatter: `backoffice/app/utils/format.ts:6-11`,
`Intl.DateTimeFormat(locale, { dateStyle: 'medium', timeStyle: 'short' })`,
`null → '–'`. Twelve call sites use it. **Three do not**, and print a raw ISO
string into the table: `ApiKeysPanel.vue:29` (`created_at`), `:30`
(`expires_at`), `:31` (`last_used_at`).

**The frontend renders zero dates.** Its only `Date` use is `toISOString()` for
outbound telemetry (`useProctor.ts:228,524`, `useInterviewSession.ts:237`).
Request 1 is therefore **backoffice-only in practice** — stated here rather than
silently scoped down.

**No date library exists** in either app. `format.ts:2-4` and
`admin-backoffice/spec.md:174` both record a ratified policy: `Intl` only, never
manual formatting.

**The API emits UTC ISO 8601** (`ApiClientResource.php:43-45`,
`Admin/UserResource.php:36-37`); `api/config/app.php:68` hardcodes UTC. There is
**no user or organization timezone concept anywhere**, and no timezone
convention is documented in CLAUDE.md, AGENTS.md, DESIGN.md, GUIDE.md or docs/.
Dates render in whatever zone the browser is in, with nothing telling the reader
which. That is a real gap, recorded here.

**Destructive actions.** `ConfirmDialog.vue` is the only confirmation primitive
and is used in exactly two places: `ApiKeysPanel.vue:189` and
`UsersPanel.vue:75`. Everything else fires on first click:

| Action | Site | Blast radius |
|---|---|---|
| **Activate avatar template** | `avatar-templates/index.vue:75-83` → `:238` | **Highest in the product.** The server atomically deactivates the previous template, so one unconfirmed click changes the face and voice every candidate in the org meets. Not destructive *in name* — which is exactly why it was missed |
| Delete avatar template | `:91-99` → `:254` | Hard, unrecoverable `DELETE` |
| Import avatar templates | `TemplatePortability.vue:13/31` → `:88` | Bulk config write from an arbitrary uploaded JSON, no preview, result reported only afterwards |
| Archive project | `ProjectForm.vue:327-335` → `:656` | Reversible, but silent |

`window.confirm`/`alert` appear **nowhere** in either app. That prohibition is
currently intact by accident; this change makes it normative.

**`ConfirmDialog`'s API is too narrow for the job.** Props are
`open`/`title`/`description` (plain strings), emits `confirm`/`cancel`, **no
slots, no `confirmLabel`, no `variant`**. Its buttons are hardcoded to
`$t('projects.action.cancel')` (`:10`) and `$t('users.confirm.action')` (`:17`)
— so **every** confirmation in the app says "Confirm"/"Cancel" regardless of
what it does. A "Delete" or "Revoke" verb is currently not expressible. It also
carries a `suppressNextCancel` flag (`:50-76`) that stops reka-ui emitting a
spurious `cancel` after `confirm`; every new call site must clear its target
state on `cancel` in the exact pattern the two existing sites use, or the race
returns.

**API-key state — and a landmine.** `ApiClientResource.php:42` serialises
`is_active`; `useApiClients.ts:10` types the row from it; `ApiKeysPanel.vue`
references it **zero times**. The Revoke button (`:33-40`) has no `v-if`/
`disabled` guard, so an operator can revoke an already-revoked key, get the full
dialog, fire a second DELETE and again see nothing change.

1. **`backoffice/types/api.ts:1121` declares `is_active: string`** (also
   `id: string`, `abilities: string | string[]`). The OpenAPI schema was
   inferred from example JSON, not from real types — `ApiClient.php:83` casts
   `is_active` to `boolean`, so the wire value is a real JSON boolean. Test
   fixtures mirror the error (`ApiKeysPanel.spec.ts:94` uses the string
   `'true'`). **A truthiness check would pass the tests and lie in production.**
   The schema MUST be corrected and the client regenerated *before* any badge is
   written.
2. **The state is not binary.** `m2m-auth/spec.md:362` and
   `ApiClient.php:102-108` define authentication by the `active()` scope —
   `is_active = true AND (expires_at IS NULL OR expires_at > now())`. A badge
   driven by `is_active` alone would print **"Active" on an expired key**. There
   are three states: active, expired, revoked.
3. `index` returns `paginate(20)` but `ApiKeysPanel.vue:292-294` reads only
   `response.data` and ignores the envelope, so beyond 20 keys the rest are
   invisible.

Keeping revoked rows visible is deliberate:
`ApiClientController.php:121-124` does not filter them, because revocation is a
soft flag plus a Redis denylist (`:143-190`).

Precedent for the badge is near-verbatim: `atoms/UserStateBadge.vue` (12 lines,
`boolean → destructive/default`), alongside `AccessLevelBadge`,
`ProjectStatusBadge`, `StatusBadge`, `ReliabilityBadge`.

## Recommendation: keep `Intl`, do not add dayjs

The user asked for dayjs by name. The honest answer is that **dayjs would not
deliver what was actually asked for, and `Intl` already does.**

| | `Intl.DateTimeFormat` (today) | dayjs |
|---|---|---|
| Locale-aware output | Yes, already reactive to the i18n locale | Yes |
| Bundle cost | 0 bytes — platform built-in | Runtime dep + one locale file **per locale**, imported and kept in sync with `nuxt.config.ts:13-50` (`it`/`en`) |
| Timezone support | Native via `timeZone` option | Requires the `utc` + `timezone` plugins |
| Relative time ("2h ago") | `Intl.RelativeTimeFormat` — free, but the delta bucket is hand-computed | `relativeTime` plugin, terser |
| Project policy | Ratified: `format.ts:2-4`, `admin-backoffice/spec.md:174` | **Contradicts it** |

The request's *intent* — "every date formatted according to the selected
language" — is already the ratified design. It is violated in exactly three
places, and the fix is three call sites, not a dependency. Adding dayjs would
buy a terser API and easier relative time, at the cost of a runtime dependency,
per-locale plugin wiring, and reversing a documented decision, to do what the
platform does for free.

**The durable fix is not the library — it is enforcement.** A `FormattedDate`
atom plus a test guard means no future component *can* render a raw date again.
That is what actually prevents the reported class of bug. This is recorded as
**Q1** because the user named the library explicitly and deserves the veto.

## Scope

### In Scope

1. **Zero raw dates.** `ApiKeysPanel.vue:29-31` routed through the shared
   formatter; a `FormattedDate` atom as the single render path; a test that
   fails if any template interpolates a raw `*_at` field.
2. **Timezone convention, written down.** Source is UTC; display is the
   viewer's browser zone. Documented in `format.ts` and the spec so the next
   reader does not have to infer it. A visible zone suffix is added **only to
   `expires_at`** in the API-keys table, where "expires 14 Aug, 02:00" is
   actionable and ambiguous. Not to the other eleven sites.
3. **Widen `ConfirmDialog`** — `confirmLabel`, `cancelLabel`, `variant:
   'default' | 'destructive'`; `suppressNextCancel` preserved verbatim; both
   existing call sites migrated to real verbs.
4. **Confirmation on every unguarded action**: avatar-template activate,
   avatar-template delete, avatar-template import, project archive. Each states
   its consequence in the description — activate MUST say which template it
   replaces org-wide.
5. **`window.confirm`/`alert` prohibited** as a normative rule, not a habit.
6. **API-key state, correctly.** Fix `types/api.ts` (`is_active: boolean`,
   `id`, `abilities`), regenerate the client, correct the fixtures — **first**.
   Then a three-state badge (active / expired / revoked) derived from the same
   `active()` predicate the guard uses, and Revoke hidden or disabled once a key
   is no longer active.

### Out of Scope

- **Logout** (`NavBar.vue:29-37`). Deliberate: logout destroys nothing and is
  recoverable in one action. Confirming routine actions trains operators to
  click through dialogs, which erodes the confirmations that matter.
- **Any frontend date work.** There are no dates to format.
- **The API-keys pagination defect** (`:292-294`) — a real bug, recorded here so
  it is not lost, deferred to keep this diff reviewable.
- **A user/organization timezone preference.** No such concept exists; adding
  one is a product decision, not a formatting fix.
- **Type-to-confirm** (typing a name to delete). The user asked for a modal; a
  labelled destructive verb is the proportionate answer.
- **dayjs**, pending Q1.

## Capabilities

### New Capabilities

None. The confirmation contract belongs with the other backoffice UI contracts
rather than fragmenting into its own spec.

### Modified Capabilities

- `admin-backoffice`: (a) `i18n and Locale-Aware Formatting` (`:171`) extended —
  no view may render a date except through the shared formatter, and the
  UTC-source / local-display convention becomes explicit; (b) a **new
  requirement**: every destructive or irreversible action MUST be confirmed
  through `ConfirmDialog` with an action-specific verb and consequence text,
  native `confirm`/`alert` prohibited; (c) the API-keys table MUST render key
  state and MUST NOT offer Revoke on a key that is not active.
- `avatar-templates`: activation, deletion and import MUST be confirmed;
  activation's confirmation MUST name the org-wide replacement it causes.
- `m2m-auth`: the documented `ApiClientResource` shape must match the cast
  types (`is_active` boolean) — the spec phase should confirm whether this is a
  requirement change or purely a `Generated Client Parity` (`:184`) defect.

## Approach

Four slices, ordered so no slice can be written against a lie.

| PR | Content | Why here |
|---|---|---|
| 1 | OpenAPI schema fix + `bun run codegen` + fixture correction | **Must be first.** Every later assertion about `is_active` is meaningless until the type is true |
| 2 | `FormattedDate` atom; three `ApiKeysPanel` sites; timezone convention; raw-date guard test | Independent of confirmations; smallest, safest slice |
| 3 | `ConfirmDialog` widening + both existing call sites migrated | Enabling primitive; no new behaviour, so failures are unambiguous |
| 4 | Confirmations on the four unguarded actions + `ApiKeyStateBadge` + Revoke guard, with the affected tests rewritten to click through the dialog | The behavioural change, on top of a primitive that already works |

## Affected Areas

| Area | Impact | Description |
|---|---|---|
| `backoffice/types/api.ts`, `openapi.json`, api Scramble annotations | Modified | `is_active` boolean; `id`, `abilities` corrected |
| `backoffice/app/components/molecules/ConfirmDialog.vue` | Modified | `confirmLabel`/`cancelLabel`/`variant` |
| `backoffice/app/components/atoms/FormattedDate.vue`, `ApiKeyStateBadge.vue` | New | Single date render path; three-state key badge |
| `backoffice/app/components/organisms/ApiKeysPanel.vue` | Modified | Dates, state column, Revoke guard |
| `backoffice/app/pages/avatar-templates/index.vue` | Modified | Confirmations on activate + delete |
| `backoffice/app/components/organisms/TemplatePortability.vue` | Modified | Confirmation on import |
| `backoffice/app/components/organisms/ProjectForm.vue` | Modified | Confirmation on archive |
| `backoffice/app/utils/format.ts` | Modified | Timezone convention documented |
| `backoffice/i18n/locales/*` | Modified | Confirmation titles, descriptions, verbs; badge labels |
| `openspec/specs/admin-backoffice/spec.md`, `avatar-templates/spec.md` | Modified | Contracts above |

## Risks

| Risk | Likelihood | Mitigation |
|---|---|---|
| `types/api.ts:1121` `is_active: string` + fixture `'true'` means a truthiness check passes CI and lies in production | **Certain if unaddressed** | Schema fix is PR 1, ahead of any badge code. Fixtures corrected in the same commit |
| A badge on `is_active` alone shows "Active" on an expired key | High | Badge derives from the same predicate as `ApiClient::scopeActive` — three states, not two |
| Adding confirmations breaks every test that clicks activate/delete and asserts the call fired synchronously (`avatar-templates-page.spec.ts`, `avatar-template-form.spec.ts`) | **High** | Confined to PR 4; each rewritten to click through the dialog. Test churn is the cost of the feature, not a surprise |
| `ProjectForm.vue` archive shares `saving` state with submit (`:658`, `:667`) — cancelling could strand `saving = true` | Med | Cancel path must reset `saving`; asserted by test |
| Widening `ConfirmDialog` touches both existing call sites and `ConfirmDialog.spec.ts` | Med | New props default to today's strings, so migration is additive |
| A new call site forgets to clear its target on `cancel` and reawakens the `suppressNextCancel` race | Med | The two existing sites are the reference pattern; design must state it as a call-site obligation |
| Changing `format.ts`'s fixed `dateStyle`/`timeStyle` signature is a 12-site refactor, and `format.spec.ts:13-26` asserts against a re-computed `Intl.DateTimeFormat` with those exact options | Med | **Do not change the signature.** `FormattedDate` wraps `formatDate`; the zone suffix is an opt-in extra, not a signature change |

## Rollback Plan

Each slice reverts independently. PR 1 is a type + fixture revert (the runtime
never changed). PR 2 restores raw ISO strings — ugly, not broken. PR 3 is
additive props with today's defaults. PR 4 restores single-click behaviour; no
migrations, no API changes, no persisted state anywhere in this change.

## Dependencies

- None external, **assuming Q1 resolves to `Intl`**. A dayjs decision would add
  a runtime dependency plus per-locale imports and change this line.

## Success Criteria

- [ ] No backoffice view renders a raw ISO string; a test fails if one is added.
- [ ] Switching `it`↔`en` re-renders every date, including the three API-key
      columns, in the new locale's convention.
- [ ] Activating, deleting or importing an avatar template, and archiving a
      project, each require an explicit confirmation whose button names the
      action and whose text names the consequence.
- [ ] Dismissing any confirmation (Cancel, Escape, backdrop) performs nothing
      and leaves no stranded state — including `ProjectForm`'s `saving`.
- [ ] The API-keys table distinguishes active, expired and revoked; after a
      successful revoke the row visibly changes state without a page reload.
- [ ] Revoke cannot be invoked on a key that is not active.
- [ ] `codegen:check` is green with `is_active` typed `boolean`.
- [ ] `window.confirm`/`alert` still appear nowhere in either app.

## Open Questions

**Q1 — dayjs or `Intl`? DECISION DEFERRED, deliberately.** The recommendation
above is `Intl` plus enforcement, with the reasoning and the trade written out.
The user named dayjs explicitly, so the veto is theirs. If dayjs is chosen, the
`it`/`en` locale files must be imported and kept in sync with
`nuxt.config.ts:13-50`, and `format.ts:2-4` plus `admin-backoffice/spec.md:174`
must be formally amended rather than quietly contradicted.

**Q2 — is the frontend's skip-question in scope?**
`frontend/app/pages/interview/[token].vue:81` is irreversible for the candidate,
which argues for confirmation. But it fires mid-interview, where a modal costs
composure and time, and the candidate is not an operator managing records.
Recorded for the spec phase; **not decided here.**

**Q3 — does "always confirm" reach beyond deletion?** This proposal reads the
request as *consequence-driven*, not *verb-driven*: avatar-template activation
is confirmed because its blast radius is org-wide, and logout is not confirmed
because it costs nothing. Confirm that reading, or the rule becomes literal
("only things named delete") and activation drops out.

## Proposal question round

These could not be asked interactively. They need review before the spec phase
freezes an assumption.

1. **dayjs — see Q1.** Assumption: keep `Intl`, fix the three sites, add
   enforcement. Say the word and dayjs goes in instead, with the policy amended
   openly.
2. **Timezone.** Today a key's expiry renders in the reader's browser zone with
   nothing saying so — an operator in Rome and one in New York read the same row
   differently. Assumption: display stays browser-local, the convention gets
   documented, and only `expires_at` gains a visible zone. Is a real per-user
   timezone preference wanted instead? That is a bigger product decision.
3. **Import.** Assumption: a plain confirmation before importing avatar
   templates. Should it instead show *what* is about to be imported (a preview
   of names and counts) before asking? That is more work and materially safer.
4. **Confirmation copy.** Each dialog needs its own consequence sentence in
   `it` and `en` — the activate one is the load-bearing sentence in this change.
   Assumption: drafted here and flagged for review.
