# Proposal: Database-Driven Conversation Prompts

## Intent

The competency-agnostic half of the interviewer system prompt is hardcoded PHP heredocs and
concatenations inside `SystemPromptComposer`. Changing one word of how the avatar conducts an
interview is a code change, a review, a release and a `CONVERSATION_PROMPT_VERSION` bump —
so the fastest lever on interview quality is the slowest thing in the product to move.

There is also no way to say anything per competency. `framework_bars_indicators` already
carries per-competency content, but it says WHAT to assess (indicator + anchors), never HOW to
probe it. A competency needing a specific instruction ("for INN, insist on what was abandoned")
has nowhere to put it.

Success: prompt text is data, seeded verbatim from today's PHP, editable without a deploy,
layerable per competency — and every already-scored interview stays reproducible from its
stamped `prompt_version`.

## Scope

### In Scope

1. **Migrations** for two tables: a platform-level global template (`section_key`, `locale`,
   `body`, keyed by an immutable `revision`) and a per-role×competency override.
2. **Seeders** carrying the current hardcoded EN text into the template rows **verbatim**, plus
   the IT translations the hard-fail rule requires. Zero rewording in this change.
3. **A characterization test asserting the composed prompt is byte-identical before and after**
   — pinned against a golden captured from the pre-change composer. This is the change's
   primary gate; if it is red, nothing else matters.
4. **Template resolution at the CALL SITE** (`InterviewController::composePromptForCompetency()`),
   passed into `compose()` as an argument. The composer stays pure.
5. **Placeholder-contract guard** (save-time validation AND composition-time refusal).
6. **Immutable revisions** + content hash, so `prompt_version` still identifies exact text.
7. Spec deltas; PHPStan/Pint/coverage (~95% on composition) as usual.

### Out of Scope

- `framework_bars_indicators` — already DB-driven and working. Untouched.
- `api/lang/{en,it}/interview.php` — **deliberately stays on disk.** `end_phrase`/`final_phrase`
  are the frontend's sole source for `matchesEndPhrase()`; moving them is a three-repo change
  with a live completion-detection contract in the middle. `opening.*` belongs to
  `OpeningTextComposer`, a different composer with its own anti-leak guarantee. Separate change.
- **Backoffice authoring UI — DEFERRED.** The user's stated priority is the data layer. Editing
  in this change is seeder/console only; the API + UI is a later slice.
- **Per-tenant prompt templates — DEFERRED** (see Tenancy below). Additive if ever ratified.
- `potential` assessment type; `OpeningTextComposer`; section-REPLACE override mode.

## Capabilities

### New Capabilities

- `conversation-prompt-templates`: platform-level, revision-immutable, locale-keyed prompt
  section storage; resolution, placeholder contract, and the versioning/traceability rules.

### Modified Capabilities

- `interview-conversation`: "System-Prompt Composition — Pure Function" gains DB-resolved
  template sections as a passed-in input; `prompt_version` becomes a template-revision
  identifier rather than a config string; new composition-time refusal conditions.
- `framework-catalog`: adds the per-role×competency prompt-override surface alongside BARS
  indicators, under the same global/versioning rules.

## Approach

**Two layers, one composition.**

Layer 1 — global template. One row per (`revision`, `section_key`, `locale`). Section keys map
1:1 onto today's private builders: `header_intro`, `opening_notice`, `star`, `budget`, `nudge`,
`authored_preamble`, `advance_with_phrase`, `advance_without_phrase`, plus the section labels
`assemblePrompt()` emits. The mapping is mechanical on purpose: it is what makes the
byte-identity test achievable.

Layer 2 — per-competency override, **APPEND only**, rendered as one additional named section
placed after COVERAGE TOPICS and before the STAR protocol. Chosen over REPLACE because a
row able to replace `advance_*` or the same-episode constraint can delete a safety invariant
per competency, which is precisely the failure mode below; and over "both" because two modes
double the guard surface for a need nobody has stated yet. REPLACE stays deferred, not denied.

