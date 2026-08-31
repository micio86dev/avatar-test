# Proposal: BARS Coverage Visibility

## Intent

39 of 83 declared role×competency pairs have BARS anchors (ICO 15/15, FLL 8/18, MLL 8/18, BUL 8/14, SRX 0/18). The 44-pair gap is tracked already (`framework_gaps.kind=competency_no_bars`). Three defects sit on top of it:

1. `docs/app_description/02-domain/01-roles-and-competencies.md:78` states *"File completi: ICO.json, FLL.json, MLL.json, BUL.json"*. Three of those four are partial — a note that precedes its fact.
2. The API computes the truth and the client discards it. `CompetencyResource.php:56` emits `bars_available`; it reaches `backoffice/types/api.ts:1285`; `ProjectForm.vue:555` drops it; `CompetencyPicker.vue` never reads it. An operator picks an uncovered competency, runs the interviews, and finds out at scoring time (`ScoreEvaluationJob.php:571` → `unscorable_reason=role_no_bars`).
3. The CI catalog gate asks the ROLE question only (`scripts/ci-guards.sh:529`). A BARS file covering 8 of 18 competencies passes green.

## Scope

### In Scope
- Replace the doc completeness claim with per-role coverage counts.
- Thread `bars_available` through `ProjectForm` → `CompetencyPicker`: uncovered competencies disabled for NEW selection, with a visible per-option reason and a group-level coverage line. `it` + `en` keys, no bare literals.
- Extend the catalog gate to role×competency pairs, seeded from the 44 known gaps, following the existing two-direction known-gaps precedent.
- Vitest + Playwright coverage; `ci-guards` self-test rows for both new directions.

### Out of Scope
- **Authoring the 396 anchor texts.** They are role-specific, not copyable: for STG, ICO's first indicator is *"Understand the short- and medium-term consequences of own actions"*, FLL's is *"Have a plan to achieve own team's goals"*. Reusing ICO's anchors would score a leader against individual-contributor behaviour and produce a number that looks valid. No source material exists in `docs/`, `legacy-demo/`, or the framework tree.
- Server-side rejection of uncovered `competency_ids` (see Risks).
- The SRX role-level exemption and `scripts/framework-known-gaps.txt` entry — unchanged.
- The four in-flight changes.

## Capabilities

### New Capabilities
None.

### Modified Capabilities
- `admin-backoffice`: the competency picker MUST surface per-role BARS coverage and MUST NOT allow a new selection of an uncovered competency.
- `ci-pipeline`: the framework catalog gate MUST assert coverage per role×competency pair, not only per role. (The existing role-level gate is unspecified in `openspec/specs/` — the delta codifies it, then extends it.)

## Approach

**Position: disable, not warn — and always explain.**

Selecting an uncovered competency today has exactly one outcome: an unscorable competency on a real person's report. It is not a judgment the operator can currently get right, so a warning asks them to weigh a choice with no upside. Disable it. But a bare disabled checkbox is a second defect, not a fix — the operator sees an option they cannot take and no reason. So: disabled + inline reason + a group line ("N of M competencies have no behavioural anchors for this role yet").

**Deselection stays open — and this corrects a premise.** A project's competency set is NOT immutable once active: `Project::booted()` guards only `assessment_type`, `framework_version_id`, `role_code`; `UpdateProjectRequest.php:83` accepts `competency_ids` with `sometimes` at any status; `ProjectController::update()` calls a plain `sync()`. The edit form is therefore the REMEDIATION path for projects that already hold uncovered competencies. Rendering those checked-and-locked would trap the operator with a competency they can see is broken and cannot remove. Rule: **disabled for selection, never disabled for deselection.**

**CI gate**: reuse the runtime's own vocabulary (`competency_no_bars`) and the mechanism already ratified for `role_no_bars` — a committed per-pair list that fails for any UNdeclared pair AND for any exemption whose gap has closed. A gate that cannot go green gets disabled within a week; that lesson is recorded twice in this repo.

## Affected Areas

| Area | Impact | Description |
|---|---|---|
| `docs/app_description/02-domain/01-roles-and-competencies.md` | Modified | Line 78 completeness claim → coverage table |
| `backoffice/app/components/molecules/CompetencyPicker.vue` | Modified | Consume coverage flag; disable-for-selection + reason |
| `backoffice/app/components/organisms/ProjectForm.vue` | Modified | Stop dropping `bars_available` at line 555 |
| `backoffice/i18n/locales/{it,en}.json` | Modified | New copy keys (both mandatory) |
| `scripts/ci-guards.sh` | Modified | Per-pair coverage functions |
| `scripts/framework-competency-gaps.txt` | New | 44 committed pair exemptions |
| `.github/workflows/wrapper-ci.yml` | Modified | Gate step (d) + self-test rows |

## Risks

| Risk | Likelihood | Mitigation |
|---|---|---|
| Client-only guard is a hint, not an invariant; a direct API call still attaches an uncovered competency | High | Accepted for this slice. Server-side rejection would 422 an existing project re-submitting its current set; it needs a delta-only rule (reject newly-added ids only) and an audit of live data first. Tracked, not silently dropped. |
| The 44-entry gap list reads as permanent debt | Medium | The stale-exemption direction forces deletion in the commit that closes each gap |
| `CompetencyPicker` must still satisfy `form-contract`, `destructive-action`, `date-render` arch guards | Medium | Run `backoffice/tests/unit/arch/` before the picker change lands |
| Snapshot drift if any resource changes | Low | No API change planned; if one appears, all three `openapi.json` copies move together and `task openapi:sync` requires `DB_CONNECTION=pgsql` |

## Rollback Plan

Three independent reverts. The doc edit is a one-line revert. The picker change is a component + i18n revert restoring the current always-enabled grid (no schema, no API, no data migration). The CI gate is a revert of `ci-guards.sh` + `wrapper-ci.yml` step (d) plus deletion of the new gaps file. Nothing persists state, so no data is stranded by any of the three.

## Dependencies

- None on the four in-flight changes. Wrapper CI must be green before the new gate rows are added.

## Open Question (spec phase — do NOT decide here)

Should the missing-anchor debt surface anywhere other than the picker — project detail, reports view — given that projects created before this change may already hold uncovered competencies? The remediation path exists (competency sets are editable); what is undecided is whether the product should point the operator at it.

## Success Criteria

- [ ] No file in `docs/app_description/` claims BARS completeness that the JSON does not have.
- [ ] A competency with no anchors for the selected role cannot be newly selected in the backoffice, and the operator is told why.
- [ ] An already-selected uncovered competency renders, is flagged, and can be removed.
- [ ] Adding a competency to a role in `roles.json` without adding its BARS entry fails CI.
- [ ] Authoring a missing BARS entry without deleting its exemption fails CI.
- [ ] `bun run test:unit` and `bun run test:e2e` green in `backoffice`; ci-guards self-test green.
