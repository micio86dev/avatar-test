# Verification Report

**Change**: avatar-language-follows-project
**Version**: N/A (delta specs, no version field)
**Mode**: Strict TDD (config: `strict_tdd: true`)
**Shipped**: `api` v0.26.1 (`010acbe`, fix release on top of v0.26.0), `backoffice` v0.14.0 (`fa622db`, unchanged since prior pass). Submodule pointers confirmed against `git submodule status` and `git log`.

This is a **re-verification** of a prior PASS-WITH-WARNINGS report (3 CRITICAL, 5 WARNING, 2 SUGGESTION). All findings from that pass were independently re-checked against the `fix/avatar-language-verify` branch (`951a463` → `010acbe`), not taken on the coordinator's word.

## Independent re-verification method

Beyond reading the diff, each of the two highest-risk fixes was **actively falsified**: the shipped code was temporarily reverted to the exact defect it claims to fix, the relevant test was re-run to confirm it fails, then the file was restored and `git status`/full-suite-pass confirmed a clean, unmodified tree.

1. Reverted `TavusProvider.php`'s `properties.language` write to top-level `language` (the exact D2 defect) → `Tavus writes the project language NESTED under properties, never top-level` **failed** (`Failed asserting that null is identical to 'italian'`) → reverted, clean diff.
2. Changed the migration's strip key from `'language'` to `'not_language_at_all'` → `StripTemplateLanguageMigrationTest` **failed** (`Expecting [...] not to have key 'language'`) → reverted, clean diff.

Both fixes are genuinely load-bearing, not cosmetic.

## Completeness

| Metric | Value |
|---|---|
| Tasks total (excluding close-out) | 33 |
| Tasks complete (checked `[x]`) | 33 |
| Close-out | 4.1 now checked `[x]`; 4.2/4.3 correctly still unchecked (pre-deploy check + archive genuinely pending) |
| Tasks checked but NOT actually delivered | **0** (both previously-found over-marks — 1.9, 1.11 — are now true) |

## Build & Tests Execution

**Backend** — `php -d memory_limit=2G artisan test --parallel` (real Postgres, `DB_CONNECTION=pgsql`), run independently, twice (before and after the falsification exercise, tree identical both times):
```
2000 tests, 1995 passed, 5 skipped, 0 failed
Lines: 94.03% (6298/6698) — matches the coordinator's claimed "1995 passing, 5 skipped, 0 failed, 94.0%"
```
**Backoffice** — not re-run: `git log`/`git status` confirm `backoffice` is byte-identical to the previously-verified `fa622db` (v0.14.0); no commits landed since the prior pass. Prior result (755/755 passed) stands.

## Prior CRITICAL findings — all 3 verified RESOLVED

### C-1 (was CRITICAL) — stale docblocks in `InterviewController.php`
`git diff 33d450a..010acbe` shows all four locations corrected:
- `:950` → *"resolved for the PROJECT's language with a platform-default fallback"* + new parenthetical explaining D7 and the unvalidated-M2M-input reasoning
- `:956` → `@param string|null $language The PROJECT's language...`
- `:1011` (`resolveCompletionPhrases` docblock) → *"Use the PROJECT's language when a phrase file exists for it."*
- `:1019` → `@param string|null $language The PROJECT's language.`

`rg -n "participant's language" --type php` across the full repo returns **zero** matches. ✅ **RESOLVED.**

### C-2 (was CRITICAL) — no Tavus null-`$ctx` / explicit-override test
Three tests added to `AvatarLanguageTest.php` (the coordinator described two; a third closes the same-org isolation WARNING — see below):
1. `Tavus writes the project language NESTED under properties, never top-level` — full `/api/candidate/interview/start` request, active template asking for `en`, project at `it`, asserts `properties.language === 'italian'` AND `not->toHaveKey('language')`. **Falsified live** (see above) — genuinely catches the D2 path defect.
2. `Tavus falls back to the configured default when the caller supplies no language` — Reflection-invokes `platformDefaultConversationFields(null)` directly and asserts `properties.language === 'english'` off `interview.tavus.language` config. Functionally mirrors HeyGen's null-ctx test (same claim: null context → config default), though by a different mechanism (direct method invocation vs. captured HTTP body) — HeyGen's equivalent captures the token body through a full `issue()` call. Not a byte-for-byte mirror, but it exercises the real production method and is not vacuous.
3. `two projects in ONE organization each get their own language, despite one shared template` — new, closes the design's explicitly-required "same org, two projects" isolation scenario (was WARNING 6 previously).

