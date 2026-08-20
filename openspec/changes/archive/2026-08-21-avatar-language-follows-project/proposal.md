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

### F1 — Three ratified-looking comments state a fact about the code that is false

**Read this one first. It is the finding most likely to cause the next defect.**

Three places assert that no organization has an active `AvatarTemplate`:

| Location | Text |
|---|---|
| `HeygenProvider.php:182` | *"`AvatarTemplate`. **No org has one today**, so `$templateFields` was `[]`…"* |
| `TavusProvider.php:82` | *"active `AvatarTemplate` (`TemplatePayload::tavus()`). **No org has one** today…"* |
| `interview-session/spec.md:1278` | *"identity came ONLY from **a template no organization had**."* |

Demo provisioning made all three false. `DemoWriter::writeAvatarTemplates()` (`:143-163`) creates
`beai-demo-heygen-it` with `is_active => ! $alreadyActive` **and**
`'language' => $identity['heygen']['language']`; `ProjectCompetenciesTest.php:75-76` asserts exactly
one active template exists. A demo org's avatar therefore speaks the template's language while its
UI and greeting follow the project — the divergence is **live, not latent**.

**Why this is a deliverable and not a footnote.** A comment that reads as ratified fact and is not
one is precisely the failure mode that produced today's `pause_every_n_competencies`
"no backend column exists" defect in a separate change. The next reader of `buildSessionTokenBody()`
will reason from `:182` and conclude that the template path is dead code. Correcting these three
statements is deliverable 11.

**Limit of verification**: no production database was queried and none is reachable from here. What
is established is that the code *supports and actively seeds* an active template carrying a
language. The population of real tenants in that state remains unknown (open question 1).

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
| 3 | `HeygenProvider::TOKEN_FIELD_ALLOWLIST` drops `avatar_persona.language` (`:59`) — D1 |
| 4 | **Add** the project language to `TavusProvider::platformDefaultConversationFields()`, sourced from `$ctx->language`, **at `properties.language`** — the demo-proven path, not the current top-level one; relocate the `it → italian` map — **D2, RATIFIED** |
| 5 | `ProviderFieldSpecs` drops the `language` `FieldSpec` from **both** `heygen()` (`:61`) and `tavus()` (`:84`), retiring `LANGUAGES` (`:36`) if unused |
| 6 | `DemoWriter` demo definitions drop `'language'` (`:152`, `:172`); rename/redescribe `beai-demo-tavus-en` whose name encodes a language it no longer sets |
| 7 | Backoffice i18n: remove `avatar_templates.field.language` and `avatar_templates.hint.language` from `it.json` / `en.json` (`:606`, `:650` in both) |
| 8 | **Data migration** stripping `language` from every `avatar_templates.config` row, with a documented non-restorable `down()` — **D3, RATIFIED** |
| 9 | `end_phrase` / `final_phrase` source `participant.language` → project language, at both `buildSuccessResponse(...)` call sites (`:583`, `:652`) — **D4, RATIFIED** |
| 10 | Delta specs: `avatar-templates` + `interview-session` (see Capabilities); regenerate `openapi.json` and both typed clients if the field-spec response shape changes |
| 11 | **Correct the three false "no org has an active template" statements** — `HeygenProvider.php:182`, `TavusProvider.php:82`, and `interview-session/spec.md:1278` (F1) |

### Out of Scope

- **Per-project avatar templates.** Rejected. Open item 7.2 in `avatar-templates/spec.md:496-501`
  is answered by this change, not implemented by it.
- **Making the UI follow the template.** Rejected.
- **The future of the `participants.language` column.** Deliverable 9 swaps the *source* of two
  response fields and nothing else. Three questions were examined, judged out of scope, and are
  **deliberately left open** — they were not overlooked:
  1. whether a per-candidate language override should exist at all;
  2. whether `M2m/ParticipantController.php:53` should validate `language` against
     `supported_locales` and default it from the project;
  3. what `EntryLinkMinter`'s `$lang` override argument (`:72`) is for.

  Each needs a product decision about per-candidate language. See D4.
- **`interview-continuous-flow`** — independent and untouched.
- **Template-carried persona/greeting** (`avatar-templates/spec.md:523`) — unrelated surface.
- Voice, avatar identity, video quality: templates keep all of it.

