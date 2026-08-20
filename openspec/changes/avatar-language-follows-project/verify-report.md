# Verification Report

**Change**: avatar-language-follows-project
**Version**: N/A (delta specs, no version field)
**Mode**: Strict TDD (config: `strict_tdd: true`)
**Shipped**: `api` v0.26.0 (`88b522e`), `backoffice` v0.14.0 (`fa622db`), submodule pointers confirmed against `git submodule status`

## Completeness

| Metric | Value |
|---|---|
| Tasks total (excluding close-out) | 33 |
| Tasks complete (checked `[x]`) | 33 |
| Tasks incomplete | 0 (close-out 4.1–4.3 correctly left unchecked) |
| Tasks checked but NOT actually delivered | **2** (1.9, 1.11 — see CRITICAL) |

## Build & Tests Execution

**Backend** — `php -d memory_limit=2G artisan test --parallel` (real Postgres, `DB_CONNECTION=pgsql`, confirmed in `phpunit.xml`):
```
1997 tests, 1992 passed, 5 skipped, 0 failed
Lines: 94.03% (6298/6698) — matches tasks.md's claimed "1992 passing, 94.0%"
```
**Backoffice** — `bun run test:unit`:
```
98 test files, 755 tests, 755 passed, 0 failed
```
Both suites: ✅ PASSED, both coverage claims independently reproduced.

## Spec Compliance Matrix

| Requirement | Scenario | Test | Result |
|---|---|---|---|
| avatar-templates: mapper never emits language | Neither `TemplatePayload::heygen()`/`::tavus()` emits language for a config carrying a stale value | `TemplatePayloadTest.php` "neither provider mapping emits a language" | ✅ COMPLIANT |
| avatar-templates: field spec validation | `language` key → `unknown` (422), both providers | No test literally submits `language` as the unknown key (only a typo key `avatarID` is tested) | ⚠️ PARTIAL — covered structurally (ConfigValidator is spec-driven) but not by the literal scenario the spec names |
| interview-session: template can never override avatar language (HeyGen) | Active template sets `language:'en'`, project is `it` → avatar speaks `it` | `AvatarLanguageTest.php` "an active template CANNOT override..." | ✅ COMPLIANT |
| interview-session: Tavus platform default at correct PATH | No template, no `$ctx` language → `properties.language:'italian'`, nested | `ProviderContractFixtureTest.php` (exact-match golden fixture, catches wrong path) | ✅ COMPLIANT |
| interview-session: Tavus explicit `$ctx->language` wins over platform default | Project language flows through to `properties.language` (e.g. `en`→`english`), mirroring HeyGen's dual-branch test | **No test found anywhere in the suite** | ❌ UNTESTED (task 1.9 marked done) |
| interview-session: cross-tenant isolation | Org A's stale template language never reaches Org B's session | `AvatarLanguageTest.php` "one organization template never reaches another" | ✅ COMPLIANT |
| interview-session: same-org, two-project isolation | Two projects of the SAME org under ONE active template get different avatar languages | **No dedicated test** — only structurally guaranteed by D1 (mapper never emits language at all) | ⚠️ PARTIAL — design explicitly mandated this scenario, not delivered |
| interview-session: end_phrase/final_phrase source from PROJECT | Closing phrases resolve from project language, not participant | `AvatarLanguageTest.php` "the closing phrases come from the PROJECT" + `InterviewStartPhrasesTest.php` | ✅ COMPLIANT |
| D6 migration: one-way key-strip, key-by-key survival | Every other config key survives across two orgs/providers/active states | `StripTemplateLanguageMigrationTest.php` (3 tests, real Postgres) | ✅ COMPLIANT (see WARNING re: test independence) |

**Compliance summary**: 6/9 fully COMPLIANT, 3/9 PARTIAL/gapped.

## Correctness (Static Evidence)

