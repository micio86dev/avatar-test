# Design: The Avatar's Spoken Language Follows the Project

## Technical Approach

One rule, applied in one place: **`TemplatePayload` stops knowing that language exists.**

Once the mapper emits no language key, neither provider's three-layer
`array_replace_recursive` has anything to override with, and the platform default — fed from
`$ctx->language ← $project->language` — becomes the single source by construction rather than by
guard. Nothing downstream needs a filter, a precedence rule, or a conditional.

That leaves four consequences to sequence, and they are the whole of the work:

1. **HeyGen already has a platform default** (`HeygenProvider.php:272-276`). Deleting the template's
   emission is sufficient. The allowlist edit is cleanup, not a fix — **D1**.
2. **Tavus has none.** The template is its only language source today, and the source it would move
   to writes the value at a path the demo contradicts. Both must change together or the change is a
   silent no-op — **D2**, **D3**, **D4**.
3. **The operator-facing surface** (field spec → validator → demo seed → backoffice form → i18n keys
   → persisted rows) is retired in a fixed order so no intermediate state throws — **D5**, **D6**.
4. **The closing phrases** move to the project language, which turns out to cost nothing — **D7**.

Language is not otherwise re-plumbed. `QuestionContext` is unchanged, the controller's
`language: $project->language` (`InterviewController.php:198`) is unchanged, `/sessions/token` remains
the carrier for HeyGen. This change **removes** a source; it does not add one.

---

## Findings that changed the design

Verified in code on 2026-08-20, beyond the proposal's F1–F4.

**F5 — Tavus's platform default cannot source a language without a signature change AND a new config
key.** `TavusProvider::platformDefaultConversationFields()` (`:159-176`) takes **no arguments** —
`$ctx` is never passed to it. It must become `platformDefaultConversationFields(QuestionContext $ctx)`.
And `$ctx->language` is **nullable by contract** (`QuestionContext.php:51`): `ProviderSmokeCheck.php:79-85`
constructs a context with no language at all. HeyGen absorbs that with
`config('interview.heygen.language')` (`:272`). Tavus has **no equivalent key** — `config/interview.php`'s
`tavus` block holds `api_key`, `replica_id`, `persona_id` and nothing else. Without one, `interview:smoke-check`
against Tavus would send no language and the null path would be untested. See **D4**.

**F6 — deliverable 9 costs zero queries, because the value is already in the room.** Both
`buildSuccessResponse(...)` call sites live in methods that **already receive `$ctx`**:
`handleResumeInCorso(..., QuestionContext $ctx)` (`:532-537`, call site `:583`) and
`handleIssuePending(..., QuestionContext $ctx, ...)` (`:593-599`, call site `:652`). And
`$ctx->language` was assigned `$project->language` at `:198`, from `$project = $participant->project`
resolved once at `:91`. The edit is `$participant->language` → `$ctx->language` — no new parameter,
no new query, no new relation load. See **D7**.

**F7 — retiring the demo's `language` orphans a config surface, and the key that must survive is a
visual near-twin of the key that must go.** `DemoWriter.php:152` reads
`$identity['heygen']['language']`, which comes from `DemoDataset::avatarIdentity()` (`:712-724`,
`:718`) reading `config('interview.demo.heygen.language')`. That chain goes, plus the `@return` shape
at `DemoDataset.php:708`.

**The trap is that the two config keys are byte-identical expressions reading the same env vars, 113
lines apart:**

| Key | Line | Expression | Fate |
|---|---|---|---|
| `interview.heygen.language` | `config/interview.php:83` | `env('HEYGEN_LANGUAGE', env('LIVEAVATAR_LANGUAGE', 'it'))` | **SURVIVES — MUST NOT BE TOUCHED** |
| `interview.demo.heygen.language` | `config/interview.php:196` | `env('HEYGEN_LANGUAGE', env('LIVEAVATAR_LANGUAGE', 'it'))` | **REMOVED** |

The right-hand column is the only difference between them. `interview.heygen.language` is the
**provider** surface — HeyGen's null-`$ctx` fallback (`HeygenProvider.php:272`), spec-ratified at
`interview-session/spec.md:1258-1262`, and the sole reason `interview:smoke-check` resolves a language
today. `interview.demo.heygen.language` is `beai:demo-seed`-scoped and dies with the demo fixture.
`config/interview.php:64-72` states the separation is deliberate — *"this key is DELIBERATELY a
separate config surface"* — but the two literals are indistinguishable at a glance, and a cleanup that
deletes the wrong one **removes the platform default's fallback and reintroduces the 0.22.1 outage
class** (the docblock at `:76-79` says as much about `avatar_id`). The env vars `HEYGEN_LANGUAGE` /
`LIVEAVATAR_LANGUAGE` are **kept**, because `:83` still reads them; only the demo consumer goes.

**F8 — the backoffice form is spec-driven, so the i18n removal is cleanup and the deploy order is
one-directional.** `AvatarTemplateForm.vue` renders `$t(field.label_key)` (`:137`) and
`$t(field.hint_key)` (`:197`) from the API's field-spec response. Drop the `FieldSpec` and the control
disappears on its own. **The removal must be path-scoped**: only `avatar_templates.field.language`
(`it.json`/`en.json:606`) and `avatar_templates.hint.language` (`:650`). `projects.field.language`
(`:218`), `projects.form.help.language` (`:242`) and `participants.detail.language` (`:108`) are
different concerns that keep their labels. A blind search-and-replace on `"language"` deletes the
project language label — the very field this change makes authoritative.

**F9 — `WHERE config ? 'language'` is a trap on this stack.** PostgreSQL's jsonb existence operator is
`?`, which PDO reads as a parameter placeholder. The migration must use the function form
`jsonb_exists(config, 'language')`. See **D6**.

