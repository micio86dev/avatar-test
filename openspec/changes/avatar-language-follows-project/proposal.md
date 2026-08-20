# Proposal: The Avatar's Spoken Language Follows the Project

> **Ratified direction, not up for re-litigation**: the avatar's spoken language follows the
> **PROJECT**. An `AvatarTemplate` may no longer override it. Templates keep controlling avatar
> identity, voice, and video quality. Making the UI follow the template, and making templates
> per-project, were both considered and **rejected**.

## Intent

Four things in one interview carry a language. They do not share a source, and one of them can
silently disagree with the other three.

| Concern | Current source | Verified at |
|---|---|---|
| Frontend UI locale prefix | `project.language` | `EntryLinkMinter.php:72`, `EntryLinkUrlComposer.php:19-21` |
| Opening greeting | `project.language` | `InterviewController.php:178-183` |
| `end_phrase` / `final_phrase` | **`participant.language`** | `InterviewController.php:583, 652, 802` |
| **Avatar's spoken language** | **the org's active `AvatarTemplate`, when it sets one** | `TemplatePayload.php:42, 89-97` |

**How the override happens.** `HeygenProvider::buildSessionTokenBody()` (`:207-221`) does
`array_replace_recursive($platformDefault, $templateFields, $providerOwned)`, and
`avatar_persona.language` is in `TOKEN_FIELD_ALLOWLIST` (`:56-62`). The template beats the platform
default, which is where `$ctx->language` — the project's, threaded at `InterviewController.php:198`
— lives. `TavusProvider` (`:97-101`) runs the same three-layer merge with **no allowlist at all**,
so every mapped field passes through, `language` included.

**Why the template cannot be the source of truth.** `avatar_templates` has an `organization_id` and
**no `project_id`** (`2026_08_01_000001_create_avatar_templates_table.php:22-70`), plus a partial
unique index `avatar_templates_one_active_per_org`. `ActiveTemplateResolver::resolve()` is
`AvatarTemplate::where('is_active', true)->first()`, org-scoped by `TenantScoped`. **At most one
active template per organization**, against a per-project `project.language`. An org running one
Italian and one English project cannot express that through a template. The `avatar-templates` spec
already names this as a deferred idea (`spec.md:496-501`, open item 7.2) — this change makes it
unnecessary rather than pending.

**It also breaks the avatar internally.** Its scripted lines — opening greeting (`OpeningTextComposer`),
`end_phrase`/`final_phrase` — are composed elsewhere and handed to it already written. Configuring
its persona for one language while feeding it copy in another is incoherent regardless of the UI.

**Binding constraint** (CLAUDE.md): *"i18n mandatory it/en: UI, TTS questions and evaluation must be
consistent with the project language."*

## Verified findings that change the shape of the fix

Read from the code on 2026-08-20. Four items were **not** in the framing and matter.

### F1 — The divergence is LIVE for demo-provisioned orgs, not latent

The hotfix comments (`HeygenProvider.php:180-183`, `TavusProvider.php:79-84`) claim *"No org has one
today."* That is no longer true of any org provisioned through demo data:
`DemoWriter::writeAvatarTemplates()` (`:143-163`) creates `beai-demo-heygen-it` with
`is_active => ! $alreadyActive` **and** `'language' => $identity['heygen']['language']`.
`ProjectCompetenciesTest.php:75-76` asserts exactly one active template. So a demo org's avatar
speaks the template's language while its UI and greeting follow the project.

**Limit of verification**: no production database was queried and none can be from here. What is
established is that the code *supports and actively seeds* an active template with a language. The
population of real tenants in that state is unknown and must be checked before apply.

### F2 — Dropping the `language` `FieldSpec` breaks demo seeding, loudly

`ConfigValidator` is entirely spec-driven and reports any key absent from `ProviderFieldSpecs` as
`unknown` (`ConfigValidator.php:44-48`). `DemoWriter.php:193-201` throws `RuntimeException` on any
validator error. Remove the `FieldSpec` without also removing `'language'` from **both** demo
definitions (`:152`, `:172`) and `demo:provision` dies at seed time. This is a hard in-scope
dependency, not a follow-up.

### F3 — Tavus's `language` is at the wrong path *and* has no platform default

Two separate problems on one field.

- `platformDefaultConversationFields()` (`TavusProvider.php:159-176`) supplies only `replica_id` and
  `persona_id`. The template is Tavus's **only** language source. Removing it without adding a
  platform default drops Tavus's language entirely — a regression, not a fix.