| Design decision | Status | Notes |
|---|---|---|
| D1 — mapper is the load-bearing cut, allowlist is defence-in-depth (labelled) | ✅ Implemented | `TemplatePayload.php:36-54` no language emission; `HeygenProvider.php:59-60` comment correctly labels allowlist removal as "defence in depth" |
| D2 — Tavus writes `properties.language`, nested | ✅ Implemented | `TavusProvider.php:174-178`; golden fixture asserts full-body equality including the nested path |
| D3 — `TavusLanguage::forWire()` as a named, unit-tested class | ✅ Implemented | `app/Support/Provider/TavusLanguage.php` + `tests/Unit/Support/Provider/TavusLanguageTest.php` |
| D4 — `$ctx->language ?? config('interview.tavus.language')` | ✅ Implemented | `TavusProvider.php:174`, new config key `config/interview.php:137` |
| D5 — field spec drops `language`, `LANGUAGES` retired, demo seed intact | ✅ Implemented | `ProviderFieldSpecs.php` has no language FieldSpec, no `LANGUAGES` const; full Demo test suite (19 files) passed |
| D6 — one-way JSONB strip, `down()` documented no-op, `??` escaped operator | ✅ Implemented | Migration file correct; **but see WARNING — RED fixture duplicates SQL rather than executing the migration class** |
| D7 — closing phrases source from `$ctx->language`, zero new queries | ✅ Implemented (code) | `InterviewController.php:687,756` pass `$ctx->language` — **but see CRITICAL — the four docblocks task 1.11 claims to have corrected were never touched** |
| D8 — five comment sites corrected to state the invariant, cite a pinning test | ⚠️ Partially implemented | All 5 false "no org has one today"-style claims ARE removed (verified via `git diff`); **none of the 5 replacement comments cites the named pinning test the design/task mandated** |
| D9 — api merges before backoffice | ✅ Confirmed | `git log`: `feature/avatar-language-pr1`/`pr2` merged before `pr3`; `88b522e` (api) predates `fa622db` (backoffice) |
| F7 — twin config keys, correct one deleted | ✅ Confirmed | `interview.heygen.language` (`config/interview.php:83`) survives untouched; `interview.demo.heygen.language` correctly removed from the demo block |
| F8 — i18n removal path-scoped | ✅ Confirmed | Only `avatar_templates.field.language`/`.hint.language` removed; `projects.field.language`, `projects.form.help.language`, `participants.detail.language` all survive |
| F9 — `??` escaped jsonb operator | ✅ Confirmed | `database/migrations/2026_08_20_140000_...php:35` |
| F11 — pre-change exports unimportable | ✅ Accurately recorded | Consistent with `ConfigValidator` being spec-driven; documented in design.md and tasks.md 2.9 |
| Task 2.4 — `ConfigValidator`/`AvatarTemplatePortabilityController` need no edit | ✅ Confirmed | `git diff 1ed0dc9..33d450a --stat` shows neither file touched |
| Task 3.3 — openapi.json field-spec schema not regenerable | ✅ Confirmed | `/avatar-templates/field-specs` in `openapi.json` resolves to `{"data": {"type": "string"}}` — Scramble genuinely does not publish the shape |
| Open questions (real-tenant impact; `participants.language` future) | ✅ Accurately left OPEN | Not answered in proposal, spec, or design; task 4.2 correctly unchecked |

## Coherence (Design)

All 9 architecture decisions (D1–D9) and F1–F11 findings were checked against the shipped code. Every one is followed in substance. The two places design coherence breaks down are documentation-completeness, not architecture: D7's promised docblock correction and D8's promised test citation were both specified precisely and both silently dropped during implementation.

## Issues Found

### CRITICAL