**F10 — the census claim appears FIVE times, not three, and the two extra sites change what kind of
finding this is.** The proposal listed three. Two more were found by verifying those three:

| # | Site | Text | Source |
|---|---|---|---|
| 1 | `HeygenProvider.php:182` | *"No org has one today, so `$templateFields` was `[]`"* | proposal F1 |
| 2 | `TavusProvider.php:82` | *"No org has one today"* | proposal F1 |
| 3 | `interview-session/spec.md:1278` | *"a template no organization had"* — **ratified spec** | proposal F1 |
| 4 | `ActiveTemplateResolver.php:13` | *"it is the state EVERY existing organization is in the moment this ships"* | **this design** |
| 5 | `config/interview.php:61-62` | *"sourced avatar_id/voice_id/language ONLY from the org's active `AvatarTemplate`, **and NO org has one today**"* | **coordinator, verified here** |

Site 5's docblock says it **twice**: `:72` adds *"this is only the fallback for the (today: universal)
case where it does not."* Both are corrected as one edit.

All five are false: `DemoWriter::writeAvatarTemplates()` (`:143-163`) seeds an **active** HeyGen
template carrying a language, and `ProjectCompetenciesTest.php:75-76` asserts exactly one active
template exists.

**Why five instead of three reframes the finding.** Four of the five were written by *different*
fixes at *different* times — C14's template feature, hotfix 0.22.1, hotfix 0.22.2, and the ratified
spec that recorded them — and each author verified the claim before writing it. Every one of them was
**correct on the day it was written**. This is not four instances of carelessness; it is one
*recurring* failure mode with a shared shape: **a comment that describes the state of the DATA rather
than the guarantee of the CODE.** Nothing in the process re-reads such a sentence when the data moves,
because nothing knows it depends on data at all. Site 5 is the sharpest illustration — it sits
directly above the config keys this change depends on (F7), so the next person cleaning up those keys
reads a false premise first.

Archived copies under `openspec/changes/archive/**` carry the same phrasing and are **not** edited —
they are the historical record of what was believed when they were written.

**F11 — the migration cannot reach template files already exported.**
`AvatarTemplatePortabilityController.php:127` runs the same `ConfigValidator`, so a JSON export taken
before this change — sitting on an operator's disk, not in the database — will be **rejected on
import** with `{key: language, code: unknown}`. Accepted deliberately: see **D6**, *residual*.

---

## Architecture Decisions

### D1 — The cut is in `TemplatePayload`. The allowlist edit is defence in depth, and is labelled as such

**Choice.** Delete `TemplatePayload.php:42` (`avatar_persona.language`) and `:89-97` (the Tavus
language block). Also delete `'avatar_persona.language'` from `HeygenProvider::TOKEN_FIELD_ALLOWLIST`
(`:59`) — **and describe that second edit, in the PR and in the code comment, as redundant.**

**Rationale.** The two edits are not symmetric and must not be reviewed as if they were.

| Edit | Load-bearing? | Why |
|---|---|---|
| `TemplatePayload.php:42`, `:89-97` | **Yes** | After it, `allowlistedTemplateFields()` (`:289-309`) finds nothing at that path to copy. `data_get($mapped, 'avatar_persona.language')` returns `null` and the key is skipped. |
| `HeygenProvider.php:59` | **No** | Filtering a key that is never produced. |

The reverse ordering does **not** hold, which is the whole reason the allowlist cannot be the fix:
`allowlistedTemplateFields()` unions the constant with
`config('interview.heygen.extra_token_fields', [])` (`:293-296`, env `HEYGEN_EXTRA_TOKEN_FIELDS`).
Removing only the constant leaves the field re-openable **by an env var, with no deploy** — a
ratified product rule undone by a comma in a `.env`. Cutting at the mapper closes that door too,
because `extra_token_fields` can only widen the filter over values the mapper produced.

The allowlist entry is still removed, for one reason: it is the readable inventory of what a template
may say to HeyGen. Leaving `language` there documents a permission that no longer exists.

**Alternatives rejected.** (a) Allowlist-only — insufficient per above. (b) Filter the language key
inside `buildSessionTokenBody()` — adds a guard to defend against a value nothing produces; the merge
stays honest only if the inputs are. (c) Keep the mapper and reorder the merge so the platform default
wins — inverts the documented precedence (`interview-session/spec.md:1266-1273`) for every field to
fix one.

**Testability.** `TemplatePayloadTest` asserts key **absence** for a config that still *contains*
`language` — the post-migration-failure case, pinned in a pure unit test with no HTTP.

---

### D2 — Tavus's language becomes a platform default, at `properties.language`

**Choice.** `platformDefaultConversationFields()` gains a `QuestionContext $ctx` parameter and writes
the language to **`properties.language`**, not top level. `TavusProvider::issue()` (`:97-101`) passes
`$ctx` into it.

**Rationale.** The path is the argument, not the source.
`legacy-demo/src/pages/api/interview/start.ts:311-312` — the only demonstrated-working Tavus create
call in this repository — nests it under `properties`. `TemplatePayload::tavus():92` emits it top
level. Tavus **accepts and ignores** an unrecognised top-level key, exactly as
`TemplatePayload.php:86-88` warns it does for an unrecognised *value*. If only the source moved, the
wire body would be identical in the way that matters: a field Tavus discards, on every request, in
every project, in both languages. Green tests, satisfied spec, unchanged avatar.

`properties` is already the nest Tavus uses for call-level knobs here —
`TemplatePayload::tavus():100-103` writes `properties.max_call_duration`,
`properties.participant_absent_timeout`, `properties.enable_recording`,
`properties.enable_closed_captions`. The language joins its own family; the top-level placement was
the outlier.

