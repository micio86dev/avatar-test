# Archive Report: Scoring Failure Containment

**Change**: `scoring-failure-containment`
**Archived**: 2026-08-25
**Mode**: openspec (file-based), strict TDD
**Shipped**: NOT merged, NOT deployed. `api`, `backoffice`, and the wrapper are all on
`feature/scoring-failure-containment`, clean, unmerged, undeployed at archive time.

## IMPORTANT — Folder move NOT performed (tool limitation, reported honestly)

This execution's toolset (`Read`, `Edit`, `Write`, `Glob`, `mem_*`) contains **no
filesystem move/rename/delete capability and no shell/Bash tool**. A true "move" of
`openspec/changes/scoring-failure-containment/` to
`openspec/changes/archive/2026-08-25-scoring-failure-containment/` requires deleting the
source directory, which none of the available tools can do. Copying all 12 files into a
new archive path while leaving the source in place would NOT satisfy "the source folder
no longer exists" and would silently create two divergent copies of this change's
history — exactly the kind of false-complete archive this run was explicitly warned
against producing.

**What WAS done instead, so the eventual move is a single clean operation:**
- All spec merges (Step 2) are complete and already live in `openspec/specs/` (see
  below) — this is the substantive, hard-to-redo part of the archive and does not
  depend on the folder move.
- The two verify-report SUGGESTIONs were folded into `design.md` in place (the B2a
  slice-table correction and the ship-order footnote — see below).
- This report was written directly into the **existing** change folder
  (`openspec/changes/scoring-failure-containment/archive-report.md`), not into a
  not-yet-created archive path, so a single `git mv` carries all 13 files (12 original +
  this report) together.

**Remaining mechanical step, for a human or an orchestrator with shell access:**

```
git mv openspec/changes/scoring-failure-containment \
       openspec/changes/archive/2026-08-25-scoring-failure-containment
```

After running that command: confirm `openspec/changes/scoring-failure-containment/` no
longer exists, confirm all 13 files are present at the new path, and this change is
fully closed with no further action needed.

## Task Completion Gate — verified before any spec merge

`tasks.md`: 78/79 checked. The one open item, F.4, is explicitly annotated in
`tasks.md` itself as "owned by `sdd-spec`/`sdd-archive`... not gated on by `sdd-apply`"
— it names exactly the spec-merge work this archive phase performs (Coverage Note
amendment, `webhooks-integration` open-map rule, `observability` fingerprint/failure-
reason record). `verify-report.md` independently confirmed all four named obligations
were already present, accurate, in the delta specs read for verification — nothing
here was invented at archive time, only merged into `openspec/specs/`. F.4 is
considered satisfied by the spec merges below. No stale unchecked implementation
checkbox exists.

`verify-report.md` verdict: **PASS — 0 CRITICAL, 0 WARNING, 2 SUGGESTION.** Both
SUGGESTIONs are folded in (see "Design.md corrections" below). No CRITICAL issue
blocks archive per the Strict-vs-OpenSpec Archive Policy.

## Specs Synced

| Domain | Action | Details |
|---|---|---|
| `scoring-engine` | Updated | 3 requirements MODIFIED in place (Indicator Score Domain Validation, Excerpt Verbatim Validation, LLM Parse Error — Persistent Malformed Output — the last also fixed a pre-existing duplicated-scenario bug in the main spec); 6 requirements ADDED (Fence and Leading/Trailing Prose Tolerance, Truncation Detected From `finish_reason` Before Parsing, Truncation-Only Retry At An Enlarged Budget, Per-Indicator Validation-Failure Isolation, Indicator Validation-Failure Reason Vocabulary, Unscorable Reason Enum Widens Beyond Three Values); Coverage Note amended from three-value to four-value `unscorable_reason` enum with a pointer to the superseding requirement |
| `scoring-model` | Updated | 1 requirement ADDED (Validation-Failure Reason Is Excluded From Every Scoring Formula) |
| `observability` | Updated | 3 requirements ADDED (AiRequestFailureReason Gains a Truncation Case, ai_requests Derived-Signal Diagnostic Fingerprint, Each Truncation Retry Attempt Gets Its Own ai_requests Row) |
| `admin-read-api` | Updated | 2 requirements ADDED (Evaluation Read Surface Exposes unscorable_reason, Evaluation Read Surface Exposes Per-Indicator Validation-Failure Reason) |
| `admin-backoffice` | Updated | 2 requirements ADDED (EvaluationReport.vue Renders unscorable_reason Instead Of An Unexplained 0%, EvaluationReport.vue Renders Per-Indicator Validation-Failure Reason) |
| `webhooks-integration` | Updated | 2 requirements MODIFIED in place (evaluation payload — status, reliability reuse, files (partial); Payload schema versioning) |

