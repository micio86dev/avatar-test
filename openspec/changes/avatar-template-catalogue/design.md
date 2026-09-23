# Design: Avatar Template Catalogue (open item 7.3)

## Technical Approach

Two small, decoupled additions on top of an unchanged core: a **read-only
catalogue endpoint** the backend caches, and a **picker component** the
frontend layers on top of the existing text input. Neither touches
`TemplatePayload`, `ConfigValidator`, the single-active-template invariant,
or any stored row. No database migration exists in this change — every new
thing is either a cached HTTP call result or UI state.

The four catalogue-backed fields (`avatarId`, `voiceId` for HeyGen;
`faceId`, `palId` for Tavus) keep their current `FieldType::Text` shape and
validation exactly as-is. The picker is an **affordance**, not a new source
of truth: whatever the operator ends up with in the field — typed or
picked — is the same plain string `ConfigValidator` and `TemplatePayload`
already know how to handle.

---

## Architecture Decisions

### D1 — One generic catalogue endpoint, not four named ones

**Choice.** `GET /api/avatar-templates/catalogue?provider={heygen|tavus}&resource={voice|avatar|replica}`.

**Rationale.** Mirrors `ProviderFieldSpecs::for(string $provider)`'s
existing pattern — one entry point, provider/resource as data, not four
routes that would each need their own controller method, policy check, and
OpenAPI entry. A new `AvatarProviderCatalogue::fetch(string $provider,
string $resource): array` service class does the per-provider branching
internally, the same shape `ProviderFieldSpecs::for()` already uses for
`heygen()`/`tavus()`.

**Alternatives rejected.** (a) Four named endpoints
(`/catalogue/heygen-voices` etc.) — more surface, no behavioral benefit,
and the field-spec's new `catalogue_resource` hint (D2) already carries
the provider/resource pair, so the frontend always calls the generic
endpoint with values it already has. (b) Reuse `field-specs` itself to
also carry catalogue DATA (not just metadata) — conflates a cheap,
static, always-fresh local response with an expensive, cacheable,
potentially-stale remote one; they need different cache lifetimes and
different failure modes (D3).

### D2 — `FieldSpec` gains one new, optional property: `catalogueResource`

**Choice.** Add `public readonly ?string $catalogueResource = null` to
`FieldSpec`'s constructor, included in `toArray()` as `catalogue_resource`
only when non-null (same "filter out null/false" convention `toArray()`
already applies to `hint_key`/`required`/`options`/`min`/`max`/`step`).
Set it in `ProviderFieldSpecs::heygen()`/`::tavus()` for exactly
`avatarId` (`'avatar'`), `voiceId` (`'voice'`), `faceId` (`'replica'`),
`palId` (`'voice'`). Every other field — including
`ttsExternalVoiceId` — leaves it `null`, which `toArray()` omits entirely.

**Rationale.** `FieldType` stays a closed 4-case enum
(`Text|Number|Select|Checkbox`) describing the STORED VALUE's shape —
adding a fifth case (`Catalogue`) would conflate "how is this value typed
and validated" (unchanged: still text) with "does the backoffice happen to
also offer a picker for it" (new, orthogonal). Keeping `FieldType::Text`
means `ConfigValidator` needs zero changes — it already validates these
four fields correctly today and continues to.

**Alternatives rejected.** (a) A new `FieldType::Catalogue` case —
`ConfigValidator`'s type-check switch would need a new arm that behaves
identically to `Text`, adding a branch that exists only to be a synonym.
(b) A separate, parallel "which fields are catalogue-backed" map living
outside `ProviderFieldSpecs` — reintroduces exactly the "a knob defined in
only one of three places" drift the binding spec's own field-spec
requirement exists to prevent.

### D3 — Cache per `(provider, resource)`, 24h TTL, `Cache::remember`

**Choice.** `AvatarProviderCatalogue::fetch()` wraps its provider HTTP
call in `Cache::remember("avatar-catalogue:{$provider}:{$resource}", now()->addDay(), fn () => ...)`.
On a provider HTTP failure (non-2xx, timeout, connection error), catch and
return `['status' => 'unavailable', 'items' => []]` — never let the
exception propagate, never cache a failure (so the next request retries
rather than serving a cached empty list for 24h).