`array_replace_recursive` (`:97-101`) is already correct for a nested key and needs no change — the
recursive merge is precisely why `properties.language` survives alongside the template's
`properties.*` knobs instead of replacing the node.

**Alternatives rejected.** (a) Keep the top-level path because it is what shipped — it shipped
inert; matching a broken precedent is not compatibility. (b) Send both paths — doubles the surface,
and if Tavus later validates unknown keys the extra one is a 400 in front of a candidate. (c) Wait for
Tavus documentation before choosing — the demo is the only evidence this repository has ever used for
this contract (`@wire-source` on `:155`); deferring on it blocks a ratified decision on an
unobtainable artifact. Risk 4 stands as an apply-time reconfirmation.

**Testability — the assertion shape is mandated.** `Http::fake()` capture, then
`expect($body)->toHaveKey('properties.language', 'italian')` **and**
`expect($body)->not->toHaveKey('language')`. A test that only asserts presence-somewhere would pass
against the defect this decision exists to fix, and must be rejected in review.

---

### D3 — The `it → italian` map moves to `App\Support\Provider\TavusLanguage`

**Choice.** A new final class with one pure static method,
`TavusLanguage::forWire(string $locale): string` — `'it' => 'italian'`, `'en' => 'english'`, default
passthrough. `TavusProvider` calls it; `TemplatePayload` no longer contains it.

**Rationale.** The map is Tavus **wire vocabulary**, not template mapping. It was only inside
`TemplatePayload::tavus()` because that was the sole place a language reached Tavus; with the source
moving to the provider, leaving it behind would keep a language translator in a class whose entire
point is that it no longer handles language.

A named class rather than a private method on `TavusProvider`, for one concrete reason: strict TDD.
A private method is reachable only through `Http::fake()` + a full `issue()` call, so the ratified
vocabulary requirement (`avatar-templates/spec.md:314-317`) would lose its pure unit test and get
re-pinned as an integration assertion. `TavusLanguage::forWire('it') === 'italian'` is one line, no
fakes, no container. It also gives the relocated spec requirement a single obvious home.

The default arm is a **passthrough, deliberately**: an unmapped locale is sent as-is and ignored by
Tavus, which is the pre-existing behaviour (`TemplatePayload.php:95`). Throwing here would turn an
i18n gap into a failed interview. The docblock states this, because a silent passthrough on a value
Tavus discards is the failure mode this whole change is about.

**Alternatives rejected.** (a) Private method on `TavusProvider` — untestable in isolation, per above.
(b) A config-file map — invites per-environment divergence on a fixed vendor vocabulary. (c) A
`FieldType`-driven translation in `ProviderFieldSpecs` — the field spec is being deleted.

---

### D4 — Tavus gains `interview.tavus.language`, mirroring HeyGen exactly

**Choice.** Add `'language' => env('TAVUS_LANGUAGE', 'it')` to `config/interview.php`'s `tavus` block.
Resolution: `$ctx->language ?? config('interview.tavus.language')`, then `TavusLanguage::forWire()`,
then omit if empty.

**Rationale.** F5: `$ctx->language` is nullable and `ProviderSmokeCheck.php:79-85` exercises the null
path. HeyGen's answer is `config('interview.heygen.language')` (`:272`), spec-ratified at
`interview-session/spec.md:1258-1262` as *"falling back to `interview.heygen.language` only when the
caller supplies none"*. Giving Tavus a differently-shaped fallback would mean two providers with two
null-language behaviours for one product rule.

Default `'it'` matches `interview.heygen.language` (`config/interview.php:83`) and
`interview.frontend_default_locale` (`:227`). This is a **new config key, not a new dependency** —
the Dependency Resolution Policy is untouched.

**Alternatives rejected.** (a) Fall back to `config('app.fallback_locale')` (`en`) — silently
disagrees with HeyGen's `it` on the same deployment. (b) Omit the key when `$ctx->language` is null —
leaves Tavus with no language at all on the smoke-check path, reintroducing exactly the gap this
change is closing, in the one place an operator uses to verify it. (c) Reuse
`interview.heygen.language` — couples two vendor surfaces whose value spaces already differ (`it` vs
`italian`), which is the confusion **D3** exists to isolate.

---

### D5 — The field-spec removal ships as one PR, in a fixed intra-PR order

**Choice.** Deliverables 5, 6, 7 and the `DemoDataset`/config cleanup are **one atomic slice**. Within
it, the order is fixed:

```
 1. RED     ProviderFieldSpecTest / TemplatePayloadTest / DemoWriter tests invert
 2.         DemoWriter.php:152, :172          — drop 'language' from both demo configs
            DemoDataset.php:708, :712-724     — drop heygen.language from the identity shape
            config/interview.php:196          — drop interview.demo.heygen.language
 3.         ProviderFieldSpecs.php:61, :84    — drop the FieldSpec; then :36 LANGUAGES
 4.         backoffice it.json/en.json:606, :650 — drop the two keys (path-scoped, F8)
```

**Rationale — step 2 must precede step 3, and nothing else is free.** `ConfigValidator` is entirely
spec-driven: any key absent from `ProviderFieldSpecs` returns `unknown` (`:44-48`).
`DemoWriter.php:192-201` throws `RuntimeException` on **any** validator error before it writes a row.
Reverse the order and `beai:demo-seed` dies at the first template — the demo org has no projects, no
participants, and CI's demo suite fails on a seed step rather than an assertion.

`ConfigValidator` and `AvatarTemplatePortabilityController` need **no edit at all**. Both consume
`ProviderFieldSpecs` and inherit the removal. That is the design property being relied on, and the
reason the coupling is safe to sequence rather than refactor.

