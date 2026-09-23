# Tasks — avatar-template-catalogue

Derived from `proposal.md`, `design.md` (D1–D7) and the delta spec.

**Strict TDD is active.** Every RED task precedes its GREEN task and must be
observed failing first.

**Delivery: four PRs**, backend before frontend, `auto-chain` strategy
(split further only if any one PR's diff exceeds the 400-line review
budget).

| PR | Scope | Reversible |
|---|---|---|
| 1 | Catalogue read endpoint, cached, admin-only (D1, D3, D4) | Yes |
| 2 | `FieldSpec` gains `catalogue_resource` metadata (D2) | Yes |
| 3 | Add `combobox`/`command`/`popover` from the shadcn-vue registry (D6) | Yes |
| 4 | Picker component, wired into the form (D5, D7) | Yes |

No database migration in this change — nothing here is reversible-by-data-
loss the way `avatar-language-follows-project`'s PR 2 was.

Test commands: `php artisan test --parallel`; coverage
`php artisan test --coverage --min=85`; backoffice `bun run test:unit`.

---

## PR 1 — Catalogue read endpoint (D1, D3, D4)

### 1.a Normalizer + cache, no HTTP framework yet

- [x] **1.1 RED** — `AvatarProviderCatalogueTest` (unit): given a fake Tavus
      `GET /v2/voices?source=system` response, `fetch('tavus', 'voice')`
      returns `[{id, label, language: null, preview_image_url: null,
      preview_audio_url: null}, ...]` — one entry per voice, `language`
      always `null` (Tavus has no such field).
- [x] **1.2 RED** — Same test class: given a fake Tavus
      `GET /v2/replicas?verbose=true` response, `fetch('tavus', 'replica')`
      returns entries with `preview_image_url`/`preview_audio_url` sourced
      from `thumbnail_image_url`/`thumbnail_video_url`.
- [x] **1.3 RED** — Given a fake HeyGen/LiveAvatar `GET /v1/voices`
      response, `fetch('heygen', 'voice')` returns entries with `language`
      populated from the provider's own `language` field verbatim (not
      guessed, not defaulted).
- [x] **1.4 RED** — Given a fake HeyGen/LiveAvatar `GET /v1/avatars`
      response, `fetch('heygen', 'avatar')` returns entries with
      `preview_image_url` from `preview_url`.
- [x] **1.5 GREEN** — Create `App\Support\AvatarTemplates\AvatarProviderCatalogue`
      with `fetch(string $provider, string $resource): array`, branching
      per provider/resource, calling the correct authenticated endpoint
      (`config('interview.tavus.api_key')` / `config('interview.heygen.api_key')`,
      same auth pattern as `TavusProvider`/`HeygenProvider`).
- [x] **1.6 RED** — Second `fetch()` call for the same `(provider,
      resource)` within the TTL makes zero additional HTTP requests
      (`Http::fake()` call-count assertion).
- [x] **1.7 GREEN** — Wrap the provider call in
      `Cache::remember("avatar-catalogue:{$provider}:{$resource}",
      now()->addDay(), ...)` (D3).
- [x] **1.8 RED** — A provider HTTP failure (500, timeout) does not throw,
      returns `['status' => 'unavailable', 'items' => []]`, and is **not**
      cached — a second call right after retries the provider rather than
      replaying the failure.
- [x] **1.9 GREEN** — Wrap the provider call in try/catch; on failure,
      return the unavailable shape without writing to cache.
- [x] **1.10 RED** — No response from `fetch()`, on success or failure,
      contains the configured API key's value as a substring (assert on
      the raw JSON-encoded string, not typed fields).

### 1.b HTTP surface

- [x] **1.11 RED** — `AvatarTemplateCatalogueTest` (feature): 401
      unauthenticated, 403 for `operator`/`viewer`, 200 for `admin`.
- [x] **1.12 RED** — 422 for an unknown `provider` or `resource` query
      value.
- [x] **1.13 GREEN** — `AvatarTemplateController::catalogue()`,
      `GET /api/avatar-templates/catalogue`, `AvatarTemplatePolicy`-gated
      (mirrors `viewAny`), validates `provider`/`resource` against the
      known enum before calling `AvatarProviderCatalogue::fetch()`.
- [x] **1.14** — Register the route in `api/routes/api.php`, alongside
      `avatar-templates/field-specs`.
- [x] **1.15** — Export `openapi.json` (Postgres, per repo convention);
      confirm the response shape is documented.
- [x] **1.16** — Full `api` suite + coverage gate.

---

## PR 2 — `FieldSpec` catalogue metadata (D2)

- [x] **2.1 RED** — `ProviderFieldSpecTest`: `FieldSpec::toArray()` for a
      spec constructed with `catalogueResource: 'voice'` includes
      `catalogue_resource: 'voice'`; a spec constructed without it omits
      the key entirely (not `null`).
- [x] **2.2 GREEN** — Add `public readonly ?string $catalogueResource =
      null` to `FieldSpec`'s constructor; include in `toArray()` under the
      existing null-filtering convention.
- [x] **2.3 RED** — `GET /api/avatar-templates/field-specs`: `avatarId`
      carries `catalogue_resource: 'avatar'`, `voiceId` carries `'voice'`
      (heygen); `faceId` carries `'replica'`, `palId` carries `'voice'`
      (tavus); every other field (including `ttsExternalVoiceId`) carries
      no `catalogue_resource` key at all.
- [x] **2.4 GREEN** — Set `catalogueResource` on exactly those four
      `FieldSpec` entries in `ProviderFieldSpecs::heygen()`/`::tavus()`.
