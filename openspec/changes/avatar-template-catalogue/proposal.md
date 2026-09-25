# Proposal: Avatar Template Catalogue (open item 7.3)

## Intent

Let an admin **pick** a voice or avatar from a real, live provider catalogue —
searchable, filterable by language where the provider exposes one, with an
audio preview for a voice and an image/thumbnail preview for an avatar/face —
when creating or editing an avatar template. Keep the existing free-text
manual entry as a fallback for every field, unchanged, because neither
provider's catalogue is complete enough to replace it.

This closes `openspec/specs/avatar-templates/spec.md`'s "Out of Scope (C14)"
item: *"An avatar/voice catalogue... Fetching and caching each provider's
inventory is a second integration per provider... Tracked as open item 7.3."*

It is also the direct, structural fix for the accent bug this session
diagnosed by hand: the org's active HeyGen `voice_id` (`c84af063-...`) is
named **"Alessandra - IA"** but the LiveAvatar catalogue tags it
`language: "en"` — an Italian-sounding preset name on an English voice,
discoverable only by querying the provider's own catalogue, which nothing in
BEAI does today. A picker that shows the real `language` tag next to every
option is how an operator catches this before activating a template, not
after a candidate complains.

---

## Verified current state

Read from the code and the live provider accounts on 2026-09-22.

### There is no catalogue anywhere in this codebase

`api/app/Support/AvatarTemplates/FieldSpec.php` (64 lines) and
`FieldType.php` (22 lines, four cases: `Text`, `Number`, `Select`,
`Checkbox`) carry no catalogue field: no preview URL, no language filter, no
fifth case for a combobox. `avatarId`, `voiceId`, `faceId`, `palId`,
`ttsExternalVoiceId` are all plain `FieldType::Text` in
`ProviderFieldSpecs.php`.

`AvatarTemplateForm.vue` (816 lines) renders every field with native HTML
controls only — `<select>`, `<input type="checkbox">`,
`<input type="text"|"number">` — no search, no filter, no media preview
anywhere in the file. The single write path, `onFieldChange()` (570-606),
already treats an empty string as "remove the key" — the contract a picker
must not break.

`useAvatarTemplates.ts` (134 lines) has no function to call a provider
catalogue; only CRUD + field-specs + export/import.

The backoffice's `components/ui/` has `alert-dialog`, `dialog`, `select` —
no `combobox`, `command`, or `popover`. A searchable picker needs adding
those from the shadcn-vue registry (`components.json`: style `reka-nova`,
no custom registry configured).

`AvatarTemplateController::fieldSpecs()` (94-108) never calls a provider;
`GET /api/avatar-templates/field-specs` is pure local metadata. No caching
of any upstream vendor response exists in `api/app` today — the closest
precedent is the single `Cache::remember()` call in
`ProfilePhotoUrlSigner.php:60`.

### What each provider's catalogue actually contains (live-queried this session)

**Tavus** (`https://tavusapi.com`, header `x-api-key`):
- `GET /v2/voices?source=system` → 74 built-in voices. **All English.** No
  `language` field on the resource at all — Tavus's own catalogue cannot be
  filtered by language server-side; it can only be shown as "this is
  everything Tavus offers, and it's English."