**Rationale.** Tavus and LiveAvatar are billed, rate-limited APIs; the
form must not call them live on every open. A 24h TTL matches these
catalogues' actual change frequency — Tavus's system voices and HeyGen's
presets are account-level, curated, and do not change intraday. Following
`ProfilePhotoUrlSigner.php:60`'s `Cache::remember` idiom keeps this
consistent with the one existing precedent in this codebase rather than
inventing a second caching pattern.

**Alternatives rejected.** (a) No cache, always live — the rate-limit/cost
risk the proposal already flagged. (b) A queued warm-cache job — adds
infrastructure (a scheduled job, a queue slot) for a resource that is
cheap to fetch on-demand and rarely requested (an admin opens this form
occasionally, not per-candidate). (c) Caching the failure state too — would
turn a transient provider outage into a full day of "no catalogue
available" for an admin who retries five minutes later.

### D4 — `language: null` is exact, never inferred, never a filter-match wildcard

**Choice.** The normalizer reads each provider's own `language` field
verbatim (HeyGen: `language` string; Tavus voices/replicas: no such field
at all → `null`, always). The catalogue endpoint performs NO
language-based filtering server-side — it returns everything for a
`(provider, resource)` pair; the FRONTEND filters client-side by the
`language` the operator picks, and a `null`-language entry never matches
a non-null filter.

**Rationale.** Directly prevents the exact failure this change exists to
catch: a name that looks Italian ("Alessandra") on an English-tagged
voice. Filtering server-side would hide the count/existence of
English-only options from an operator who might actually want one
(e.g., an English-language project); client-side filtering over the full
list keeps that visible while still defaulting the UI to the project-
relevant language.

**Alternatives rejected.** (a) Server-side `?language=it` filtering — adds
a second thing that could disagree with the frontend's own filter logic
for no real benefit, since the full catalogue is small (≤100 items per
provider/resource) and cheap to filter client-side. (b) Defaulting a
`null` Tavus language to `"en"` (since Tavus's catalogue happens to be
100% English today) — a data assumption baked into code that becomes
silently wrong the day Tavus adds a non-English voice with still no
language field.

### D5 — Preview media: embed the provider's URL directly, revisit only if it proves signed/short-lived

**Choice.** `preview_image_url`/`preview_audio_url` in the catalogue
response are the provider's own URLs (Tavus's `thumbnail_image_url`/
`thumbnail_video_url`; HeyGen's `preview_url`), passed through unchanged.
The frontend renders them as plain `<img src>` / `<audio src>`. No BEAI
proxy, no re-upload.

**Rationale.** Both observed this session were plain CDN URLs
(`cdn.replica.tavus.io/...`, no query-string signature visible) — nothing
indicated a short expiry. Proxying adds a new authenticated media-relay
endpoint (and its own caching/security surface) for a problem not yet
confirmed to exist.

**Residual risk, explicitly flagged for apply-time reconfirmation.** If
either provider's preview URL turns out to be signed with a TTL shorter
than the 24h catalogue cache (D3), a preview could 404/403 for the
remainder of the cache window. `sdd-apply` MUST fetch one real preview URL
for each provider immediately before implementing this and check for a
signature/expiry query parameter; if found, cap the catalogue cache TTL to
below the URL's TTL (or switch to embedding provider IDs and re-fetching
preview URLs uncached) rather than proceeding on the assumption stated
here.

**Alternatives rejected.** (a) Proxy every preview through BEAI up front —
speculative infrastructure for an unconfirmed problem, and DESIGN item to
revisit is cheaper than building it now. (b) Strip preview support
entirely — defeats the stated purpose (the user explicitly asked to hear
the voice and see the avatar before picking).

### D6 — Add `combobox` (Command + Popover) from the shadcn-vue registry; no custom component from scratch

**Choice.** Install shadcn-vue's standard `combobox` pattern (composed from
`command` + `popover`, per the shadcn-vue skill/registry) as its own PR
(Approach PR 3), before any feature logic touches it (Approach PR 4).