### Stale-prose sweep (beyond the delta headings)

The delta mechanism only replaces matching `### Requirement:` headings; it does not
touch surrounding prose. Swept `scoring-engine/spec.md`'s **Coverage Note**, which
pinned `unscorable_reason` at exactly three values as normative prose (not a
requirement heading) — updated to state four values (`anchor_translation_missing`,
`role_no_bars`, `llm_parse_error`, `llm_truncated`) with a pointer to the superseding
requirement, and added coverage-note entries for truncation detection, fence/prose
tolerance, the truncation retry, per-indicator isolation, and the `unassessable_reason`
vocabulary — all previously undocumented in that note. Checked the other five merged
main specs and the rest of the `openspec/specs/` tree for other stale references to a
three-value enum, a single-`try` catch scope, or the absence of a truncation failure
class; none found outside the Coverage Note.

## Design.md corrections (verify-report SUGGESTIONs, folded in)

1. **D13 slice table.** The line "B2a is inert alone, which is what makes the split
   safe" was FALSE and was empirically disproved by `sdd-verify`'s break-and-restore
   test: B2a's own migration's equivalence CHECK
   (`(score = -1) = (unassessable_reason IS NOT NULL)`) forces the write path to tag
   **every** `-1` write, including the pre-existing model-declared case, not only the
   new illegal-type case — reverting the job's passthrough and re-running
   `GoldenCassetteTest`/`IntermediateScaleCassetteTest` reproduces
   `SQLSTATE[23514]: Check violation` on exactly that case. Corrected in place with an
   explicit note (not silently rewritten, since this is a factual error in a
   forward-looking planning instruction, not a historical record that must be
   preserved verbatim — unlike `design.md`'s Phase-0 naming corrections, which the
   team already amended in place for the same reason during `apply`).