`LANGUAGES` (`:36`) is removed **last and only after** confirming it is unreferenced — it is used at
`:61` and `:84` only, so it becomes dead the moment both go. Larastan flags an unused private
constant; leaving it would fail the pipeline for a reason unrelated to the change.

`beai-demo-tavus-en` (`DemoWriter.php:165-166`) is renamed — its name and its description both encode
a language it no longer sets. Proposed: `beai-demo-tavus-secondary`, described by its role (inactive
second-provider template) rather than by a language. A fixture named after a field that no longer
exists is the same defect class as **D8**.

**Alternatives rejected.** (a) Split api and backoffice into separate PRs and ship the backoffice one
first — renders `avatar_templates.field.language` as a raw key in the form (F8). (b) Keep the
`FieldSpec` and mark it read-only/deprecated — leaves a control an operator can set and never hear,
which is the exact failure `ProviderFieldSpecs`' own docblock (`:12-15`) was written to prevent.

---

### D6 — One-way JSONB key-strip, unscoped by design, honestly irreversible

**Choice.** A migration `…_strip_language_from_avatar_templates_config.php`:

```php
// Platform-wide by design: NOT tenant-scoped. See the scope table below.
DB::table('avatar_templates')
    ->whereRaw("jsonb_exists(config, 'language')")
    ->update(['config' => DB::raw("config - 'language'")]);
```

| Aspect | Decision | Rationale |
|---|---|---|
| **Filter** | `jsonb_exists(config, 'language')` | `?` is a PDO placeholder (F9). The predicate also keeps `updated_at`-free no-op rows out of the write set. |
| **Operator** | `config - 'language'` | jsonb key-delete. Removes **exactly one top-level key**; every sibling is preserved byte-for-byte by Postgres, not by application code re-serialising a decoded array. |
| **Scope** | **Both providers, active and inactive, every organization** | `language` is invalid for both providers after step 3 of **D5**; an inactive row is activated later and 422s on a key the form cannot show. |
| **Tenancy** | **Deliberately unscoped** | See the scope table. |
| **`down()`** | No-op with a docblock that says the values are gone | A migration that pretends to be reversible is worse than one that is honestly one-way. |

**Why it is required, not cosmetic.** After **D5**, a surviving `language` key makes its template
**unsavable and unimportable**: the operator's next edit 422s with `{key: language, code: unknown}`
on a field the form no longer renders, and `AvatarTemplatePortabilityController.php:127` refuses the
same document. Leaving the values in place is cheaper on the day and arms the trap.

**Risk if the filter is wrong.** The operator's entire avatar configuration is destroyed with no
recovery path. `config - 'language'` on the wrong key silently removes `avatarId` or `palId`; a
whole-column overwrite loses everything. There is no `down()` to save it and — because this migration
runs against every organization at once — the blast radius is the platform, not one tenant. The
mitigation is **RED-first on a maximal fixture**: a config carrying every key its provider's field
spec defines *plus* `language`, asserted key-by-key after the migration, in both providers, before the
`update()` is written.

**Residual, accepted (F11).** Template JSON exported before this change fails re-import with
`unknown: language`. Not fixed by stripping on import: `AvatarTemplatePortabilityController.php:123-126`
argues explicitly against a second validation path, and silently accepting a key the form rejects is
the drift that comment forbids. The message names the key; the operator deletes one line. Release note.

**Alternatives rejected.** (a) Ignore stored values and have `ConfigValidator` tolerate unknown keys —
weakens a validator that protects every field to accommodate one. (b) Snapshot to a side table first —
useful only if a restore path exists, and the ratified position is that the values are obsolete, not
misplaced. Callers who want a snapshot take one at the DB level (rollback plan).

---

### D7 — The closing phrases read `$ctx->language`; the project is already in scope at both sites

**Choice.** `InterviewController.php:583` and `:652` change `$participant->language` → `$ctx->language`.
Nothing else moves.

**Rationale.** F6: `$ctx` is already a parameter of both enclosing methods (`:532-537`, `:593-599`),
and `$ctx->language` was assigned `$project->language` at `:198` from a `$project` resolved once at
`:91`. **No new query, no new parameter, no relation load, no N+1.** Threading `$project` in as a
second argument would duplicate a value the DTO already carries for exactly this locale.

This is not a new rule — it is compliance. `interview-session/spec.md:278` already requires the
phrases *"localized to the project language"*, with scenarios keyed `GIVEN a project with
language = 'it'` (`:302-315`). The code has been in violation. The delta spec records these as
**satisfied**, not amended.

Three docblocks state the wrong source and are corrected in the same edit: `:744` and the `@param` at
`:750` on `buildSuccessResponse()`, and the `@param` at `:799` plus the resolution rule at `:791` on
`resolveCompletionPhrases()`. The parameter itself stays `?string $language` — the method resolves a
locale and should not learn what a project is.

`resolveCompletionPhrases()`'s fallback (`:802-815`) is **unchanged** and still load-bearing:
`project.language` is validated against `supported_locales` at write time
(`StoreProjectRequest.php:69`), but a locale can be supported by the API and still lack
`lang/{locale}/interview.php`, and rows can be written directly. `Lang::has()` keeps that
deterministic.

**Alternatives rejected.** (a) Defer to a separate change — ships "the avatar speaks the project's
language" while its closing line resolves from unvalidated third-party input
(`M2m/ParticipantController.php:53`), rebuilding the same defect one field over. (b) Validate
`participant.language` against `supported_locales` and keep it as the source — a product decision
about per-candidate language, explicitly out of scope (open question 2).

---

### D8 — Comments state the invariant, never the census

**Choice.** **Five** sites are corrected (F10). Every replacement describes what the code
**guarantees**; none states how many organizations are in a given state.