**Rationale.** This backoffice already standardizes on shadcn-vue
(`components.json`: style `reka-nova`) for `alert-dialog`/`dialog`/
`select`; a hand-rolled combobox would fork that convention for one
feature. Isolating the registry addition into its own PR means a
first-time dependency addition is reviewed on its own, separately from
the feature code that uses it — consistent with this change's own PR
sequencing rationale (Approach table).

**Alternatives rejected.** (a) Build a custom searchable dropdown from
native HTML — reinvents keyboard nav/ARIA the shadcn `Command` primitive
already provides, and diverges from the project's stated UI-kit strategy.
(b) Bundle the registry addition into the same PR as the picker component
— couples a mechanical dependency add to feature-specific review, making
either harder to review in isolation.

### D7 — The picker replaces the CONTROL, not the WRITE PATH; the "clear drops the key" contract is unchanged

**Choice.** For the four catalogue-backed fields,
`AvatarTemplateForm.vue`'s existing `v-else` text-input branch (currently
rendering every non-select/checkbox field, line 202) is replaced by a new
conditional: if `field.catalogue_resource` is present, render the
combobox; otherwise, the existing plain text input, unchanged. The
combobox itself still calls the SAME `onFieldChange()` handler
(570-606) on selection or manual typing — selecting a catalogue item sets
the field's string value exactly as typing it would; clearing it (the
combobox's own "clear" affordance, or deleting typed text) calls the same
`withoutKey()` path (551-555) that already drops the key rather than
submitting an empty string.

