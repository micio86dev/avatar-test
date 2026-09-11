# Tasks: Database-Driven Conversation Prompts

## Review Workload Forecast

| Field | Value |
|-------|-------|
| Estimated changed lines | ~1580 authored total across 6 PRs; largest slice ~380 (PR5), none over 400 |
| 400-line budget risk | Medium — PR5 sits close to the cap and is the risk concentration |
| Chained PRs recommended | Yes |
| Suggested split | PR1 → PR2 → PR3 → PR4 → PR5 → PR6 (design's six slices) |
| Delivery strategy | auto-chain |
| Chain strategy | feature-branch-chain |

```text
Decision needed before apply: No
Chained PRs recommended: Yes
Chain strategy: feature-branch-chain
400-line budget risk: Medium
```

Tracker branch: `feature/db-driven-conversation-prompts` (targets `develop`; only this branch merges).
PR1 → tracker. PR2 → PR1's branch. PR3 → PR2's. PR4 → PR3's. PR5 → PR4's. PR6 → PR5's.
**PR5 (composer cut-over) MUST NOT be combined with any other slice** — it deletes the heredocs, changes `compose()`'s signature, touches ~20 test call sites, and is gated entirely on byte identity.

### Suggested Work Units

| Unit | Goal | Likely PR | Focused test command | Runtime harness | Rollback boundary |
|------|------|-----------|----------------------|-----------------|-------------------|
| 1 | Golden byte-identity harness, captured pre-change | PR 1 | `php artisan test --filter=SystemPromptGoldenTest` | N/A — pure unit fixture capture, no runtime scenario | Delete test + 5 fixtures; no other code touched |
| 2 | 4 migrations + models + enum, index invariants proven | PR 2 | `php artisan test --parallel --filter=ConversationPrompt` | `php artisan migrate` / `migrate:rollback` against local Postgres | `migrate:rollback` drops 4 tables + 1 column; nothing reads them yet |
| 3 | Resolver + placeholder contract + VO + exception | PR 3 | `php artisan test --parallel --filter=PromptTemplateResolver` | N/A — composer/controller not wired yet, no live /start path exercised | Delete resolver/VO/contract/exception files; PR2 tables unused, no regression |
| 4 | Seeder — verbatim EN + human-authored IT | PR 4 | `php artisan test --parallel --filter=ConversationPromptTemplateSeeder` | `php artisan db:seed --class=ConversationPromptTemplateSeeder` (run twice, assert no duplication) | Delete seeder + its test; no revision ever activated outside local |
| 5 | Composer cut-over: heredocs deleted, `$templates` param, durable stamp | PR 5 | `php artisan test --parallel --filter=SystemPromptGoldenTest` (must stay byte-identical) then full `php artisan test --parallel` | `POST /api/interview/start` against a seeded+activated local revision | Revert branch only — migrations additive, `config/conversation.php` keeps its key shape so a revert composes from PHP again |
| 6 | Per-competency override rendering | PR 6 | `php artisan test --parallel --filter=Override` | `POST /api/interview/start` for a competency with a seeded override row | Revert `assemblePrompt()` override-insertion hunk; no override seeded by default so behavior is unaffected |

---

## Phase 1: PR1 — Golden Byte-Identity Harness

Branch `feature/db-driven-conversation-prompts/01-golden-harness` → target tracker. Est. ~140 lines + 5 generated fixtures (fixtures excluded from authored budget, included in snapshot identity). Test: `php artisan test --filter=SystemPromptGoldenTest`.

- [ ] 1.1 RED: Write `tests/Unit/C8/SystemPromptGoldenTest.php` covering the 5 fixed combinations (en/budget4/no-nudge/no-phrase; en/2/nudge/phrase/min4; en/0-clamped/phrase/min4 singular floor; it/4/nudge/phrase/min4/2-authored; en/2/phrase/6-authored no nudge), asserting `expect($text)->toBe($fixture)` — fails, fixtures do not exist.
- [ ] 1.2 GREEN: On the pre-change tree, run with `PROMPT_GOLDEN_UPDATE=1 php artisan test --filter=SystemPromptGoldenTest` to capture `tests/Fixtures/Conversation/prompts/{1..5}.txt` verbatim from the current heredoc composer; commit the fixtures.
- [ ] 1.3 GREEN: Re-run `php artisan test --filter=SystemPromptGoldenTest` without the env flag; confirm pass with zero diff.
- [ ] 1.4 Docblock: state the golden is a characterization test (green on write, not RED→GREEN for new behavior) and that `PROMPT_GOLDEN_UPDATE` must never be used again — any later diff touching `tests/Fixtures/Conversation/prompts/` is byte drift and must be rejected in review.

## Phase 2: PR2 — Schema + Models

Branch `.../02-schema-models` → target PR1 branch. Est. ~380 lines. Test: `php artisan test --parallel --filter=ConversationPrompt`.

- [ ] 2.1 RED: `tests/Unit/Database/ConversationPromptRevisionActiveIndexTest.php` — a second real duplicate INSERT with `is_active=true` raises Postgres `23505` — fails, table absent.
- [ ] 2.2 GREEN: migration `create_conversation_prompt_revisions_table.php` — `revision varchar(64) UNIQUE`, `is_active bool NOT NULL DEFAULT false`, `content_sha256 char(64)` + CHECK `~'^[0-9a-f]{64}$'`, `notes text NULL`, timestamps, `CREATE UNIQUE INDEX conversation_prompt_revisions_one_active … WHERE is_active`.
- [ ] 2.3 RED: `tests/Unit/Database/ConversationPromptOverridePartialIndexTest.php` — duplicate role-specific override AND duplicate role-less override each raise `23505` (two real duplicate INSERTs) — fails, table absent.
- [ ] 2.4 GREEN: migration `create_conversation_prompt_sections_table.php` — `section_key varchar(32)` + CHECK enumerating the 17 keys, `body jsonb NOT NULL` translatable, `UNIQUE (revision_id, section_key)`, FK `revision_id` cascadeOnDelete.
- [ ] 2.5 GREEN: migration `create_conversation_prompt_overrides_table.php` — nullable `role_id` FK cascade, `competency_id` FK cascade, `body jsonb` translatable, partial index pair (`WHERE role_id IS NOT NULL` / `WHERE role_id IS NULL`) + plain `(revision_id, competency_id)` lookup index.
- [ ] 2.6 RED: `tests/Arch/Conversation/ConversationPromptActivationAppendOnlyArchTest.php` mirroring `AuditLogAppendOnlyArchTest` — no `update()`/`delete()`/`save()` call against `ConversationPromptActivation` anywhere in `app/` — fails, model absent.
- [ ] 2.7 GREEN: migration `create_conversation_prompt_activations_table.php` — `revision_id` FK **restrictOnDelete**, `actor_id` nullable FK users nullOnDelete, `action varchar(16)` CHECK IN ('activated','deactivated'), `content_sha256 char(64)`, `created_at useCurrent()` only (no `updated_at`), index `(revision_id, created_at)`.
- [ ] 2.8 GREEN: migration `add_conversation_prompt_version_to_interview_sessions_table.php` — `conversation_prompt_version varchar(255) NULL`.
- [ ] 2.9 GREEN: models `ConversationPromptRevision`, `ConversationPromptSection` (spatie translatable `body`), `ConversationPromptOverride` (spatie translatable `body`), `ConversationPromptActivation` (append-only, `$timestamps` limited to `created_at`).
- [ ] 2.10 GREEN: `app/Enums/PromptSectionKey.php` — PHP backed enum, all 17 cases (`header_intro`, `opening_notice`, `label_coverage`, `label_override`, `label_star`, `star`, `label_followup`, `budget`, `label_nudge`, `nudge`, `label_authored`, `authored_preamble`, `label_advance`, `advance_floor_one`, `advance_floor_many`, `advance_with_phrase`, `advance_without_phrase`).
- [ ] 2.11 Verify: `php artisan migrate` clean on local Postgres, `php artisan migrate:rollback` reversible; `php artisan test --parallel --filter=ConversationPrompt` green.

## Phase 3: PR3 — Resolver + Placeholder Contract

Branch `.../03-resolver-contract` → target PR2 branch. Est. ~300 lines. Test: `php artisan test --parallel --filter=PromptTemplateResolver`. Composer is NOT touched in this slice.

- [ ] 3.1 GREEN: `app/Exceptions/Conversation/PromptTemplateUnresolvableException.php extends CompositionException`.
- [ ] 3.2 GREEN: `app/DTOs/Conversation/PromptTemplateSet.php` — readonly VO (`revisionId`, `revisionLabel`, `resolvedSha256`, `sections` array, `override`), `section(PromptSectionKey $key)` throws if absent.
- [ ] 3.3 GREEN: `app/Support/Conversation/PromptSectionContract.php` — shared validator: (a) every required placeholder present ≥1×, (b) no unknown `:token` survives, (c) no leading/trailing newline; usable at both save-time and composition-time.
- [ ] 3.4 RED: `tests/Unit/Support/Conversation/PromptSectionContractTest.php` — `advance_with_phrase` missing `:advance_phrase` refused; unknown `:token` refused; leading/trailing newline refused; `header_intro` missing `:competency_code` refused; override `body` carrying ANY placeholder refused — fails, contract absent.
- [ ] 3.5 RED: `tests/Unit/Services/Conversation/PromptTemplateResolverTest.php` — no active revision → `PromptTemplateUnresolvableException`; missing section row → same; missing locale translation (M-2 hard-fail) → same; role-specific override wins over role-less; role-less override applies when no role-specific exists; no override row → `override = null` — fails, resolver absent.
- [ ] 3.6 GREEN: `app/Services/Conversation/PromptTemplateResolver.php::resolveActive(locale, competencyId, roleId)` — loads active revision, 17 sections, `hasTranslation` check per section, override precedence, contract application, canonical-JSON `resolvedSha256` (D-9: `{"revision":id,"locale":loc,"sections":{key:body sorted ASC},"override":string|null}`, `JSON_UNESCAPED_UNICODE|JSON_UNESCAPED_SLASHES|JSON_THROW_ON_ERROR`); cache keyed by immutable `revisionId` (no invalidation logic).
- [ ] 3.7 Verify: `php artisan test --parallel --filter=PromptTemplateResolver` green; golden test (PR1) still byte-identical — nothing wired into the composer yet.

## Phase 4: PR4 — Seeder (Verbatim EN + Human-Authored IT)

Branch `.../04-seeder` → target PR3 branch. Est. ~200 lines. Test: `php artisan test --parallel --filter=ConversationPromptTemplateSeeder`.

> **HUMAN-BLOCKING — this PR cannot merge without it.** The Italian section text needs a human author, not a machine translation. Flag task 4.2 to the user before this slice is considered done.

- [ ] 4.1 RED: `tests/Feature/Database/ConversationPromptTemplateSeederTest.php` — all 17 section keys × `{en,it}` present after seeding; each body passes `PromptSectionContract`; re-running the seeder is idempotent (`firstOrCreate` keyed on `revision`, verifies `content_sha256` on a repeat run, writes nothing, never mutates a referenced revision) — fails, seeder absent.
- [ ] 4.2 **BLOCKING, HUMAN INPUT REQUIRED**: obtain human-authored Italian text for all 17 sections (institutional avatar chrome, not BARS anchors — not blocked on ROADMAP OQ-6, but MUST NOT be machine-translated). Do not proceed to 4.3 without it.
- [ ] 4.3 GREEN: `database/seeders/ConversationPromptTemplateSeeder.php` — seeds EN copied byte-for-byte from the pre-change heredocs/literals + the human-authored IT text; revision label e.g. `conv-2026-09-04`; never sets `is_active` outside local.
- [ ] 4.4 GREEN: seeder writes zero override rows by default (every competency starts with no override; default composition stays unchanged).
- [ ] 4.5 Verify: `php artisan test --parallel --filter=ConversationPromptTemplateSeeder` green; `php artisan db:seed --class=ConversationPromptTemplateSeeder` run twice locally, confirm no row duplication and no mutation of the referenced revision.

## Phase 5: PR5 — Composer Cut-Over (RISK CONCENTRATION — isolate, do not combine)

Branch `.../05-composer-cutover` → target PR4 branch. Est. ~380 lines. Test: `php artisan test --parallel --filter=SystemPromptGoldenTest` (must stay byte-identical), then `php artisan test --parallel`.

- [ ] 5.1 RED: convert `tests/Unit/C8/SystemPromptComposerTest.php`'s ~20 positional calls to named args with a `templates()` helper building a `PromptTemplateSet`; run suite — fails against the still-old `compose()` signature (expected RED).
- [ ] 5.2 RED: new case — a `PromptTemplateSet` whose `advance_with_phrase` body lacks `:advance_phrase` throws `CompositionException` at COMPOSITION time (independent of save-time contract) — fails, guard not yet wired into `compose()`.
- [ ] 5.3 RED: new case — across all 5 golden combinations, no unbound `:token` and no bare `end_phrase` literal survives into composed text — fails until the post-interpolation sweep exists.
- [ ] 5.4 GREEN: modify `SystemPromptComposer::compose()` — `PromptTemplateSet $templates` FIRST param; delete every heredoc/private literal; each builder pulls its body via `$templates->section(...)`; interpolate with `strtr()` longest-key-first (never chained `str_replace`); post-interpolation sweep throws on any surviving `/:[a-z_]{2,}/`.
- [ ] 5.5 GREEN: extend `promptVersion()` to `{config}+r{revisionId}.{sha12}` (D-9); update the method's docblock.
- [ ] 5.6 GREEN: `InterviewController::composePromptForCompetency()` — resolve the `PromptTemplateSet` via `PromptTemplateResolver` INSIDE the existing try block (before `createOrResumeSession()`/provider `issue()`); catch `PromptTemplateUnresolvableException` alongside the existing catches, mapping to `composition_error` / 422 with zero InterviewSession rows and zero provider calls.
- [ ] 5.7 GREEN: write `interview_sessions.conversation_prompt_version` at `issue()` time (same call site as `system_prompt_chars`); write-once, never overwrite a non-null value with null.
- [ ] 5.8 RED→GREEN: `tests/Feature/C8/ConversationPromptActivationDoesNotAlterComposedInterviewTest.php` — compose → stamp on revision R1 → activate R2 → R1's stamped `conversation_prompt_version` AND its re-resolved text are byte-identical to what was composed before R2's activation.
- [ ] 5.9 GREEN: update `config/conversation.php` docblock — `prompt_version` is now a PREFIX of the full stamp, not the whole value.
- [ ] 5.10 CRITICAL VERIFY: `php artisan test --parallel --filter=SystemPromptGoldenTest` — every fixture from PR1 stays byte-identical; `tests/Fixtures/Conversation/prompts/*` must show zero diff in this PR's changeset.
- [ ] 5.11 Verify: `php artisan test --parallel`, `vendor/bin/pint --test`, `vendor/bin/phpstan analyse --memory-limit=1G` all clean.

## Phase 6: PR6 — Per-Competency Override Rendering

Branch `.../06-override-rendering` → target PR5 branch. Est. ~180 lines. Test: `php artisan test --parallel --filter=Override`.

- [ ] 6.1 RED: `tests/Unit/C8/PromptOverrideRenderingTest.php` — override text renders after COVERAGE TOPICS and before STAR COVERAGE PROTOCOL, changing nothing else; no override row → output identical to skipping the override step entirely; role-specific override does not apply to a different role; role-less override applies to every role; when both exist, role-specific wins and is never concatenated with the role-less one — fails, override not rendered.
- [ ] 6.2 GREEN: wire `label_override` (`COMPETENCY-SPECIFIC GUIDANCE:`) from `PromptSectionKey` into `assemblePrompt()`.
- [ ] 6.3 GREEN: `SystemPromptComposer::assemblePrompt()` inserts the override section (label + body) at the fixed position when `$templates->override !== null`; single append, no concatenation (resolver already guarantees at most one via role precedence).
- [ ] 6.4 Verify: `php artisan test --parallel --filter=Override` green; golden fixtures (PR1) still untouched since no competency ships a seeded override by default; full `php artisan test --parallel` green; coverage ≥85% overall, ~95% on `SystemPromptComposer`/`PromptTemplateResolver`; `vendor/bin/pint --test` and `vendor/bin/phpstan analyse --memory-limit=1G` clean.

---

## Verification Commands (run before each PR is marked done)

- `php artisan test --parallel` — full Pest suite, from `api/`.
- `vendor/bin/pint --test` — style check (repo convention: fix with `vendor/bin/pint --format agent`, never merge with `--test` failing).
- `vendor/bin/phpstan analyse --memory-limit=1G` (CI) / `--memory-limit=2G` (local `composer analyse`) — Larastan.
- Per-slice focused command listed in each phase header above and in the Suggested Work Units table.
- This change adds no new public endpoint and does not alter `/start`'s response shape, so no OpenAPI/VERSION delta is expected — still re-run the standard `scramble:export` diff in PR5/PR6 to confirm.