| # | Site | Current claim | Replacement states |
|---|---|---|---|
| 1 | `HeygenProvider.php:182` | *"No org has one today, so `$templateFields` was `[]`"* | Identity is sourced from the platform default and **may** be overridden per key by an active template; the 0.22.1 outage happened because there was **no** platform default — not because templates were rare. |
| 2 | `TavusProvider.php:82-83` | *"No org has one today"* | Same, for the 0.22.2 400. |
| 3 | `ActiveTemplateResolver.php:13` (F10) | *"it is the state EVERY existing organization is in"* | `null` is a **supported** resolution, not an exceptional one; every caller must degrade to platform defaults. |
| 4 | `config/interview.php:61-62` **and** `:72` (F10) | *"NO org has one today"* / *"the (today: universal) case"* | These keys are the **unconditional floor** for any request where the active template sets no value; that is a permanent contract, not a description of current tenants. |
| 5 | `interview-session/spec.md:1278` | *"a template no organization had"* | *"a template that was optional and frequently absent"* — `sdd-spec` owns the final wording. |

Site 4 is corrected **without touching the surrounding separation rationale** (`:64-72`,
`:74-79`), which is a statement about code structure and remains true and load-bearing — it is what
F7's near-twin trap depends on being read.

**The rule, and why it is a design decision rather than a style note.** A comment that counts rows is
a comment that expires. Its truth depends on data the reader cannot see, in an environment the comment
cannot name, at a time the comment does not record. So it cannot be verified from the file it sits in,
cannot be tested, and decays silently into a confident falsehood that reads as ratified fact. An
invariant — *"null is a supported resolution; degrade to the platform default"* — is checkable against
the code beside it and stays true after any seeding, migration, or tenant change.

**This is a recurring failure mode, not a lapse.** Four of the five were written by different fixes at
different times, and each author verified the claim before writing it; each was **correct on the day it
was written** (F10). The defect is the *category of sentence*, which has a shelf life that nothing in
the process tracks — no review step, no test, and no tooling knows that a prose sentence took a
dependency on production data. Framing it as carelessness would predict that more care prevents a
sixth. It would not. Only not writing the sentence does.

**This rule applies to every comment and spec sentence written by this change**, including the new ones
in **D3**, **D4** and **D6** — D6's migration docblock in particular, which must say *"all
organizations, by design"* (a property of the query) and must **not** say how many rows carry the key.

#### Can anything cheap prevent a sixth?

**A test cannot pin these claims, and that is precisely why they survived four rounds of verification.**
The assertion is about **production data**, and every test in this repository runs against a fresh or
demo-seeded database. A test asserting "no organization has an active template" would assert a fact
about its own fixture, not about production — and `ProjectCompetenciesTest.php:75-76` already asserts
the **opposite** in the seeded test database while all five comments stood unchallenged. The claim is
**unfalsifiable in CI by construction**. That is the finding, and it disqualifies the obvious remedies:

| Candidate mechanism | View |
|---|---|
| Assert the census in a test | **Impossible.** Nothing in CI can observe production tenants. |
| Pin it in the F5/D4 fallback test | **Misreads what that test does.** `HeygenProviderTest.php:271-275` and D4's new Tavus case pin the *invariant* — the platform default supplies a language when the template does not. They already fail loudly if that guarantee breaks. They say nothing about how many templates exist, and should not be made to. |
| An arch/lint test grepping comments for census phrasing | **Rejected for this change.** Technically buildable on the pinned stack (`api/tests/Arch/` exists), but it is a regex over English prose with a phrase list that expires the same way the comments do — a comment that counts rows, relocated to a test file. It also expands deliverables beyond correcting the five, which the scope does not justify on one occurrence of the pattern. Reconsider as its own change if a sixth appears. |
| A runtime check or production assertion | **Out of scope and wrong shape.** The census is not a property the product needs to enforce; it is a fact the product should never have written down. |

**The cheap prevention that IS in scope, and is adopted:** each of the five replacements must state a
guarantee that an **existing named test already pins**, and cite that test. Sites 1 and 4 are held by
`HeygenProviderTest.php:249-276` (platform default supplies the language, `$ctx` or config); site 2 by
D4's new Tavus null-`$ctx` case; site 3 by every provider test that runs with no active template. A
comment whose claim has a test beside it fails loudly when it stops being true, because the test goes
red. This costs nothing — it is a writing constraint on corrections already in scope — and it converts
the five from unverifiable prose into documentation of behaviour CI defends.

Archived artifacts under `openspec/changes/archive/**` carry the same phrasing and are **not** edited
— they are the historical record of what was believed when they were written.

---

### D9 — `api` merges first; the migration is the one thing that cannot come back

**Choice.** Paired `feature/*` branches under Git Flow ×4. **Merge `api` first, `backoffice`
immediately after**, then one wrapper commit bumping both submodule pointers.

**Rationale — the window is asymmetric, and only one direction is safe.**

| Order | Window state | Severity |
|---|---|---|
| `api` first | Field spec gone → form renders no language control. `backoffice` still holds two now-unused i18n keys. | **Harmless.** An unused translation key renders nothing. |
| `backoffice` first | `api` still emits the `FieldSpec` → `AvatarTemplateForm.vue:137` renders `$t('avatar_templates.field.language')`, which resolves to the raw key string. | **Operator-visible defect.** |

If `openapi.json` changes (only if the field-spec response shape is published), it regenerates from
merged `api/develop` **before** the backoffice merge — never hand-edited.

**Rollback, and where the symmetry ends.** Code is three disjoint mapper/provider edits: revert the PR
and prior behaviour returns. HeyGen's revert is behaviour-neutral for any org with no active template,
since the platform default already carried the project language. Tavus's revert restores the
template-sourced, wrong-path field — i.e. back to inert.