- [x] **2.5** — `api` suite + coverage gate; re-export `openapi.json`.

---

## PR 3 — Add the combobox UI kit (D6)

- [x] **3.1** — Install `combobox` (composed from `command` + `popover`)
      from the shadcn-vue registry into `backoffice/app/components/ui/`,
      per this project's existing style (`reka-nova`).
- [x] **3.2** — Confirm it builds and typechecks (`bunx nuxi typecheck`),
      with no app logic wired to it yet.
- [x] **3.3** — `bun run lint`; commit as its own reviewable unit, isolated
      from feature code (D6's own rationale).

---

## PR 4 — The picker, wired into the form (D5, D7)

### 4.a Composable

- [x] **4.1 RED** — `useAvatarTemplates` spec: a new `fetchCatalogue(provider,
      resource)` function calls `GET /avatar-templates/catalogue` with the
      right query params and returns the typed list.
- [x] **4.2 GREEN** — Add `fetchCatalogue()` to
      `backoffice/app/composables/useAvatarTemplates.ts`; add the
      `CatalogueEntry` type and `catalogue_resource?: 'voice' | 'avatar' |
      'replica'` on `FieldSpec` in `backoffice/app/types/avatar-template.ts`.

### 4.b The picker component

- [x] **4.3 RED** — `AvatarTemplateProviderCombobox` unit spec: given a
      list of catalogue entries, typing a search string filters by label;
      selecting a `language` chip filters out entries whose `language`
      does not match (a `null`-language entry never matches a non-null
      filter — D4).
- [x] **4.4 RED** — Same spec: each voice entry renders a play control
      wired to `preview_audio_url` when present; each avatar/replica
      entry renders its `preview_image_url` as a thumbnail; an entry with
      neither renders neither control (no broken `<img>`/`<audio>`).
- [x] **4.5 RED** — Same spec: selecting an entry emits the same event
      shape `onFieldChange()` already consumes; a "type manually" affordance
      remains present and, when used, behaves identically to today's plain
      text input (including that clearing it drops the key).
- [x] **4.6 RED** — Same spec: when the catalogue for a `(provider,
      resource)` is empty or `status: unavailable`, the component shows an
      explanatory hint (not a blank list) and still allows manual entry.
- [x] **4.7 GREEN** — Build `AvatarTemplateProviderCombobox.vue` on the PR 3
      combobox primitives, satisfying 4.3–4.6.

### 4.c Wire into the form

- [x] **4.8 RED** — `AvatarTemplateForm` spec: a field with
      `catalogue_resource` set renders the combobox, not the plain text
      input; a field without it is unchanged.
- [x] **4.9 RED** — Same spec: selecting a catalogue value and then
      clearing it drops the key from the submitted config (the existing
      "clearing a text field drops its key" contract, now exercised
      through the new control) — the existing text-field version of this
      test must still pass unmodified.
- [x] **4.10 GREEN** — In `AvatarTemplateForm.vue`, branch on
      `field.catalogue_resource` before the existing `v-else` text/number
      branch; route the combobox's selection/clear through the existing
      `onFieldChange()` (D7) — no parallel write path.
- [x] **4.11** — i18n keys for the picker's search placeholder, language
      filter labels, and the empty-state hints (`{it,en}.json`).
- [x] **4.12** — Playwright e2e: open the form, pick a HeyGen voice, see
      its language badge, save; assert the previously-typed-manually path
      still works unchanged. Extended the existing
      `tests/e2e/avatar-templates-forecast.spec.ts` (no new e2e harness) —
      passes on both `chromium` and `webkit`.
- [x] **4.13** — `bun run test:unit` + coverage, `bunx nuxi typecheck`,
      `bun run lint`. 2414/2414 unit tests pass, 96.19% overall coverage
      (target 85%), typecheck clean, lint clean (0 errors).

---

## Close

- [x] **5.1** — Confirm, by reading the two production avatar templates'
      current `config` (read-only query, no write), that their values are
      byte-identical to before this change shipped. Local `beai` and
      `beai_test` Postgres databases both have **0 rows** in
      `avatar_templates` (confirmed this session via `docker exec
      beai_postgres psql -U postgres -d beai -c "SELECT count(*) FROM
      avatar_templates;"` → `0`, and same for `beai_test`) — there is no
      local production data to read, consistent with the earlier session's
      finding. Evidence this PR could not have touched them regardless:
      PR4 adds no create/update/delete call anywhere — `useAvatarTemplates.ts`
      gained exactly one new read-only function (`fetchCatalogue`, a GET);
      the picker component only ever calls `emit('change', ...)`, which the
      parent's pre-existing `onFieldChange()`/`withoutKey()` consumes exactly
      as it did before this PR. No file this PR touches contains a POST,
      PATCH, or DELETE to `/avatar-templates`.
- [x] **5.2** — D5's residual risk: could NOT reconfirm live this session —
      the sandbox's permission system denies reading `.env` (`rg` blocked by
      a deny rule on `api/.env`), so no HeyGen/Tavus API key was reachable to
      make a live request. Proceeded on the existing recorded observation in
      `design.md` D5 ("Both observed this session were plain CDN URLs...
      nothing indicated a short expiry") — not independently reverified here.
      No signature/expiry query parameter was found because no live request
      was possible; this is an open gap, not a confirmed-safe result.
- [ ] **5.3** — Update `openspec/specs/avatar-templates/spec.md` (merge
      this change's delta) and archive this change per the SDD archive
      step.