**Purity is preserved by construction.** A `PromptTemplateResolver` loads and caches rows at the
call site and hands `compose()` a `PromptTemplateSet` value object. This is the pattern the
controller already uses and documents for authored questions: "loaded here because this is the
one place that already knows both the project and the competency; the composer stays a pure
function of what it is handed." Injecting a repository into the composer is rejected — its
purity is an asserted correctness invariant, not a style preference.

**Versioning.** A revision is immutable once any interview has been composed against it;
"editing" publishes a new revision. `prompt_version` becomes the revision id plus a content
hash over the resolved section set, so a stamped value still names exact bytes. An edit MUST
NOT retroactively alter the prompt of an interview already composed or scored. The existing
blank-version refusal is preserved and extended: an unresolvable revision fails composition
rather than stamping something untraceable.

**Locale: HARD-FAIL, no fallback.** A template row missing the project locale throws, matching
the M-2 `AnchorTranslationMissingException` rule for anchors. A half-English prompt is the
mixed-language output the i18n requirement already forbids. This is why the seeders must ship
IT alongside EN.

**Tenancy: platform-level (superadmin), recommended.** `framework_competencies` and
`framework_bars_indicators` are explicitly global; `lang/*/interview.php` documents these
strings as "institutional avatar chrome, NOT per-tenant". A per-organization prompt row buys
nothing yet and creates a cross-tenant read surface for content that is currently identical
everywhere — and "a tenant must never see another tenant's data" is binding. Nullable
`organization_id` can be added additively later.

## Affected Areas

| Area | Impact | Description |
|---|---|---|
| `api/database/migrations/` | New | Global template table + per-competency override table |
| `api/database/seeders/` | New | Current EN text verbatim + IT translations |
| `api/app/Services/Conversation/SystemPromptComposer.php` | Modified | Section builders read the passed-in template set; stays pure |
| `api/app/Services/Conversation/PromptTemplateResolver.php` | New | Call-site loader + cache |
| `api/app/DTOs/Conversation/` | New/Modified | `PromptTemplateSet`; `ComposedPrompt` carries the revision |
| `api/app/Http/Controllers/Candidate/InterviewController.php` | Modified | Resolves the template set in `composePromptForCompetency()` |
| `api/app/Models/` | New | Template + override Eloquent models |
| `api/config/conversation.php` | Modified | `prompt_version` becomes the active-revision pointer |
| `api/tests/Unit/C8/SystemPromptComposerTest.php` | Modified | Existing suite must stay green unchanged in meaning |
| `api/tests/.../PromptByteIdentityTest.php` | New | The golden characterization gate |
| `openspec/specs/{interview-conversation,framework-catalog}/` | Modified | Delta specs |

## Risks

| Risk | Likelihood | Severity | Mitigation |
|---|---|---|---|
| **The `end_phrase` contract is reintroduced.** An editable `advance_*` row can omit the verbatim closing phrase. `buildAdvanceSection()` records the consequence: the avatar never speaks it, `matchesEndPhrase()` never matches, the competency runs to its session cap, and on the provider the session dies with `MAX_DURATION_REACHED` — which the candidate experiences as an error at the end of a question they answered completely. **THIS DEFECT HAS ALREADY SHIPPED ONCE.** | High | **Critical** | Per-section required-placeholder contract, enforced TWICE: validation refuses the save, and composition REFUSES (`CompositionException`) any resolved `advance_*` body lacking `:advance_phrase`/`:min_questions`. Plus a test asserting no unbound `:token` and no bare `end_phrase` literal survives into the composed text. A guard only at save time is insufficient — seeders and SQL bypass it. |
| **`prompt_version` traceability breaks.** Binding: every Evaluation records `framework_version`, `model_version`, `prompt_version`. Mutable text behind a stable version string makes an already-scored evaluation untraceable to the prompt that produced it. | High if unguarded | **Critical** | Immutable revisions (edit = new revision) + content hash over the resolved set; a referenced revision can never be UPDATEd; edits never touch composed/scored interviews. Tested, not asserted in prose. |
| Byte drift during migration (whitespace, heredoc newlines, `implode("\n")` joins) silently changes avatar behaviour | High | Medium | The byte-identity golden test is the gate; it is written and RED before any text moves. |
| Override append point degrades prompt quality (instruction ordering matters — see the section-order requirement) | Medium | Medium | Fixed position, spec'd and tested; the override is optional and every seeded competency starts with none, so the default composition is unchanged. |
| Framework-version pinning is weaker than ruling 3 implies: `framework_bars_indicators` carries NO `framework_version_id`, and `framework_versions` is tenant-scoped while indicators are global | Certain (pre-existing) | Medium | Named as an open question for design; the override table inherits exactly the same versioning as the anchors it sits beside, and does not invent a stricter scheme that the neighbouring table cannot honour. Fixing framework pinning is its own change. |
| Per-request DB reads on the `/start` hot path | Low | Low | Resolver caches per revision+locale; rows are small, global and immutable. |
| Seeder re-runs duplicating or mutating a referenced revision | Medium | Medium | Idempotent, revision-keyed seeding; a referenced revision is never rewritten. |

