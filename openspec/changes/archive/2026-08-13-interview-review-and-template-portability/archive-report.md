# Archive report: Interview Review Surface and Template Portability

**Archived** 2026-08-13.

## Verification: every scenario maps to a test

| Scenario | Test |
|---|---|
| Review returns timing, integrity, snapshots | `SessionReviewTest` — full payload |
| Snapshots signed and expiring, no raw key | `SessionReviewTest` — whole body checked for the key |
| Events oldest first | `SessionReviewTest` — timeline order |
| Clean session reports zero, not a failure | `SessionReviewTest` — empty timeline |
| Cross-tenant is 404, not 403 | `SessionReviewTest` — other org's session |
| Operator may read | `SessionReviewTest` — operator role |
| Unauthenticated refused | `SessionReviewTest` — 401 |
| Candidates can never read | `CandidateCannotReadProctoringArchTest` — 3 guards |
| Cost follows the configured rate | `SessionCostEstimatorTest` — per provider |
| Unfinished session has no estimate | `SessionCostEstimatorTest` |
| Unpriceable reports absent, not zero | `SessionCostEstimatorTest` — unknown provider |
| Weighted score matches the ported table | `IntegritySummarizerTest` — 24 cases |
| Admin exports a versioned document | `AvatarTemplatePortabilityTest` |
| Non-admin refused both ways | `AvatarTemplatePortabilityTest` — operator, viewer |
| Import arrives inactive | `AvatarTemplatePortabilityTest` |
| Unknown key refused, named, nothing created | `AvatarTemplatePortabilityTest` |
| Colliding name creates, never overwrites | `AvatarTemplatePortabilityTest` |
| Dual-provider entry splits in two | `AvatarTemplatePortabilityTest` |
| Bad schema refused before creating | `AvatarTemplatePortabilityTest` |
| Round trip export → import | `AvatarTemplatePortabilityTest` |
| Score shown with its events, never alone | `SessionReviewPanel.spec` — impossible score rendered as sent |
| Clean session reads as clean | `SessionReviewPanel.spec` |
| Signed URL used as given | `SessionReviewPanel.spec` |
| Cost labelled, dash not zero | `SessionReviewPanel.spec` |
| Controls hidden for non-admin | `TemplatePortability.spec` |
| Import result and refusal reported | `TemplatePortability.spec` |

The candidate-read guard was additionally verified RED by injecting a `show()`
on `Candidate\IntegrityController` and confirming it failed, then reverting. A
guard that has never failed is trusted on faith.

## Three things the plan got wrong, corrected rather than worked around

**LLM cost was dropped.** `ai_requests` records organization, provider, model
and tokens but carries no `interview_session_id`, so token spend cannot be
attributed to one session without inventing the link. A plausible number with no
basis is worse than an absent one. Recorded in D5 and in the delta spec;
attribution needs that column, which belongs to the writer side.

**A prior spec statement was superseded.** `AdminReadRouteSurfaceTest` asserted
that snapshots are "never exposed via this API". The narrow part that changed is
recorded as a MODIFIED requirement: the API still never serves the bytes, and the
guard was rewritten to enforce exactly that rather than deleted for being
inconvenient. Retention is untouched.

**A duplicate validator was removed mid-implementation.** The importer initially
grew its own unknown-key check beside `ConfigValidator`, which already does it —
two validators drift, and the divergence would let a file install a config the
form would have rejected. D7 said use one source; the first draft did not.

## The dependency was NOT resolved

Slice 3 extends an `avatar-templates` capability that did not exist, because
`avatar-provider-templates` is still open with no delta specs. Rather than block
the whole change or write someone else's specification, `openspec/specs/
avatar-templates/spec.md` was created covering ONLY the portability surface, and
says so at the top. The base capability — catalogue, one-active-per-org,
provider immutability, field specs — remains unwritten and remains that change's
to own.

## Gates at archive time

- api: 1541 passed, 5 skipped. pint and phpstan clean.
- backoffice: 490 unit, 97 E2E. eslint, typecheck and client-drift clean.