## Decisions

**All four are settled.** D1 was taken in the proposal; D2, D3 and D4 were **RATIFIED by the user**
after the first question round. None is open to `sdd-spec` or `sdd-design`.

### D1 — The allowlist entry: kept as a statement of intent, not as a guard *(RATIFIED)*

After deliverable 1, `TemplatePayload::heygen()` never emits `avatar_persona.language`, so
`allowlistedTemplateFields()` (`:289-309`) has nothing to filter. Removing the allowlist entry is
**redundant defence in depth and should be described as such** — do not let it be reviewed as
load-bearing.

Two reasons to remove it anyway. It is a **statement of intent**: the allowlist is the readable
inventory of what a template may say to HeyGen, and leaving `language` there documents a permission
that no longer exists. And the reverse ordering does not hold: the allowlist alone would **not** be
sufficient, because it is union'd with `config('interview.heygen.extra_token_fields', [])`
(`:293-296`), so an env change could re-open the field. The load-bearing fix is in `TemplatePayload`.

### D2 — Fix the Tavus language PATH as well as its source *(RATIFIED)*

`TemplatePayload::tavus():92` emits `language` **top-level**. The demonstrated-working demo call puts
it at **`properties.language`** (`legacy-demo/src/pages/api/interview/start.ts:311-312`). Deliverable
4 places the new platform default at the demo-proven path.

**This is the strongest argument in the change, and it must not be buried.** If the path is wrong,
Tavus accepts the field and ignores it. Moving the *source* from template to project would then
change **nothing observable on the wire** — the avatar would keep speaking whatever the Tavus
persona defaults to, in every project, in both languages. Without the path fix, this change is a
**no-op for Tavus while reading as a fix**: green tests, a satisfied spec, and an avatar that never
changed its behaviour.

The irony is on the record, four lines above the defect. `TemplatePayload.php:86-88` warns:

> Tavus wants the language spelled out. Sending `'it'` is **accepted and ignored**, so the avatar
> answers in English to an Italian candidate — a failure nobody would attribute to a language
> mapping.

The author identified the failure mode exactly, fixed the **vocabulary** (`it` → `italian`), and
left the **path** wrong. Same failure mode, one level up, guarded by a comment describing it.

**Consequence for the delta spec**: `avatar-templates/spec.md:314-317` and its scenario at `:339-343`
ratify only the *vocabulary* translation. The path was never specified, which is why nothing caught
this. The delta spec MUST now state the path, not just the value.

### D3 — Strip persisted `config.language` with a migration *(RATIFIED)*

A JSONB key-strip over every `avatar_templates.config` row, both providers, active and inactive.

**Required, not cosmetic.** `ConfigValidator` reports keys absent from `ProviderFieldSpecs` as
`unknown` (`:44-48`), so a row that still carries `language` makes its template **unsavable and
unimportable**: the operator's next edit 422s on a key they cannot see, in a form that no longer
renders it, and `AvatarTemplatePortabilityController.php:127` refuses the same document on import.
Ignoring the values in place is cheaper on the day and leaves that trap armed.

**The `down()` cannot restore the stripped values and MUST say so in its docblock.** A migration
that silently pretends to be reversible is worse than one that is honestly one-way.

### D4 — Fold the `end_phrase` / `final_phrase` source swap into this change *(RATIFIED)*

Both `buildSuccessResponse(...)` call sites (`InterviewController.php:583, 652`) switch from
`$participant->language` to the project language. Two reasons, both accepted:

1. **The code contradicts a ratified spec.** `interview-session/spec.md:278` requires the closing
   phrases be *"localized to the project language"*, with scenarios keyed
   `GIVEN a project with language = 'it'` (`:302-315`). This is not a second inconsistency to weigh
   against the first — it is a spec violation on exactly the invariant this change establishes.
2. **`participant.language` is unvalidated third-party input.**
   `M2m/ParticipantController.php:53` accepts `'language' => ['nullable','string','max:10']` with no
   `supported_locales` check and no default from the project (`:69`). A caller can post `"fr"` on an
   `it` project and the closing phrases silently fall back to English.

Shipping "the avatar speaks the project's language" while its closing line resolves from a
different, unvalidated source would rebuild the same defect one field over.