- `GET /v2/replicas?verbose=true` → replicas (faces): `replica_id`,
  `replica_name`, `replica_type`, `tags`, `thumbnail_image_url`,
  `thumbnail_video_url`, `default_voice_id`. Visual only, no language tag
  (a face has no language — confirmed, matches the binding spec's "language
  comes from the project, never the template/avatar").
- A persona's `layers.tts.external_voice_id` + `tts_engine`
  (cartesia/elevenlabs/azure) can point at a 3rd-party voice, but **Tavus
  exposes no catalogue endpoint for those at all** — enumerating ElevenLabs'
  or Cartesia's own libraries would be a second, separate integration this
  change does not attempt.

**HeyGen/LiveAvatar** (real base URL is `https://api.liveavatar.com/v1`,
confirmed from `api/app/Services/Provider/HeygenProvider.php` — NOT
`api.heygen.com`; header `X-API-KEY`):
- `GET /v1/voices` → preset voices with a genuine `language` field,
  natively filterable. **All 67 voices in this account are `language:
  "en"`** — zero Italian available from HeyGen's own catalogue today. This
  is the exact voice family the currently-active production `voice_id`
  (`"Alessandra - IA"`) was picked from.
- `GET /v1/avatars` → visual avatars, `preview_url`, `default_voice`.
- 3rd-party voices need a pre-bound secret
  (`POST /v1/secrets` → `POST /v1/voices/third_party`, confirmed against
  the published OpenAPI spec) — no ElevenLabs/Cartesia/Fish/OpenAI/Gemini
  key exists in this account yet (separate, already-deferred decision from
  earlier this session).

**Net effect, stated plainly rather than oversold**: a catalogue picker for
Italian voices will show **zero results from either provider's own preset
catalogue** until a 3rd-party TTS secret is configured. Its value today is
honest discovery (an operator sees the real `language` tag and the real gap,
instead of guessing from a name) plus a reusable UI shape that becomes
useful the moment a 3rd-party voice is bound.

---

## Scope

### In Scope

1. **Catalogue read endpoints** (new, admin-only, mirrors
   `AvatarTemplatePolicy`) — one per provider-resource pair (HeyGen voices,
   HeyGen avatars, Tavus voices, Tavus replicas/faces), or one generic
   `GET /api/avatar-templates/catalogue?provider=&resource=` — decided at
   design. Each returns a normalized
   `{id, label, language: string|null, preview_image_url?, preview_audio_url?}`
   list. Server-side cached (`Cache::remember`, TTL decided at design) so a
   form open never round-trips a paid 3rd-party API live.
2. **Field-spec metadata extension** — mark which of the existing
   `FieldType::Text` fields (`avatarId`, `voiceId`, `faceId`, `palId`) are
   catalogue-backed and which resource type they draw from. The underlying
   stored VALUE stays an unvalidated free-text string exactly as today —
   this only adds a picker affordance, never a new validation rule.
   `ttsExternalVoiceId` stays plain manual text, explicitly labelled as
   "no catalogue available" — no 3rd-party voice inventory exists to back
   it.
3. **Backoffice picker component** — add `combobox`/`command`/`popover`
   from the shadcn-vue registry; build a search + language-filter +
   preview (audio play button for a voice, thumbnail image for an
   avatar/face) + "or type a code manually" control, wired into
   `AvatarTemplateForm.vue` for exactly the four catalogue-backed fields.
   Manual entry remains the literal same text input, never removed —
   the picker is additive UI on top of it, not a replacement of it.
4. Honest empty/partial states in the UI: a language filter that matches
   nothing says so, with a hint (e.g. "Tavus has no Italian voices; use
   manual entry with a third-party voice ID" / "no third-party voice is
   configured for this organization yet") — never a silently empty list
   that reads as a bug.

### Out of Scope (explicit)

- **Changing the two avatar templates currently ACTIVE in production.**
  This change ships no data migration and no seeder touching existing
  `avatar_templates` rows — purely additive read endpoints + UI. Fixing
  those two templates' actual `voiceId`/`external_voice_id` values is a
  separate, manual, deliberate admin action (via this new picker, once
  shipped), not part of this change.
- **Binding a 3rd-party TTS secret** (ElevenLabs/Cartesia/Fish/OpenAI/
  Gemini) into HeyGen/LiveAvatar's `POST /v1/voices/third_party`, or into
  Tavus's `external_voice_id`. No such credential exists yet in either
  account. Once one does, the catalogue's "0 Italian results" gap for
  both providers closes on its own — no further design needed here for
  that path, just a future credential.
- **A catalogue for Tavus's 3rd-party TTS voices.** Tavus has no such
  endpoint; enumerating ElevenLabs'/Cartesia's own libraries would be a
  separate, future integration.
- **Per-organization provider credentials.** Still a single global
  env-sourced key per provider (`config('interview.heygen.api_key')` /
  `config('interview.tavus.api_key')`), matching C14's original explicit
  decision and `LlmCredential`'s platform-level (not per-tenant) precedent.
  Unchanged by this proposal.
- **Any change to `TemplatePayload.php`'s wire mapping.** The catalogue
  only helps PICK a value; how a chosen id reaches HeyGen/Tavus at session
  start is completely unchanged.
- **A `language` key anywhere in stored config.** Unchanged invariant from
  `avatar-language-follows-project`: the avatar's spoken language is
  sourced from the project, never the template. The picker's language
  FILTER is a client-side/query-param convenience over the catalogue
  listing, never a field written into `avatar_templates.config`.

---

## Capabilities

### Modified

- `avatar-templates` — adds catalogue-backed field metadata and two new
  read-only endpoints. Every existing requirement (CRUD, validation,
  single-active invariant, portability, Tavus PAL sync, provider
  immutability) is unchanged.

No new capability domain — this is exactly the deferred "open item 7.3"
inside the existing spec.

---

## Approach

Four PRs, backend-then-frontend, each independently shippable and
individually within the 400-line review budget (chained if any one exceeds
it — `auto-chain` delivery strategy already selected for this change).

| PR | Content | Why here |
|---|---|---|
| 1 | Catalogue read endpoints (Tavus voices/replicas, HeyGen/LiveAvatar voices/avatars), normalized response shape, `Cache::remember`-backed | Pure backend, no UI dependency, unblocks frontend work in parallel |
| 2 | Field-spec metadata: mark catalogue-backed fields + resource type, extend `GET /api/avatar-templates/field-specs` response | Small, additive, no behavior change to existing validation |
| 3 | Backoffice: add `combobox`/`command`/`popover` from the shadcn-vue registry (no app logic yet) | Isolates a first-time UI-kit addition from feature logic |
| 4 | Backoffice: the picker component itself (search, language filter, preview, manual-entry fallback), wired into `AvatarTemplateForm.vue` for the four fields | The feature becomes usable |

---

## Risks

**Rate limits / cost on paid 3rd-party APIs.** Tavus and LiveAvatar are
billed, rate-limited vendor APIs; a naive "call live on every form open"
is a real production risk. Mitigated by `Cache::remember` with a TTL
(design decides the number — these catalogues change rarely, so a long
TTL, e.g. 24h, is the likely answer, confirmed against provider docs at
design).

**Preview media URLs may be signed/expiring.** Not yet confirmed for
either provider's preview fields (`thumbnail_image_url`/
`thumbnail_video_url` for Tavus, `preview_url` for HeyGen avatars). If
signed with a short TTL, embedding them directly at cache time could go
stale before the cached catalogue entry expires. Design must verify actual
URL lifetime before choosing "embed the provider URL directly" vs. "proxy
through BEAI."

**Language filtering is honestly weak today.** Tavus: 0% Italian (no
language field at all). HeyGen: 0% Italian in this account. The UI must
disclose this rather than imply a working multilingual catalogue — see
Scope item 4.

**Two providers, two very different catalogue shapes.** Tavus's voices
carry no language field whatsoever — normalization must map that to an
explicit "unknown language" state, never silently treat it as matching
every filter (which would make an "Italian" filter show 74 English voices
with a blank language badge, worse than showing nothing).

**First-time addition of Command/Popover/Combobox to this backoffice.**
Must compose correctly with the existing 422 field-keyed validation/error-
mapping convention (`admin-backoffice`'s Form Field Validation And Banner
Contract, referenced by the binding spec) — a picker that silently
swallows a validation error on its field would be worse than the plain
text input it replaces.

---

## Dependencies

- `avatar-provider-templates` (C14, archived) — this change extends its
  `ProviderFieldSpecs`/`FieldSpec` mechanism; does not modify its CRUD,
  RBAC, or single-active-template invariants.
- `avatar-language-follows-project` (archived) — this change must not
  regress that: the catalogue's language filter is read-only convenience,
  never a write path for a `language` key.

---

## Success Criteria

1. An admin editing a HeyGen or Tavus avatar template can open a picker
   for `avatarId`/`voiceId`/`faceId`/`palId`, search, filter by language
   where the provider exposes one, preview audio (voice) or image
   (avatar/face), and select — writing the exact same plain string a
   manual entry would have written.
2. Manual free-text entry still works, unchanged, for every field,
   including `ttsExternalVoiceId` and anything outside the four
   catalogue-backed fields.
3. The two currently-active production avatar templates' `config` values
   are byte-identical before and after this change ships — no migration,
   no seeder write to existing rows.
4. Provider catalogue calls are cached server-side; opening the form
   repeatedly does not re-hit Tavus/LiveAvatar on every request.
5. No provider API key ever reaches the browser, in any response body or
   error message.

---

## Open questions

**Q1 — one generic catalogue endpoint or four named ones?** Proceeding
with one generic `GET /api/avatar-templates/catalogue?provider=&resource=`,
matching `ProviderFieldSpecs::for(string $provider)`'s existing pattern.
Confirmed at design.

**Q2 — cache TTL?** Proposing 24h (these catalogues change rarely — Tavus
and HeyGen add/retire preset voices infrequently). Confirmed at design
against each provider's actual documented rate limits.

**Q3 — show Tavus's English-only results when filtering by Italian, or
hide the provider's catalogue entirely?** Proceeding with **show, empty,
with an explanatory hint** ("Tavus has no Italian voices in its catalogue
— use manual entry with a third-party voice ID"), matching Scope item 4.
A silently missing section reads as a bug; an explained empty state reads
as a fact about the provider.