**The migration is not revertible and must be rolled back independently, or not at all.**

```
 Code reverted, rows already stripped   →  SAFE. FieldSpec is back, the key is
                                            simply unset; validator sees no unknown key.
 Migration "reverted", code still live  →  IMPOSSIBLE. down() is a documented no-op.
                                            The values do not exist to restore.
```

So: **never bundle the migration with the code in a single revertible unit.** If restoring values
could ever matter, capture `avatar_templates(id, config)` at the database level before deploy — do not
disguise the migration as reversible to obtain it.

---

## Sequence: language resolution on `/start`, both providers

```
Candidate            InterviewController          Provider              TemplatePayload      Wire
    │                        │                        │                       │               │
    │── POST /start ────────►│                        │                       │               │
    │                        │ $project = $participant->project      (:91)    │               │
    │                        │ $ctx = QuestionContext(language: $project->language)  (:198)   │
    │                        │                        │                       │               │
    │                        │── issue($session,$ctx)►│                       │               │
    │                        │                        │                       │               │
    │                        │            HeyGen: platformDefaultTokenFields($ctx)            │
    │                        │              avatar_persona.language = $ctx->language          │
    │                        │                        │                       │               │
    │                        │            Tavus:  platformDefaultConversationFields($ctx)  D2 │
    │                        │              properties.language =                             │
    │                        │                TavusLanguage::forWire($ctx->language           │
    │                        │                  ?? config('interview.tavus.language'))     D4 │
    │                        │                        │                       │               │
    │                        │                        │── ::heygen/::tavus ──►│               │
    │                        │                        │◄── NO language key ───│    D1         │
    │                        │                        │                       │               │
    │                        │            array_replace_recursive(default, template, owned)   │
    │                        │              → template contributes nothing to language        │
    │                        │                        │───────────────────────────────────────►
    │                        │◄── ProviderToken ──────│                       │               │
    │                        │                        │                       │               │
    │                        │ buildSuccessResponse(…, $ctx->language, …)  (:583, :652)   D7  │
    │                        │   resolveCompletionPhrases($ctx->language)                     │
    │◄── 201 end_phrase / final_phrase in the PROJECT language ────────────────────────────────
```

Read the merge line twice: the template layer still runs, still wins per key for `voiceId`,
`videoQuality` and every other knob, and simply has no language key to contribute. That is **D1** —
precedence is unchanged; the input is empty.

---

## Multi-tenancy — every query scope, explicit

`AvatarTemplate` extends `TenantModel`, so `TenantScoped` appends
`avatar_templates.organization_id = resolver->getOrgId()` to **every Eloquent** query.
`Project` is likewise scoped. Raw `DB::table()` builders get **no** scope at all.

| # | Query | Scope | Notes |
|---|---|---|---|
| 1 | `ActiveTemplateResolver::resolve()` — `AvatarTemplate::where('is_active', true)->first()` (`:24`) | global org scope **+** `is_active` | **Unchanged.** Still runs, still resolves the org's template. Its result no longer influences language — every other key still merges. |
| 2 | `TavusProvider::activeTemplateConfig()` (`:273-282`) | inherits #1 | **Unchanged**, including the swallow-and-default `catch`. |
| 3 | `HeygenProvider::activeTemplateConfig()` | inherits #1 | **Unchanged.** |
| 4 | **NEW** — migration strip: `DB::table('avatar_templates')->whereRaw("jsonb_exists(config,'language')")->update(…)` | **NO org scope. Platform-wide, deliberately.** | Raw builder, no global scope, and **no `organization_id` predicate is added**. A migration runs outside any tenant context (`TenantResolver` has no org during `artisan migrate`), and a partially-migrated table is the failure mode **D6** exists to prevent — a skipped org's next template edit 422s. The docblock MUST state "all organizations, by design", so the absent scope reads as a decision rather than an omission. |
| 5 | `DemoWriter::writeAvatarTemplates()` — `AvatarTemplate::where('is_active', true)->exists()` (`:137`), `::where('name', …)->first()` (`:203`) | global org scope **+** predicate | **Unchanged.** Only the `config` array literals change. |
| 6 | `$participant->project` (`InterviewController.php:91`) | FK on the JWT-authenticated participant | **Unchanged and not re-queried** — **D7** consumes `$ctx->language`, already derived from it (F6). |
| 7 | `resolveCompletionPhrases()` (`:802-815`) | **no database access** | `Lang::has()` / `Lang::get()` against `lang/{locale}/interview.php`. Institutional UX chrome, identical for every tenant of a given locale — no tenant data crosses. |

**Required cross-tenant test.** Organization A (`language = 'it'`) with an active template whose
stored config sets `language = 'en'`, and Organization B (`language = 'en'`) with no template at all:
each `/start` MUST carry its **own** project's language, and A's template MUST NOT influence B's body.
Plus the intra-tenant case the proposal makes the headline: **two projects of the same organization**,
`it` and `en`, under **one** active template, producing two different avatar languages.

---

## File Changes