**Scope boundary, stated so it reads as deliberate rather than overlooked**: only the source swap is
folded in. The three questions listed under *Out of Scope* — whether the column should exist,
whether M2M should validate the locale, and what `EntryLinkMinter`'s `$lang` override is for — stay
separate product decisions.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- **`avatar-templates`** — `language` leaves the HeyGen and Tavus field specs; the Tavus
  vocabulary-translation requirement and its scenario (`spec.md:314-317, 339-343`) move to the
  platform default, and the relocated requirement MUST now specify the **path**
  (`properties.language`) as well as the vocabulary — the omission of the path is why D2's defect
  was never caught. The per-project-override deferral (`:496-501`) is answered.
- **`interview-session`** — `:1170-1171` must stop listing `avatar_persona.language` among
  template-merged fields; `:1296-1302` ("a template overrides the platform default per key") needs a
  language-specific counter-scenario; `:1262-1264` gains Tavus's language platform default, at its
  path; `:1278`'s "a template no organization had" is factually wrong and is corrected under
  deliverable 11. `:897`, `:911` and `:1304-1309` stay **true and unchanged** — language still rides
  `/sessions/token`, still from the project. Under D4, `:278` and `:302-315` become **satisfied
  rather than amended**: the spec was already right and the code is being brought to it.

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
Decision needed before apply: No
```

Production code is small; tests, specs, fixtures, and the migration are not. `Decision needed before
apply` moved to **No** when D2, D3 and D4 were ratified — all four decisions are now settled. The two
questions still open (below) do not gate implementation: one is a pre-deploy production check, the
other is explicitly out of scope.

## Affected Areas

| Area | Impact | Description |
|---|---|---|
| `api/app/Support/AvatarTemplates/TemplatePayload.php:42, 89-97` | Modified | Stops emitting language for both providers |
| `api/app/Support/AvatarTemplates/ProviderFieldSpecs.php:36, 61, 84` | Modified | `language` `FieldSpec` removed from both providers |
| `api/app/Services/Provider/HeygenProvider.php:59` | Modified | Allowlist entry removed (D1) |
| `api/app/Services/Provider/TavusProvider.php:159-176` | Modified | Project language **added** to the platform default at `properties.language` (D2) |
| `api/app/Services/Provider/TavusProvider.php:79-84` | Modified | Stale "No org has one today" comment corrected (F1, deliverable 11) |
| `api/app/Services/Provider/HeygenProvider.php:180-183` | Modified | Same stale claim corrected (F1, deliverable 11) |
| `api/app/Support/Demo/DemoWriter.php:143-188` | Modified | Demo configs drop `language`; `tavus-en` renamed (F2) |
| `api/database/migrations/` | **New** | Strip `config.language` from persisted rows; non-restorable `down()` (D3) |
| `api/app/Http/Controllers/Candidate/InterviewController.php:583, 652` | Modified | Phrase source → project language (D4) |
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
| 3. **Without D2's path fix the whole change is a silent no-op for Tavus** — a wrong path is accepted and ignored, so the source swap changes nothing on the wire while tests go green | **Certain if D2 is dropped** | D2 RATIFIED. Verification MUST assert the emitted **path**, not merely the presence of a language value — the vocabulary-only spec (`avatar-templates/spec.md:314-317`) is exactly what let this survive |
| 4. `properties.language` is proven by the demo, not by Tavus documentation | Med | Reconfirm against the live contract during apply. If Tavus accepts both paths, the demo-proven one still wins and the code must say why |
| 5. The D3 migration is one-way; a mistake in its filter loses operator configuration | Med | Strip exactly the `language` key, both providers, active and inactive rows; assert every other key survives on a full-config fixture before the delete runs anywhere real |
| 6. A tenant deliberately using the template to speak a different language loses that ability | Low | Cannot be verified without production data (F1, open question 1). It is a ratified product decision, not a regression — surface it in release notes |
| 7. Amending ratified spec blocks needs sign-off, not a silent overwrite | Certain | Explicit delta specs in `sdd-spec` |
| 8. D4 changes a live response field on `/start`; the frontend treats absent/empty phrases as terminal (`interview-session/spec.md:295-296`) | Low | Both sources resolve through the same fallback; assert non-empty for a participant whose language is null, unsupported, and divergent from the project |
| 9. The corrected comments (deliverable 11) drift again the next time seeding changes | Med | State the invariant, not the census: describe what the code *supports*, never how many organizations currently do it. A comment that counts rows is a comment that expires |
| 10. Multi-repo drift: `api` and `backoffice` must ship together or the form renders a key with no translation | Med | Git Flow ×4 — paired `feature/*` branches, wrapper pins both submodule commits in one bump. Merge `api` first, `backoffice` immediately after |

## Rollback Plan

**Code**: three small, disjoint edits per provider. Revert the PR and the previous merge order
returns; the platform default already carried the project's language for HeyGen before this change,
so a HeyGen rollback is behaviour-neutral for any org with no active template.

**Data**: the D3 migration deletes a JSONB key. Its `down()` **cannot restore the values** — RATIFIED
as a documented no-op whose docblock states that plainly. If restoring ever matters, capture an
`avatar_templates(id, config)` snapshot in the same PR before the delete; do not disguise the
migration as reversible.

**Order matters**: roll back the migration PR independently of the code PR. Reverting the code while
the rows are already stripped is safe (the field spec is back, the key is simply unset). Reverting
the migration while the code is live is not restorable.

## Dependencies

- C7a, C8, C14 delivered. `liveavatar-contract-alignment` archived (2026-08-20).
- **All four decisions (D1–D4) are ratified. No decision gates apply.**
- D2's `properties.language` path should be reconfirmed against the live Tavus contract during
  apply — a verification step, not an open decision (Risk 4).
- Coordinated `api` + `backoffice` submodule release (Risk 10).

## Success Criteria

- [ ] For **both** providers, the outbound body's language equals `project.language` — proven with an
      active template that sets a **different** language, asserting the template does not win.
- [ ] Two projects of the **same organization** with `language = 'it'` and `'en'` produce two
      different avatar languages under the same active template.
- [ ] `TemplatePayload::heygen()` / `::tavus()` emit no language key for any config, including one
      that still contains `language`.
- [ ] Tavus still sends a language on every `/start` — the platform default replaced the template,
      it did not remove the field.
- [ ] Tavus's language is asserted at **`properties.language`**, by path and not merely by presence
      (D2). A test that would still pass with the value at the top level does not satisfy this.
- [ ] The backoffice avatar-template form renders **no** language control for either provider, and
      no untranslated key appears.
- [ ] `demo:provision` completes; every seeded template validates clean.
- [ ] After the migration, a template whose stored config carried `language` can still be edited,
      saved, and re-imported — and every other config key it held is intact.
- [ ] `end_phrase` / `final_phrase` match the project language even when `participant.language` is
      null, unsupported, or different (D4).
- [ ] No test asserts a template-sourced language for either provider.
- [ ] No comment or spec sentence still claims that no organization has an active `AvatarTemplate`
      (deliverable 11), and the replacements describe what the code supports rather than counting
      current rows.

## Proposal Question Round

Five questions were raised. **Three are now settled** and have moved into *Decisions* — D2 (fix the
Tavus path, not just the source), D3 (strip stored values by migration), D4 (fold in the
`end_phrase` source swap). They are RATIFIED and are not to be re-opened by `sdd-spec` or
`sdd-design`.

### Still OPEN — do not answer these autonomously

Neither blocks implementation. Both need a human.

1. **OPEN — does any real tenant have an active avatar template with a language set?**
   Cannot be answered from this repository; no production database was queried and none is reachable
   from here. What is established is that the code supports and seeds that state (F1). If the answer
   is yes, this change alters a live avatar's spoken language on deploy and needs a **release note**,
   not a silent ship. This is a **pre-deploy verification**, not a design gate.

2. **OPEN — should `participants.language` exist at all?**
   BEAI holds no candidate contact data (ratified decision #8) and the calling system owns
   scheduling (#5). If the project owns the interview language end to end, the column may be dead
   weight — and the unvalidated M2M input at `M2m/ParticipantController.php:53` should probably be
   locale-checked or removed either way. Explicitly **out of scope here** (see D4) and worth
   scheduling as its own change rather than leaving to drift.