- The demonstrated-working demo call puts it at **`properties.language`**
  (`legacy-demo/src/pages/api/interview/start.ts:311-312`, `language: 'italian'`).
  `TemplatePayload::tavus()` emits it **top-level** (`:92`). One of the two is wrong on the wire, and
  the `avatar-templates` spec ratifies only the *vocabulary* translation (`spec.md:314-317, 339-343`),
  never the path. The new platform default must be placed against the demo-proven path, and the
  `it → italian` map needs a home outside `TemplatePayload::tavus()`.

### F4 — `end_phrase` violates a ratified spec today

`interview-session/spec.md:278` requires the phrases *"localized to the **project** language"*, with
scenarios keyed on `GIVEN a project with language = 'it'/'en'` (`:302-315`). The code passes
`$participant->language` (`InterviewController.php:583, 652`). Worse, `participant.language` is
third-party input accepted as `['nullable','string','max:10']` with **no** `supported_locales`
check and **no** default from the project (`M2m/ParticipantController.php:53, 69`). A caller can
post `language: "fr"` on an `it` project and the closing phrases silently fall back to English while
the avatar, UI, and greeting speak Italian.

## Scope

### In Scope

| # | Deliverable |
|---|---|
| 1 | `TemplatePayload::heygen()` stops emitting `avatar_persona.language` (`:42`) |
| 2 | `TemplatePayload::tavus()` stops emitting `language` (`:89-97`) |
| 3 | `HeygenProvider::TOKEN_FIELD_ALLOWLIST` drops `avatar_persona.language` (`:59`) — see D1 |
| 4 | **Add** the project language to `TavusProvider::platformDefaultConversationFields()`, at the demo-proven path, sourced from `$ctx->language`; relocate the `it → italian` map — see D2 |
| 5 | `ProviderFieldSpecs` drops the `language` `FieldSpec` from **both** `heygen()` (`:61`) and `tavus()` (`:84`), retiring `LANGUAGES` (`:36`) if unused |
| 6 | `DemoWriter` demo definitions drop `'language'` (`:152`, `:172`); rename/redescribe `beai-demo-tavus-en` whose name encodes a language it no longer sets |
| 7 | Backoffice i18n: remove `avatar_templates.field.language` and `avatar_templates.hint.language` from `it.json` / `en.json` (`:606`, `:650` in both) |
| 8 | Existing persisted `config.language` rows — see D3 |
| 9 | `end_phrase` / `final_phrase` source `participant.language` → `project.language` — see D4 |
| 10 | Delta specs: `avatar-templates` + `interview-session` (see Capabilities); regenerate `openapi.json` and both typed clients if the field-spec response shape changes |

### Out of Scope

- **Per-project avatar templates.** Rejected. Open item 7.2 in `avatar-templates/spec.md:496-501`
  is answered by this change, not implemented by it.
- **Making the UI follow the template.** Rejected.
- **The future of the `participants.language` column** — whether a per-candidate language override
  should exist at all, and whether M2M input should be locale-validated. Deliverable 9 is a
  one-line spec-conformance fix, not that decision. See D4.
- **`interview-continuous-flow`** — independent and untouched.
- **Template-carried persona/greeting** (`avatar-templates/spec.md:523`) — unrelated surface.
- Voice, avatar identity, video quality: templates keep all of it.

## Decisions

### D1 — The allowlist entry: kept as a statement of intent, not as a guard *(taken)*

After deliverable 1, `TemplatePayload::heygen()` never emits `avatar_persona.language`, so
`allowlistedTemplateFields()` (`:289-309`) has nothing to filter. Removing the allowlist entry is
**redundant defence in depth and should be described as such** — do not let it be reviewed as
load-bearing.

Two reasons to remove it anyway. It is a **statement of intent**: the allowlist is the readable
inventory of what a template may say to HeyGen, and leaving `language` there documents a permission
that no longer exists. And the reverse ordering does not hold: the allowlist alone would **not** be
sufficient, because it is union'd with `config('interview.heygen.extra_token_fields', [])`
(`:293-296`), so an env change could re-open the field. The load-bearing fix is in `TemplatePayload`.

### D2 — Where Tavus's language goes, and who maps it *(recommendation; design confirms)*

Recommend `properties.language`, matching `start.ts:311-312`, the only demonstrated-working Tavus
call BEAI has. The `it → italian` map moves next to the platform default that now owns the concern —
it is a **provider vocabulary** concern, not a template-mapping one, and `TemplatePayload` should
stop knowing about language entirely.

**This is a wire-contract change on a live path.** `TemplatePayload::tavus()`'s top-level `language`
is currently ratified only by our own tests. Confirm the path before apply; if Tavus accepts both,
prefer the demo-proven one and say so in the code.

### D3 — Persisted `config.language`: strip by migration *(recommendation)*