## Rollback Plan

Revert the feature branch. The migrations are additive (two new tables, no column dropped, no
data rewritten), so `migrate:rollback` drops them and every existing row is untouched.
`config/conversation.php` keeps its `prompt_version` key shape, so a reverted API composes
exactly the pre-change prompt from PHP again — which is the same string the byte-identity test
pins. No interview data, transcript or evaluation is modified by this change, so there is no
data migration to unwind and no re-scoring.

## Dependencies

- None external. `framework_bars_indicators`, `framework_competencies` and `framework_roles`
  already exist and are not modified.
- Italian prompt-section translations are needed for the seeders. They are the platform's own
  interviewer instructions (not expert-authored BARS anchors), so they do not block on
  ROADMAP open question 6 — but they must be authored, not machine-guessed.

## Success Criteria

- [ ] Composed prompt is **byte-identical** to the pre-change output for every seeded
      (role, competency, locale, budget, nudge, minimum, advance-phrase, authored-question)
      combination the existing suite covers.
- [ ] Every existing `SystemPromptComposerTest` case passes without weakening an assertion.
- [ ] An `advance_*` body without its required placeholders is refused at save AND at
      composition; a test proves both.
- [ ] Editing a template creates a new revision; the prompt reconstructed from an already-scored
      interview's stamped `prompt_version` is unchanged by that edit.
- [ ] A missing project-locale template row hard-fails; no mixed-language prompt is composable.
- [ ] `SystemPromptComposer` performs no DB or HTTP access; determinism test still green.
- [ ] A per-competency override appears in the composed prompt at the specified position and
      changes nothing else.
- [ ] Coverage ≥85% overall, ~95% on the composition path. Pint + PHPStan clean.

## Proposal question round

Auto mode — I could not ask interactively. These need user review; each has a stated working
assumption so `sdd-spec`/`sdd-design` are not blocked.

1. **Who edits these?** Assumed platform superadmin only, no per-tenant templates. If any tenant
   admin must ever tune interviewer wording, tenancy changes shape now, not later.
2. **Does a per-competency override need to be per role too?** Assumed yes (role×competency,
   mirroring `framework_bars_indicators`' unique key), with a competency-wide row allowed by
   leaving `role_id` null. Confirm, because it decides the unique index.
3. **Append-only override — acceptable?** Assumed yes. REPLACE is the mode that can delete a
   safety invariant per competency, so it is deferred deliberately.
4. **Are the `lang/*/interview.php` phrases genuinely out of scope?** Assumed yes: moving them
   is a three-repo change touching live completion detection. If they must move, that is a
   separate proposal with the frontend in it.
5. **Publishing model.** Assumed: seeder/console publishes a revision, and the active revision is
   named in `config/conversation.php` (so `config:cache` still pins it). The alternative — an
   `is_active` DB flag — makes the live prompt mutable without a deploy, which is more of the
   thing the user asked for and more of the risk above. This is the one tradeoff worth a decision.