2. **Ship-order footnote added.** B2a and B2b MUST reach production in the SAME
   release — separately reviewable (each has its own passing test suite) but NOT
   separately deployable (B2a's migration is unsafe against an unmodified job).

## Premise corrections carried from design (C-A / C-B / C-C) — work removed from the proposal

The proposal (`proposal.md`, AD-3 and the Scope table) budgeted for three things that
`sdd-design` found, by reading the code, did not need doing. Recorded here for
traceability since each REMOVED planned work:

- **C-A — no value-enumerating CHECK on `ai_requests.failure_reason`.** The proposal
  assumed a closed-set-of-6 Postgres CHECK requiring a migration before the new
  `Truncated` case could ship. The real constraint
  (`CHECK ((success = false) = (failure_reason IS NOT NULL))`) is presence-based, not
  value-enumerating. This deleted the A1 slice's migration-gate dependency and its
  only rollback step with a data precondition — confirmed unmodified in the merged
  `observability` spec's new "AiRequestFailureReason Gains a Truncation Case"
  requirement.
- **C-B — the `evaluation` webhook already shipped `unscorable_reason`.** The proposal
  treated this as an open product question requiring new code
  (`EvaluationPayloadAssembler`). It was already emitting the field additively, with
  existing tests pinning both directions, before this change started. What was
  genuinely new (widening the value set, and the Increment-B per-indicator key) is
  exactly what the merged `webhooks-integration` delta captures — no rewrite of
  already-shipped code was needed.
- **C-C — no typed-client regen path for this endpoint.** The proposal assumed
  "Scramble/OpenAPI regen plus typed-client regen in `backoffice`."
  `useEvaluationReport.ts` is hand-typed against a passthrough resource Scramble
  cannot infer (the same limitation already recorded for `DashboardMetricsResource`).
  Regenerating `openapi.json` is still correct for the published contract but
  propagates nothing to the backoffice; the hand-typed interface had to be edited by
  hand, and D11's key-set drift guard (`EvaluationKeySetTest`) is the substitute for
  the regen path that doesn't exist.

## The B2a "not inert alone" finding

The single highest-consequence finding in this change. `apply-progress.md` Deviation
#7 found it during implementation; `verify-report.md` reproduced it independently via
break-and-restore rather than accepting the written account. Confirmed genuine:
B2a's migration and B2b's job restructure are separately **reviewable** PRs but are
**not** separately **deployable** — see the `design.md` correction above. This
distinction (reviewable vs. deployable) is the one a reader must not collapse.

## The excerpt-elision divergence — only HALF addressed, precisely scoped

This change's per-indicator isolation (B2/B2b) fixes the **blast radius** of an elided
or otherwise non-verbatim excerpt: where such a failure previously discarded the whole
competency, it now discards only its own indicator. It does **not** fix the
**underlying case**: `ExcerptValidator` was read directly during `sdd-verify` and
contains no ellipsis-tolerance logic of any kind — a genuinely elided excerpt (e.g. the
model citing "...worked closely..." rather than the verbatim run) still fails the
verbatim-substring check exactly as before. The only change is that it now costs one
indicator instead of the whole competency. Any future change that wants to accept
elided excerpts needs new logic in `ExcerptValidator` itself; this change deliberately
did not touch that class (per D9's diff-freeness invariant it is not in the formula set,
but it also received no isolated edit of its own).

## Follow-on work explicitly out of scope (proposal's non-goals, still standing)

1. **Whole-conversation transcript for the evaluator** — the evaluator still sees only
   the single competency's `InterviewSession`.
2. **Evaluator rigor calibration** — `PromptBuilder` still carries no severity
   guidance beyond the existing AD-1 rubric.
3. **STAR-based interviewer prompt** — `SystemPromptComposer` still has no STAR model,
   no same-episode constraint, no minimum question count.
4. **Excerpt-elision tolerance** (see above) — the remaining half of the divergence
   named in the launch prompt: per-indicator isolation limited the blast radius; the
   underlying rejection of elided-but-genuine excerpts is unresolved and unscoped to
   any specific future change yet.

## `openapi.json` — deliberately left uncommitted

Confirmed by both `apply-progress.md` (A4.4) and `verify-report.md`: a fresh
`php artisan scramble:export` produces **zero diff** touching `unscorable_reason` or
`EvaluationResource` — Scramble cannot see through the passthrough resource, exactly as
C-C predicted. The regen DID surface an unrelated ~43-line drift on other resources
(`UserResource`, `AvatarTemplateResource`, `InterviewSession`-shaped resources — type
narrowing changes, some looking like a regression), reproducible even after clearing
config/route caches. This is pre-existing environment drift, orthogonal to this
change. `openapi.json` was restored to its pre-regen committed state
(`git checkout -- openapi.json`) rather than injecting an unrelated diff into this
change's PRs. This is a human decision outside this slice's scope, correctly flagged
rather than silently resolved by either `apply` or `verify`.

## Not yet released — why archiving now is safe

This change is archived **before** merge to `develop` and before deploy, unlike the
preceding archived change (`bars-full-scale-1-5`), which was already live at archive
time. This is safe because:

- `sdd-verify` ran independently, fresh, against the actual feature-branch HEAD
  commits in both `api` (`81611b4`) and `backoffice` (`56d4897`) — not against a
  description of the branch. Both full test suites (2196 Pest tests / 834 Vitest
  tests) passed fresh during verification, matching the apply phase's own numbers
  exactly.
- The single highest-risk claim (B2a/B2b coupling) was independently reproduced by
  breaking and restoring real code, not accepted on the strength of the written
  record.
- The archive's job — merging delta specs into the source of truth and closing the
  planning/spec/design/tasks/verify cycle — is complete and does not require the code
  to be merged or deployed first; `openspec/specs/` now correctly describes the
  intended post-release behavior, which the feature branch already implements and
  which verify already confirmed matches.
- The release (merge to `develop`, then eventual `main`/tag per Git Flow) is expected
  to follow immediately, as a separate, ordinary Git Flow action outside this SDD
  change's scope — CLAUDE.md's "no deploy unless explicitly requested" boundary means
  this archive step correctly does not perform or assume that merge/deploy itself.

## Artifact index (change folder — pending the `git mv` above)

- `openspec/changes/scoring-failure-containment/proposal.md`
- `openspec/changes/scoring-failure-containment/explore.md`
- `openspec/changes/scoring-failure-containment/specs/{scoring-engine,scoring-model,observability,admin-read-api,admin-backoffice,webhooks-integration}/spec.md`
- `openspec/changes/scoring-failure-containment/design.md` (corrected in place, see above)
- `openspec/changes/scoring-failure-containment/tasks.md`
- `openspec/changes/scoring-failure-containment/apply-progress.md`
- `openspec/changes/scoring-failure-containment/verify-report.md`
- `openspec/changes/scoring-failure-containment/archive-report.md` (this file)

## Source of Truth Updated

The following main specs now reflect the new behavior:

- `openspec/specs/scoring-engine/spec.md`
- `openspec/specs/scoring-model/spec.md`
- `openspec/specs/observability/spec.md`
- `openspec/specs/admin-read-api/spec.md`
- `openspec/specs/admin-backoffice/spec.md`
- `openspec/specs/webhooks-integration/spec.md`

## SDD Cycle Status

Planning, spec, design, tasks, apply, and verify are complete and the source-of-truth
specs are updated. The change folder move to `openspec/changes/archive/` is the one
remaining mechanical step, blocked on tooling as described above, not on any open
design or verification question.