Ignoring in place is cheaper but leaves a trap. Because `ConfigValidator` reports unknown keys
(F2), a template whose config still carries `language` becomes **unsavable and unimportable**: the
next operator edit 422s on a key they cannot see in a form that no longer renders it, and
`AvatarTemplatePortabilityController.php:127` refuses the same document on import.

**Recommend a data migration that strips the `language` key from every `avatar_templates.config`
row**, both providers, active and inactive. It is a JSONB key delete, reversible by doing nothing,
and it makes "the operator's saved settings still validate" true on the day this ships.

### D4 — Fold in `end_phrase`, split out the column *(recommendation — needs sign-off)*

**View: fold in the source swap; split out everything else.** F4 is not a second inconsistency to
weigh — it is the code contradicting a ratified spec (`interview-session/spec.md:278, 302-315`) on
exactly the invariant this change exists to establish. The fix is one argument at two call sites
(`InterviewController.php:583, 652`). Shipping "the avatar speaks the project's language" while its
closing phrase still resolves from unvalidated third-party input would re-create the defect one
field over.

What is **not** folded in: whether `participants.language` should exist, whether M2M should validate
it against `supported_locales`, and what `EntryLinkMinter`'s `$lang` override argument (`:72`) is
for. Those need a product decision about per-candidate language, and they are their own change.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- **`avatar-templates`** — `language` leaves the HeyGen and Tavus field specs; the Tavus
  vocabulary-translation requirement and its scenario (`spec.md:314-317, 339-343`) move to the
  platform default or are removed; the per-project-override deferral (`:496-501`) is answered.
- **`interview-session`** — `:1170-1171` must stop listing `avatar_persona.language` among
  template-merged fields; `:1296-1302` ("a template overrides the platform default per key") needs a
  language-specific counter-scenario; `:1262-1264` gains Tavus's language platform default. `:897`,
  `:911` and `:1304-1309` stay **true and unchanged** — language still rides `/sessions/token`, still
  from the project. If D4 is accepted, `:278` and `:302-315` become satisfied rather than amended.

## Approach

Cut the field at the mapper, not at the merge. `TemplatePayload` stops knowing that language exists;
every provider then has exactly one language source, the platform default fed from
`$ctx->language ← $project->language`. The operator-facing surface (`ProviderFieldSpecs`, i18n keys,
demo fixtures, persisted rows) is retired in the same change so no control survives that an operator
can set and not hear.

Strict TDD is active (`openspec/config.yaml: strict_tdd: true`): each behaviour change lands RED
first. No tasks are written here.

### Changed-line forecast

```
400-line budget risk: Medium
Chained PRs recommended: Yes
Decision needed before apply: Yes
```

Production code is small; tests, specs, and fixtures are not. `Decision needed before apply` is
**Yes** for D2 (wire path), D3 (migration), and D4 (scope).

## Affected Areas

| Area | Impact | Description |
|---|---|---|
| `api/app/Support/AvatarTemplates/TemplatePayload.php:42, 89-97` | Modified | Stops emitting language for both providers |
| `api/app/Support/AvatarTemplates/ProviderFieldSpecs.php:36, 61, 84` | Modified | `language` `FieldSpec` removed from both providers |
| `api/app/Services/Provider/HeygenProvider.php:59` | Modified | Allowlist entry removed (D1) |
| `api/app/Services/Provider/TavusProvider.php:159-176` | Modified | Project language **added** to the platform default (D2) |
| `api/app/Support/Demo/DemoWriter.php:143-188` | Modified | Demo configs drop `language`; `tavus-en` renamed (F2) |
| `api/database/migrations/` | **New** | Strip `config.language` from persisted rows (D3) |
| `api/app/Http/Controllers/Candidate/InterviewController.php:583, 652` | Modified | Phrase source → `$project->language` (D4) |
| `api/app/Support/AvatarTemplates/ConfigValidator.php` | **Unchanged** | Spec-driven; inherits the removal automatically |
| `api/tests/{Feature/C14,Feature/C8,Unit/C7a,Feature/Demo}/…` | Modified | `ProviderFieldSpecTest.php:88-96`, payload and demo tests pin `language`; RED first |
| `backoffice/i18n/locales/{it,en}.json:606, 650` | Modified | Two key pairs removed |
| `backoffice/openapi.json` + typed client | Regenerated | Only if the field-spec response shape is published |
| `openspec/specs/{avatar-templates,interview-session}/spec.md` | Delta | See Capabilities |

## Risks

