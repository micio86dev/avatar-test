# Delta: admin-backoffice — BARS Coverage Visibility

## ADDED Requirements

### Requirement: Competency Picker Disables Uncovered Competencies For New Selection

`CompetencyPicker.vue` MUST consume the catalog's `bars_available` flag (already
emitted by `CompetencyResource` and reachable via `backoffice/types/api.ts`,
currently dropped by `ProjectForm.vue`) and MUST NOT allow a competency with
`bars_available=false` for the currently selected role to become newly
checked. The disabled option MUST render a visible, i18n-keyed reason inline
on the option itself — a disabled control with no explanation is a second
defect, not the fix. No override, bypass, or "force select" control MAY exist
for an uncovered competency, in the picker or anywhere else in the backoffice.

#### Scenario: An uncovered competency cannot be newly selected

- GIVEN a role whose competency option has `bars_available=false`
- WHEN the operator clicks its checkbox
- THEN the checkbox stays unchecked
- AND the option shows an i18n-keyed reason that it has no behavioural
  anchors yet

#### Scenario: A covered competency remains freely selectable

- GIVEN a competency with `bars_available=true` for the selected role
- WHEN the operator clicks its checkbox
- THEN it toggles selected as normal

#### Scenario: No override control exists

- GIVEN the project form and every other backoffice surface
- WHEN they are inspected for a control that selects an uncovered competency
  anyway
- THEN no such control exists

### Requirement: Picker States Group-Level Coverage Per Role

The picker MUST show, at group level, how many of the selected role's
competencies have no BARS anchors yet (e.g. "N of M competencies have no
behavioural anchors for this role yet"), i18n-keyed in `it` and `en`.

#### Scenario: Coverage line reflects the role's real gap count

- GIVEN FLL has 18 assigned competencies, 8 with anchors
- WHEN the picker renders for role FLL
- THEN the coverage line states 10 of 18 have no anchors yet

#### Scenario: A fully covered role shows zero gaps

- GIVEN ICO has 15 assigned competencies, all 15 with anchors
- WHEN the picker renders for role ICO
- THEN the coverage line states 0 of 15 have no anchors yet

### Requirement: An Already-Selected Uncovered Competency Stays Checked, Flagged, And Removable

Selection state MUST be evaluated independently of coverage: a competency
already attached to the project renders checked and carries the same
coverage flag/reason as an unselected uncovered option, but its checkbox
MUST remain enabled for deselection. The picker MUST NEVER disable a checked
option, regardless of `bars_available`. A project's competency set is not
immutable once active (`UpdateProjectRequest`/`ProjectController::update`
accept and `sync()` `competency_ids` unconditionally); the edit form is the
remediation path, so rendering an uncovered competency checked-and-locked
would trap the operator with a defect they can see but cannot fix.

#### Scenario: Editing a project holding an uncovered competency

- GIVEN a project whose selected competencies include one with
  `bars_available=false`
- WHEN the edit form renders
- THEN that competency renders checked and flagged with its reason
- AND its checkbox is enabled

#### Scenario: The operator removes the uncovered competency

- GIVEN the state above
- WHEN the operator unchecks it
- THEN it is removed from the selection and the picker accepts the change

### Requirement: Coverage Re-Evaluates When The Selected Role Changes

Coverage MUST be recomputed against the newly selected role whenever
`role_code` changes, because `bars_available` is a property of the
role×competency pair, not of the competency alone.

#### Scenario: Switching role changes which options are disabled

- GIVEN a competency covered for role ICO but not covered for role FLL
- WHEN the operator switches the form's role from ICO to FLL
- THEN that competency's option becomes disabled-for-selection under FLL

### Requirement: Project List Surfaces Uncovered-Competency Debt

> **Corrected surface, recorded rather than silently rewritten.** An earlier
> draft of this requirement said "a project's detail view" / "detail page".
> `design.md` D1 verified there is no project detail page in this codebase —
> `pages/projects/index.vue` plus its edit dialog IS the entire project
> surface today (D1's recorded promotion path: if a detail page or report
> view is added later, this debt indicator moves to
> `ProjectResource.competencies[].bars_available` and the composable below is
> deleted). The requirement's INTENT — an operator learns about unscorable
> competencies before inviting candidates, not at report time — is satisfied
> here through the existing list row (`ProjectTable.vue`) instead, backed by
> `useBarsCoverage()` (a per-role-code cache over the catalog endpoint each
> loaded project's `role_code` already exposes).

The projects list MUST state, with a count, per row, when that project holds
competencies that cannot currently be scored (`bars_available=false` for its
pinned role), so an operator learns this before inviting candidates rather
than at report time. This applies to projects created before this change as
well as new ones; the remediation path is the edit form. A count that could
not be resolved (the coverage fetch failed) MUST render as no notice at all,
never as zero — an advisory count that is silently wrong is worse than one
that is absent.

#### Scenario: A project with uncovered competencies is flagged on its list row

- GIVEN a project holding 2 competencies with no BARS anchors for its role
- WHEN the projects list renders that project's row
- THEN it states that 2 of its competencies have no behavioural anchors

#### Scenario: A fully covered project shows no debt notice

- GIVEN a project whose every selected competency has anchors for its role
- WHEN the projects list renders that project's row
- THEN no uncovered-competency notice appears

#### Scenario: A failed coverage fetch shows no debt notice, never a zero

- GIVEN the coverage catalog request for a project's role fails
- WHEN the projects list renders that project's row
- THEN no uncovered-competency notice appears — not "0 without anchors"