1. **Task 1.11 is marked complete but its docblock-correction deliverable was never done.** `git diff 1ed0dc9..33d450a -- app/Http/Controllers/Candidate/InterviewController.php` shows exactly 2 changed lines (the two `buildSuccessResponse(...)` call-site arguments, `$participant->language` → `$ctx->language`). The task explicitly also required: *"Correct the four docblocks at `:744`, `:750`, `:791`, `:799`."* None were touched. Today the code reads:
   - `InterviewController.php:950` — *"resolved for the participant's language with a platform-default fallback"*
   - `InterviewController.php:956` — `@param string|null $language The participant's language (BCP-ish locale, may be null).`
   - `InterviewController.php:1011` — *"Use the participant's language when a phrase file exists for it."*
   - `InterviewController.php:1019` — `@param string|null $language The participant's language.`

   All four now describe behaviour the code no longer has — the exact "comment describes data state, not code guarantee" failure mode D8 was written to eliminate, reproduced one function down, in the same PR that fixed it elsewhere. A future maintainer reading only the docblock would reintroduce the `$participant->language` bug this change removes.

2. **Task 1.9 ("Null-`$ctx` fallback test for Tavus, mirroring HeyGen's existing one") is marked complete; no such test exists.** Exhaustive search (`TavusProviderTest.php`, `TavusProviderPayloadTest.php`, `ProviderContractFixtureTest.php`, `AvatarLanguageTest.php`) found zero assertions on `$ctx->language` explicitly overriding Tavus's `properties.language`. `AvatarLanguageTest.php` — the file whose docblock claims to cover "the avatar's spoken language" generically — tests **only HeyGen** in all 4 of its tests. The only Tavus language coverage is `ProviderContractFixtureTest.php`'s golden-fixture exact-match test, which exercises the null-`$ctx`→config-default branch (`'it'`→`'italian'`) but never the explicit-override branch. HeyGen's equivalent (`HeygenProviderTest.php:249-276`) tests both branches in one test — nothing "mirrors" it for Tavus. D2 was called "the strongest argument in the change" specifically because a path-only-and-not-source fix is a silent no-op; the override branch — the one that actually proves a live project's language reaches Tavus — is untested.

3. **No `apply-progress` artifact exists (Engram or filesystem).** Strict TDD is active (`openspec/config.yaml`). `mem_search` for `sdd/avatar-language-follows-project/apply-progress` returns nothing, and no equivalent file exists in `openspec/changes/avatar-language-follows-project/`. Per the strict-tdd-verify protocol this is a CRITICAL: the apply phase did not report the required "TDD Cycle Evidence" table. Mitigated in substance — independent verification via `git log`/`git diff` confirms RED-before-GREEN task ordering was followed and all cited tests exist and pass — but the required process artifact itself is missing.

### WARNING

4. **D8's "cite the pinning test" instruction was not followed at any of the 5 corrected comment sites.** Both the design (D8) and task 2.11 explicitly require each replacement comment to *"state a guarantee an existing named test already pins, and cite it"* (e.g. `HeygenProvider.php:180-183 → HeygenProviderTest.php:249-276`). `git diff` confirms all 5 false "no org has one today"-class statements were correctly rewritten to state an invariant instead of a census — but none of the 5 rewritten comments (`HeygenProvider.php`, `TavusProvider.php`, `ActiveTemplateResolver.php`, `config/interview.php` ×2 blocks) names a test file anywhere. The correction that matters (removing the false claim) landed; the mechanism meant to prevent recurrence did not.

5. **The migration's RED fixture (`StripTemplateLanguageMigrationTest.php`) duplicates the migration's SQL as a hand-copied string rather than executing the real migration class**, while its own comment claims the opposite: *"Re-run the migration's own statement rather than a hand-written copy, so the test cannot drift from the thing it protects."* Today the two strings are byte-identical (verified by direct comparison) — but the test literally is a hand-written copy; it does not `require` or execute `Migration::up()`. A future edit to the migration would not be caught by this test, contradicting the design's own claim that this fixture is "the only thing standing between a wrong filter and unrecoverable loss."