| File | Action | Description |
|---|---|---|
| `api/app/Support/AvatarTemplates/TemplatePayload.php` `:42`, `:78-106` | Modify | Both language emissions deleted; the `:86-88` vocabulary comment moves with the map (**D1**, **D3**) |
| `api/app/Support/Provider/TavusLanguage.php` | **Create** | `forWire(string): string` — the `it → italian` map, pure and unit-testable (**D3**) |
| `api/app/Services/Provider/TavusProvider.php` `:97-101`, `:159-176` | Modify | `platformDefaultConversationFields(QuestionContext $ctx)`; `properties.language` written from `$ctx->language ?? config('interview.tavus.language')` (**D2**, **D4**) |
| `api/app/Services/Provider/TavusProvider.php` `:79-96` | Modify | Census comment → invariant (**D8**) |
| `api/app/Services/Provider/HeygenProvider.php` `:59` | Modify | Allowlist entry removed; comment marks it as intent, not guard (**D1**) |
| `api/app/Services/Provider/HeygenProvider.php` `:180-183` | Modify | Census comment → invariant (**D8**) |
| `api/app/Services/Provider/HeygenProvider.php` `:251-279` | **Unchanged** | Platform default already correct — the reason HeyGen needs no new source |
| `api/app/Support/AvatarTemplates/ActiveTemplateResolver.php` `:12-18` | Modify | Census comment site 3 → invariant (**D8**, F10) |
| `api/app/Support/AvatarTemplates/ProviderFieldSpecs.php` `:61`, `:84`, then `:36` | Modify | `FieldSpec` dropped from both providers; `LANGUAGES` retired last (**D5**) |
| `api/app/Support/AvatarTemplates/ConfigValidator.php` | **Unchanged** | Spec-driven — inherits the removal (**D5**) |
| `api/app/Http/Controllers/AvatarTemplatePortabilityController.php` | **Unchanged** | Same validator; pre-change exports now reject by design (**D6**, F11) |
| `api/app/Support/Demo/DemoWriter.php` `:152`, `:165-166`, `:172` | Modify | `language` dropped from both configs; `tavus-en` renamed and redescribed (**D5**) |
| `api/app/Support/Demo/DemoDataset.php` `:708`, `:712-724` | Modify | `heygen.language` leaves the identity shape and the `@return` (F7) |
| `api/config/interview.php` `:196` | **Delete this line** | `interview.demo.heygen.language` — the **demo** key. Byte-identical to `:83`; check the surrounding block header (`Demo Avatar Identity (beai:demo-seed)`, `:180-191`) before deleting (F7) |
| `api/config/interview.php` `:83` | **UNCHANGED — DO NOT DELETE** | `interview.heygen.language` — the **provider** key. HeyGen's null-`$ctx` fallback (`HeygenProvider.php:272`), ratified at `interview-session/spec.md:1258-1262`. Deleting this one instead reintroduces the 0.22.1 outage class (F7) |
| `api/config/interview.php` `:57-72` | Modify | Census comment site 4 → invariant, **both** statements (`:61-62` and `:72`); the separation rationale at `:64-72`/`:74-79` is kept verbatim (**D8**, F10) |
| `api/config/interview.php` — `tavus` block | Modify | **Add** `'language' => env('TAVUS_LANGUAGE', 'it')` (**D4**) |
| `api/.env.example`, `docs/dev-setup.md` | Modify | `TAVUS_LANGUAGE` documented. `HEYGEN_LANGUAGE` / `LIVEAVATAR_LANGUAGE` are **kept** — only their demo consumer goes; `:83` still reads them (F7) |
| `api/database/migrations/…_strip_language_from_avatar_templates_config.php` | **Create** | Unscoped JSONB key-strip; `down()` a documented no-op (**D6**) |
| `api/app/Http/Controllers/Candidate/InterviewController.php` `:583`, `:652` | Modify | `$participant->language` → `$ctx->language` (**D7**) |
| `api/app/Http/Controllers/Candidate/InterviewController.php` `:744`, `:750`, `:791`, `:799` | Modify | Docblocks corrected — "participant's language" → project language (**D7**) |
| `api/app/Services/Provider/QuestionContext.php` | **Unchanged** | Already carries the project language (`:51`); no widening needed |
| `backoffice/i18n/locales/{it,en}.json` `:606`, `:650` | Modify | Exactly two keys, path-scoped to `avatar_templates.*` (**D5**, F8) |
| `backoffice/app/components/organisms/AvatarTemplateForm.vue` | **Unchanged** | Spec-driven from `field.label_key` / `field.hint_key` (F8) |
| `backoffice/openapi.json`, `backoffice/types/api.ts` | Regenerate | Only if the field-spec response shape is published; from merged `api/develop` (**D9**) |
| `openspec/specs/avatar-templates/spec.md` `:314-317`, `:339-343`, `:496-501` | Delta | Vocabulary requirement relocates to the platform default **and gains the path**; open item 7.2 answered |
| `openspec/specs/interview-session/spec.md` `:1170-1171`, `:1262-1264`, `:1278`, `:1296-1302` | Delta | Language leaves the template-merged list; Tavus platform default at its path; census sentence corrected; language counter-scenario added |
| `openspec/specs/interview-session/spec.md` `:278`, `:302-315`, `:897`, `:911`, `:1304-1309` | **Unchanged** | Already correct — **D7** brings the code to them |

---

## Testing Strategy

Strict TDD (`openspec/config.yaml: strict_tdd: true`). Every row lands RED first. The existing tests
that pin the **old** behaviour are the RED step — they invert, they are not deleted.