**Rationale.** The binding spec's "cleared means absent" contract
(`avatar-templates/spec.md`, "The field-spec-driven backoffice form treats
'cleared' as 'absent', not empty") is a REQUIREMENT, not an implementation
detail — routing the picker through the same `onFieldChange()` function
instead of a parallel write path is what keeps that requirement satisfied
by construction rather than by a second, easy-to-drift implementation.

**Alternatives rejected.** (a) A separate `onCatalogueSelect()` handler
that writes to `draft.value.config` directly — duplicates
`withoutKey()`'s empty-value handling and the reactive update logic,
exactly the kind of second write path the binding spec's validation
contract exists to prevent drifting from the first. (b) Replace the field
entirely with the combobox, remove manual typing — explicitly rejected by
the user's own request ("lasciando anche la possibilità di inserire un
codice manualmente come ora").

---

## File Changes

| File | Action | Description |
|---|---|---|
| `api/app/Support/AvatarTemplates/FieldSpec.php` | Modify | Add `catalogueResource` constructor property + `toArray()` key (D2) |
| `api/app/Support/AvatarTemplates/ProviderFieldSpecs.php` | Modify | Set `catalogueResource` on `avatarId`/`voiceId`/`faceId`/`palId` only (D2) |
| `api/app/Support/AvatarTemplates/AvatarProviderCatalogue.php` | **Create** | `fetch(string $provider, string $resource): array` — per-provider HTTP + normalize + cache (D1, D3, D4) |
| `api/app/Http/Controllers/AvatarTemplateController.php` | Modify | New `catalogue()` action, `GET /api/avatar-templates/catalogue`, admin-only via `AvatarTemplatePolicy`, 422 on unknown provider/resource |
| `api/routes/api.php` | Modify | Register the new route, alongside the existing `avatar-templates/field-specs` route |
| `api/config/interview.php` | **Unchanged** | Reuses existing `heygen.api_key`/`tavus.api_key` — no new config key |
| `backoffice/app/components/ui/combobox/` (or equivalent shadcn output path) | **Create** (registry) | `combobox`/`command`/`popover` added via shadcn-vue CLI (D6) |
| `backoffice/app/composables/useAvatarTemplates.ts` | Modify | New `fetchCatalogue(provider, resource)` function |
| `backoffice/app/components/organisms/AvatarTemplateProviderCombobox.vue` | **Create** | The picker: search, client-side language filter, audio/image preview, manual-entry fallback (D5, D7) |
| `backoffice/app/components/organisms/AvatarTemplateForm.vue` | Modify | New conditional branch for `field.catalogue_resource`, routed through the existing `onFieldChange()` (D7) |
| `backoffice/app/types/avatar-template.ts` | Modify | `FieldSpec.catalogue_resource?: 'voice' \| 'avatar' \| 'replica'`; new `CatalogueEntry` type |
| `backoffice/i18n/locales/{it,en}.json` | Modify | New keys for the picker's empty-state hints (D4-adjacent: "no Italian voices in Tavus's catalogue" etc.) |
| `openspec/specs/avatar-templates/spec.md` | Delta (already written) | See `specs/avatar-templates/spec.md` in this change |

**No database migration.** No new table, no new column, no change to any
stored `avatar_templates` row — the hard constraint from the user (do not
touch the two currently-active production templates) is satisfied by
construction: this change has no code path that writes to that table at
all.

---

## Testing Strategy

Strict TDD (`sdd-init/avatar-test`: `strict_tdd: true`). RED before GREEN
on every row.

| Layer | What to test | Approach |
|---|---|---|
| Unit — FieldSpec | `catalogueResource` included in `toArray()` only when set; omitted (not null) otherwise | `tests/Feature/C14/ProviderFieldSpecTest.php` extends |
| Unit — catalogue normalizer | HeyGen response → `{id,label,language,preview_image_url,preview_audio_url}`; Tavus response → same shape with `language: null` always | New `tests/Unit/Support/AvatarTemplates/AvatarProviderCatalogueTest.php`, `Http::fake()` |
| Unit — cache | Second call within TTL makes no HTTP request; a failed call is not cached (next call retries) | Same test file, `Cache::shouldReceive` or a real cache store + `Http::fake()` call-count assertion |
| Feature — endpoint auth | 401 unauthenticated, 403 operator/viewer, 200 admin, 422 unknown provider/resource | New `tests/Feature/C14/AvatarTemplateCatalogueTest.php`, mirrors `AvatarTemplateApiTest.php`'s existing RBAC pattern |
| Feature — no secret leak | Response body/headers never contain the configured API key substring, on success AND on a simulated provider failure | Same file — assert on the raw JSON string, not just typed fields |
| Feature — provider failure degrades, never 500 | `Http::fake()` a 500/timeout from the provider → endpoint still returns 200 with `status: unavailable`, empty items | Same file |
| Backoffice unit | The combobox renders only for fields with `catalogue_resource`; manual text entry still works for every other field; selecting an item calls the same `onFieldChange` path clearing correctly | `tests/unit/components/organisms/avatar-template-form.spec.ts` extends |
| Backoffice unit | Clearing a catalogue-picked value drops the key (not empty string) — the existing contract test, run against the new control | Same file, mirrors the existing "clearing a text field drops its key" case |
| E2E (Playwright, backoffice) | Opening the form, picking a HeyGen voice, seeing its language badge, saving | New scenario in an existing avatar-template e2e spec |

**Coverage.** Not a correctness-critical zone (scoring, tenant scoping,
candidate state machine) — the project's 85% overall target applies, not
95%.

---

## Migration / Rollout

No database migration. Deploy order: `api` first (new endpoint is
additive, unreachable until the backoffice calls it), `backoffice`
immediately after (per this project's usual submodule-pointer-bump
convention) — there is no intermediate-state risk analogous to
`avatar-language-follows-project`'s D9, because nothing here is a removal
an old client could still reference.

No release-note-worthy behavior change for any existing template: the two
currently-active production templates keep exactly their current `config`
values, unless and until an admin deliberately uses the new picker to
change one.

---

## Open Questions

- [ ] **Preview URL lifetime** — confirmed at `sdd-apply` time per D5's
      residual-risk note, not here. Does not block starting implementation.
- [ ] **Should the picker warn (not block) when an operator selects a
      catalogue voice whose `language` disagrees with the template's
      organization's typical project language?** Out of scope for this
      change — the template has no language of its own
      (`avatar-language-follows-project`), and a per-project mismatch
      warning would need to know which project(s) a template serves,
      which is a many-to-one relationship this change does not touch.
      Noted as a plausible follow-up, not designed in now.

No question blocks `sdd-tasks`.