| Risk | Likelihood | Mitigation |
|---|---|---|
| 1. Tavus loses its language entirely if deliverable 4 is not shipped **with** deliverable 2 | **Certain if split** | Deliverables 2 and 4 must land in the same PR. Assert Tavus language presence in the same test file that asserts its absence from the template payload |
| 2. `demo:provision` throws at seed time (F2) | **Certain if 5 ships without 6** | Same PR; `ProjectCompetenciesTest.php:79` is the existing guard and will fail RED |
| 3. `properties.language` vs top-level `language` is settled from the demo, not from Tavus docs (F3) | **Med-High** | Confirm against the live contract before apply; a wrong path is silently ignored by Tavus — the exact failure the code comments already warn about |
| 4. Existing templates become unsavable if D3 is declined | High if declined | Adopt D3, or accept and document the trap explicitly |
| 5. A tenant deliberately using the template to speak a different language loses that ability | Low | Cannot be verified without production data (F1). It is a ratified product decision, not a regression — surface it in release notes |
| 6. Amending ratified spec blocks needs sign-off, not a silent overwrite | Certain | Explicit delta specs in `sdd-spec` |
| 7. D4 changes a live response field on `/start`; the frontend treats absent/empty phrases as terminal (`interview-session/spec.md:295-296`) | Low | Both sources resolve through the same fallback; assert non-empty for a participant whose language is null, unsupported, and divergent |
| 8. Multi-repo drift: `api` and `backoffice` must ship together or the form renders a key with no translation | Med | Git Flow ×4 — paired `feature/*` branches, wrapper pins both submodule commits in one bump. Merge `api` first, `backoffice` immediately after |

## Rollback Plan

**Code**: three small, disjoint edits per provider. Revert the PR and the previous merge order
returns; the platform default already carried the project's language for HeyGen before this change,
so a HeyGen rollback is behaviour-neutral for any org with no active template.

**Data**: the D3 migration deletes a JSONB key. Its `down()` **cannot restore the values** — write it
as a no-op and say so in the migration docblock. If restoring is required, take a
`avatar_templates(id, config)` snapshot in the same PR before the delete, or defer D3 to a second PR
that ships after the code has proven stable.

**Order matters**: roll back the migration PR independently of the code PR. Reverting the code while
the rows are already stripped is safe (the field spec is back, the key is simply unset). Reverting
the migration while the code is live is not restorable.

## Dependencies

- C7a, C8, C14 delivered. `liveavatar-contract-alignment` archived (2026-08-20).
- D2 needs the Tavus conversation-body language path confirmed (F3).
- D3 and D4 need sign-off before apply.
- Coordinated `api` + `backoffice` submodule release (Risk 8).

## Success Criteria

- [ ] For **both** providers, the outbound body's language equals `project.language` — proven with an
      active template that sets a **different** language, asserting the template does not win.
- [ ] Two projects of the **same organization** with `language = 'it'` and `'en'` produce two
      different avatar languages under the same active template.
- [ ] `TemplatePayload::heygen()` / `::tavus()` emit no language key for any config, including one
      that still contains `language`.
- [ ] Tavus still sends a language on every `/start` — the platform default replaced the template,
      it did not remove the field.
- [ ] The backoffice avatar-template form renders **no** language control for either provider, and
      no untranslated key appears.
- [ ] `demo:provision` completes; every seeded template validates clean.
- [ ] An existing template whose stored config carried `language` can still be edited, saved, and
      re-imported after the migration.
- [ ] `end_phrase` / `final_phrase` match `project.language` even when `participant.language` is
      null, unsupported, or different (D4).
- [ ] No test asserts a template-sourced language for either provider.

## Proposal Question Round

Not asked interactively — this executor could not reach the user. Each item is a product decision
`sdd-spec` and `sdd-design` must **not** answer alone.

1. **D4 — fold in `end_phrase`, or split it?** The recommendation is fold in the one-line source
   swap and split the column's future. Confirm, or keep this change strictly avatar-only and accept
   that one language field still resolves from unvalidated third-party input.
2. **D3 — strip the stored `language` values by migration, or ignore in place?** Ignoring leaves
   existing templates unsavable (F2/D3). The recommendation is to strip, with a non-restorable
   `down()`.
3. **F1 — does any real tenant have an active avatar template with a language set?** Cannot be
   answered from the repo. If yes, this change alters a live avatar's spoken language on deploy and
   needs a release note, not a silent ship.
4. **D2 — confirm Tavus's language path.** The demo proves `properties.language`; our mapper sends
   it top-level. If neither can be confirmed against Tavus documentation before apply, is shipping
   the demo-proven path acceptable?
5. **Is `participants.language` worth keeping at all?** BEAI holds no candidate contact data
   (ratified decision #8) and the calling system owns scheduling (#5). If the project owns the
   interview language end to end, the column may be dead weight — which is the split-out change in
   D4, and worth scheduling rather than leaving open.