| Layer | What to test | Approach |
|---|---|---|
| Unit — mapper | `TemplatePayload::heygen()` / `::tavus()` emit **no** language key, for a config that still **contains** `language` | `tests/Feature/C14/TemplatePayloadTest.php` — `:128-135` inverts. Pure, no HTTP. The "still contains" case is the post-migration-failure path (**D6**). |
| Unit — vocabulary | `TavusLanguage::forWire('it') === 'italian'`, `'en' === 'english'`, unmapped passthrough | New `tests/Unit/Support/Provider/TavusLanguageTest.php`. Carries the relocated `avatar-templates/spec.md:314-317` requirement (**D3**). |
| Unit — field spec | Neither provider's spec contains `language`; `LANGUAGES` is gone | `tests/Feature/C14/ProviderFieldSpecTest.php:91` inverts. |
| Unit — validator | A config carrying `language` now yields `{key: language, code: unknown}` for both providers | `ConfigValidator` untouched; asserts the inherited consequence (**D5**). |
| Integration — HeyGen | Active template sets `language = 'en'`; project is `it` → body carries `avatar_persona.language = 'it'` | `tests/Unit/C7a/HeygenProviderTest.php:106-150` inverts (`:112` sets it, `:149` asserts it wins). `:249-276` (project-language sourcing) **must stay green untouched**. |
| Integration — Tavus | **By path**: `properties.language === 'italian'` **and** top-level `language` absent | `Http::fake()` capture. **A test that passes with the value at the top level does not satisfy D2** and must be rejected in review (Risk 3). |
| Integration — Tavus null path | `$ctx->language === null` → `properties.language` from `interview.tavus.language` | Mirrors `HeygenProviderTest.php:271-275`'s existing null-ctx case (**D4**). |
| Integration — phrases | `end_phrase`/`final_phrase` follow the project when `participant.language` is `null`, unsupported (`fr`), and divergent (`en` on an `it` project) | `tests/Feature/C7a/InterviewStartPhrasesTest.php` — the `phrasesParticipant()` helper (`:86-94`) re-keys onto project language; `:128`, `:152`, `:175`, `:201` rewrite. Both fields asserted **non-empty** in all three cases (Risk 8, `spec.md:295-296`). |
| Integration — demo seed | `beai:demo-seed` completes; every seeded template validates clean; the renamed Tavus template exists | `tests/Feature/Demo/*`; `ProjectCompetenciesTest.php:79` is the existing guard and fails RED if **D5**'s order is broken. |
| Integration — portability | Export/import round-trips with no `language`; a **pre-change** document is rejected naming `language` | `tests/Feature/C14/AvatarTemplatePortabilityTest.php:44`, `:170` update. The rejection is asserted, not worked around (**D6**, F11). |
| Migration | Maximal fixture: every field-spec key **plus** `language`, both providers, active **and** inactive rows, **two organizations** → `language` gone, **every other key intact** | Dedicated migration test. This is the one-way risk (**D6**); the key-by-key survival assertion is mandatory, not a nicety. |
| Cross-tenant | Org A (`it`, active template setting `en`) and Org B (`en`, no template) → each `/start` carries its own project's language; A never influences B | `config.yaml rules.specs` requires a dedicated isolation scenario. |
| Cross-project | Two projects of the **same** org, `it` and `en`, one active template → two different avatar languages | The headline success criterion. |
| Backoffice unit | The template form renders no language control for either provider, and no raw i18n key appears | `tests/unit/components/organisms/AvatarTemplateForm.spec.ts` with a spec fixture lacking `language`. |
| Config regression | `config('interview.heygen.language')` still resolves after the demo key is removed | Guards F7's near-twin deletion. The existing null-`$ctx` case `HeygenProviderTest.php:271-275` **already fails red** if `:83` is deleted by mistake — no new test required, but the PR description must name it as the guard. |
| Comment corrections (**D8**) | **No new test.** The five census claims are unfalsifiable in CI by construction | Each replacement instead states a guarantee an existing named test already pins, and cites it (**D8**, *Can anything cheap prevent a sixth?*). Review checks the citation, not a new assertion. |

**Coverage.** `api` holds the 85% gate. The provider merge path is not a "correctness-critical zone"
by the CLAUDE.md list, but the migration touches every tenant's stored configuration and is written to
the 95% standard.

---

## Migration / Rollout

1. **Pre-deploy (blocking on a human, not on this design).** Query production for active
   `avatar_templates` whose `config` carries `language` — open question 1. A non-zero count means at
   least one live avatar changes its spoken language on deploy and the release note says so. This is a
   **verification step**, not a decision gate: the outcome changes the release note, never the code.
2. **Reconfirm `properties.language` against the live Tavus contract** during apply (Risk 4). If Tavus
   accepts both paths, the demo-proven one still wins and the code comment must say **why**.
3. **Merge `api`** → migration runs on deploy, unscoped, all organizations (**D6**).
4. **Merge `backoffice`** immediately after (**D9**). Never the reverse.
5. **Wrapper commit** pinning both submodule pointers; SemVer patch/minor per `docs/git-flow.md`.
6. **`beai:demo-seed`** re-run in non-production to confirm the renamed Tavus template and clean
   validation.
7. **Release note** — mandatory, not optional: templates no longer control the avatar's language; a
   template previously used to override it loses that ability by ratified decision; template JSON
   exported before this release must have its `language` line removed before re-import (F11).

Rollback: **D9**. The code and the migration are separate revertible units, and only one of them is
actually revertible.

---

## Open Questions

Both carried forward from the proposal, unanswered **by design**. Neither blocks implementation.

- [ ] **Does any real tenant have an active avatar template with a language set?** Not answerable from
      this repository — no production database was queried and none is reachable. Established: the code
      supports and actively seeds that state (F1). Determines whether this ships with a release note or
      silently. **Pre-deploy verification, not a design gate** (step 1 above).
- [ ] **Should `participants.language` exist at all?** BEAI holds no candidate contact data (ratified
      decision #8) and the calling system owns scheduling (#5). **D7** swaps the source of two response
      fields and nothing else. Whether the column should exist, whether
      `M2m/ParticipantController.php:53` should validate against `supported_locales`, and what
      `EntryLinkMinter`'s `$lang` override argument (`:72`) is for are **three product decisions**,
      explicitly out of scope, and worth scheduling as their own change rather than leaving to drift.

No question blocks `sdd-tasks`. All four proposal decisions (D1–D4 there) are RATIFIED; the ten
decisions above are this design's, and none re-opens them.