All three run through the real `TavusProvider`/`InterviewController` code, avoid the `Http::assertSent`-closure trap (direct capture pattern), and were confirmed passing in the full suite run. ✅ **RESOLVED** — the explicit-override branch (the one that actually proves a live project's language reaches Tavus) is now covered at the feature level, and falsified in this pass.

### C-3 (was CRITICAL) — no `apply-progress` artifact
`openspec/changes/avatar-language-follows-project/apply-progress.md` now exists (3.3K). Contains: a Releases table, a 6-cycle RED→GREEN table for PR1/PR2, a "Superseded tests" section (6 inverted tests + 2 bilingual-fixture repairs named), and a "Defects found in my own tests, before they shipped" section covering both the `Http::assertSent` trap and the migration-fixture duplication — recorded rather than silently fixed, as requested. ✅ **RESOLVED**, with one gap noted below (SUGGESTION).

## Prior WARNING findings — status

| # | Finding | Status |
|---|---|---|
| 4 | D8 citation mandate unhonoured at all 5 sites | ✅ **RESOLVED** — `HeygenProvider.php:187`, `TavusProvider.php:83-84`, `ActiveTemplateResolver.php:12-15`, `config/interview.php:120-122` now each name a test (`HeygenProviderTest`'s platform-default cases, `ProviderContractFixtureTest`'s golden body, the new null-context case). See SUGGESTION below re: comment grammar quality. |
| 5 | Migration RED fixture duplicated SQL instead of executing the real migration | ✅ **RESOLVED** — `runLanguageStripMigration()` now `require`s the migration file and calls `$migration->up()`. **Falsified live** (see above): breaking the real migration's strip key now fails the test, proving the old "cannot drift" claim is now actually true. |
| 6 | "Two projects, same org, one template" isolation scenario untested | ✅ **RESOLVED** — new third test in `AvatarLanguageTest.php` (see C-2 above). |
| 7 | Delta spec's literal "`language` key → `unknown` (422), both providers" scenario not tested by name | ⚠️ **STILL OPEN** — not addressed by this fix release; `ProviderFieldSpecTest.php`'s unknown-key test still uses the typo key `avatarID`, not `language`. Behaviourally covered by the generic spec-driven mechanism; not a regression, just not re-checked/fixed. Downgraded to SUGGESTION — low value to chase given the generic mechanism test already exists and D1/D5 structurally guarantee it. |

## Census statement sweep (repeat check)

Full-repo grep for every phrasing variant used in the original 5/6/8-site count (`no org has one`, `no organization has`, `EVERY existing organization`, `organization is in the moment`, etc.) across `api/` and `openspec/` returns **zero** unaddressed hits. The single remaining occurrence — `openspec/specs/interview-session/spec.md:1508` ("a template no organization had") — is the **main spec**, explicitly deferred to `sdd-archive` by task 2.11 and task 4.3 ("merge both delta specs, including the `spec.md:1278` correction"); it is not gated by this fix release and is accurately tracked as pending. ✅ No new or missed census statements found.

## Assertion Quality — new tests

All three new `AvatarLanguageTest.php` tests use the same safe pattern as the previously-fixed tests (direct capture via closure side-effect + explicit assertion on the captured variable, or direct return-value assertion via Reflection) — none uses `Http::assertSent()`/`assertNotSent()` with a broad closure. No recurrence of the trap. ✅ Confirmed via source read and the live falsification test above (test genuinely fails when the code regresses).

## tasks.md accuracy

`tasks.md` is otherwise **unchanged** from the prior pass except task 4.1 (`sdd-verify`) is now checked. Tasks 1.13 and 2.10 still report the PR1/PR2-era count ("1992 passing, 94.0%") — now stale relative to the current true count (1995/2000, 94.0%) since 8 tests were added in the subsequent, unlabeled `fix/avatar-language-verify` branch with no corresponding task entry. This is not a false "done" claim (those tasks correctly describe the state as of PR1/PR2 completion) but the fix release itself is **not documented anywhere in tasks.md** — no PR 4 / addendum section records what `951a463`/`010acbe` changed, beyond what `apply-progress.md` and this report capture. Flagged as SUGGESTION, not blocking.

## Issues Found (this pass)

### CRITICAL
None.

### WARNING
None carried forward as WARNING at full severity — WARNING 7 downgraded to SUGGESTION (low-value gap, structurally covered).

### SUGGESTION
1. **`HeygenProvider.php:187` and `TavusProvider.php:83-84` — the D8 citation text was inserted mid-sentence, producing broken grammar.** `HeygenProvider.php:187`: *"...AvatarTemplate. no organization is required to have one. Pinned by HeygenProviderTest's platform-default cases: they fail loudly if the fallback stops supplying an identity., so `$templateFields` was `[]`..."* — stray `.,` and a run-on. `TavusProvider.php:83-84` similarly: *"...one. Pinned by ProviderContractFixtureTest's golden body and AvatarLanguageTest's null-context case. today, so that mapping returned `[]`..."* — "today," now dangles as an orphaned fragment. The citations are accurate (both named tests do pin the claimed guarantee) and the false census claim is gone, but a follow-up pass should re-flow these two sentences. `ActiveTemplateResolver.php` and `config/interview.php`'s citation edits read cleanly by contrast.
2. **`apply-progress.md` documents PR1/PR2's original 6 RED→GREEN cycles but does not add cycle entries for the fix release's own new work** (the 3 new `AvatarLanguageTest.php` tests, the 4 docblock corrections, the 5-site D8 citations) as discrete RED→GREEN cycles — only the two self-found defects (assertSent trap, migration duplication) are documented in the "Defects found in my own tests" section. Not blocking; the substance is verifiable via `git diff` regardless.
3. **`tasks.md` doesn't record the fix release itself** — no task/PR entry for `fix/avatar-language-verify` (`951a463`→`010acbe`); tasks 1.13/2.10 report stale pre-fix suite counts.
4. Delta spec's literal "`language` key → `unknown` for both providers" scenario (previously WARNING 7) remains untested by name — downgraded, see table above.
5. Pre-existing typo `HegenProvider` (missing "y") at `config/interview.php:70` — still present, not introduced by this change, cosmetic only.

## Verdict

**PASS.**

All 3 CRITICAL findings from the prior pass are genuinely resolved — verified independently via `git diff`, full-suite re-execution (2000 tests, 1995 passed, 5 skipped, 0 failed, matching the coordinator's claim exactly), and live falsification of the two highest-risk fixes (the Tavus path test and the migration fixture now both fail when the underlying defect is reintroduced, proving they are not vacuous). All 3 previously-unprompted findings (migration fixture duplication, D8 citations, same-org isolation test) are also resolved, with one citation-grammar nit and one remaining low-value spec-scenario gap left as SUGGESTIONs.

**`sdd-archive` MAY proceed.** No CRITICAL or WARNING items remain. The 5 SUGGESTIONs above are cosmetic/documentation-completeness items that do not block archive; recommend folding the two dangling-sentence corrections (SUGGESTION 1) into whatever change touches those files next, and noting the fix release in `tasks.md`'s history before or during archive for traceability. Task 4.2 (pre-deploy real-tenant check) and 4.3 (`sdd-archive` itself, merging the delta specs including the `spec.md:1278` correction) remain correctly unchecked and are the only genuinely open items.