6. **Design's explicitly "Required isolation test" — two projects of the SAME organization under ONE active template, differing languages — was not delivered.** Only the cross-organization scenario (task 1.12) exists. Practical risk is low (D1 structurally guarantees the mapper never emits language regardless of project), but the design named this scenario specifically and it is absent from the suite.

7. **Delta spec's literal scenario — "a `language` key in submitted config is now `unknown` (422) for both providers" — is not covered by a test naming `language`.** The only "unknown key" test in `ProviderFieldSpecTest.php` uses a typo key (`avatarID`), not `language`. Behaviourally covered by the generic spec-driven mechanism (verified: `ConfigValidator` rejects any key absent from the FieldSpec list), but the spec asked for the scenario by name and it is not literally present.

### SUGGESTION

8. Pre-existing typo `HegenProvider` (missing "y") at `config/interview.php:70` — not introduced by this change (line untouched in the diff); cosmetic only.
9. `ActiveTemplateResolver.php`'s corrected comment reads slightly awkwardly post-edit ("...is not defensive coding — having no active template is a fully supported state, not an edge case — the moment this ships.") — the trailing clause no longer connects cleanly to the new sentence. Not a factual defect.

## TDD Compliance

| Check | Result | Details |
|---|---|---|
| TDD Evidence reported (apply-progress) | ❌ | No artifact found (Engram or filesystem) — see CRITICAL 3 |
| All tasks have tests | ⚠️ | 31/33 core tasks have verifiable test files; 1.9's claimed test does not exist |
| RED confirmed (tests exist) | ✅ (with 1 exception) | All cited test files exist except the Tavus null-ctx mirror (1.9) |
| GREEN confirmed (tests pass) | ✅ | Full suite: 1992/1997 passed, 0 failed |
| Triangulation adequate | ⚠️ | Tavus language path under-triangulated relative to HeyGen (see CRITICAL 2, WARNING 6) |
| Safety Net for modified files | ✅ | Pre-existing tests inverted in RED tasks, not silently deleted (verified via `git diff` on `TemplatePayloadTest.php`, `ProviderFieldSpecTest.php`, `AvatarTemplateApiTest.php`, `AvatarTemplatePortabilityTest.php`) |

**TDD Compliance**: 3/6 checks fully passed, 3/6 partial — primarily due to the missing formal artifact and the Tavus test gap.

## Assertion Quality

The `Http::assertSent()`-passes-on-any-request class of bug the user flagged as previously found and fixed in `AvatarLanguageTest.php` was checked and the fix holds: `langTokenBody()` pulls the single `/sessions/token` request's body out explicitly rather than using a closure inside `assertSent`. A systematic search of the full diff (`git diff 1ed0dc9..33d450a`) for the same shape in other touched test files found no recurrence.

**Assertion quality**: ✅ No tautologies, ghost loops, or the previously-fixed `assertSent`-closure trap found elsewhere in the diff.

## Verdict

**PASS WITH WARNINGS.**

The shipped runtime behaviour is correct and safe: every architecture decision (D1–D9) and finding (F1–F11) was independently verified against the actual source, both test suites pass in full (1992/1997 backend, 755/755 backoffice), and the highest-risk artifact — the one-way migration — is correctly implemented and covered (with the caveat in WARNING 5).

`sdd-archive` should **NOT** proceed until the 3 CRITICAL items are resolved:
- Fix the 4 stale docblocks in `InterviewController.php` (or downgrade task 1.11's checkbox and file a fast-follow) — this is a live, misleading documentation defect in the exact area (avatar language sourcing) this change exists to fix.
- Either add the missing Tavus explicit-override test (task 1.9) or downgrade its checkbox and record the gap explicitly.
- Produce (or explicitly waive, with reasoning) the missing `apply-progress` / TDD Cycle Evidence artifact required by Strict TDD mode.

None of the 3 CRITICALs are functional regressions — all are task-accuracy / documentation-completeness gaps — but archiving now would immortalize 2 false "done" claims in the historical record.
