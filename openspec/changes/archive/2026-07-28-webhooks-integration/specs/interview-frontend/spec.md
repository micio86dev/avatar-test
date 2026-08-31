# Delta for Interview Frontend

## ADDED Requirements

### Requirement: Exit redirect at interview completion (D8, C10)

When the candidate reaches the `done` state (all competency sessions ended — see the
existing Flow Screens requirement), the frontend MUST resolve the project's
`exit_redirect_url` and, if it is a non-null, non-empty string, redirect the browser to
that URL. `exit_redirect_url` is already exposed by the API on the candidate session
resource (`ParticipantResource.project.exit_redirect_url`,
`api/app/Http/Resources/ParticipantResource.php:58`, populated from
`Project.exit_redirect_url`, validated at `StoreProjectRequest.php:74`) — this addendum
consumes it for the first time; no backend change is required.

If `exit_redirect_url` is null or empty, the existing inline `done` branch in
`frontend/app/pages/interview/[token].vue` MUST be shown unchanged — "no further API
calls" per its existing doc comment. (`frontend/app/pages/interview/done.vue` is
unreachable dead code — no `navigateTo('/interview/done')` call exists anywhere in
`frontend/` — and is not the rendered surface; see design.md S15.) The redirect MUST fire regardless of the resulting
`Evaluation` status (`completed` or `pending`, per C9): evaluation is asynchronous and
NOT yet known at redirect time (per
`docs/app_description/04-integration-surface/04-user-exit.md` — "la valutazione non
è sincrona con il redirect"), and the frontend MUST NOT wait for it or poll for it before
redirecting.

**Scope note (D8):** this requirement covers ONLY the normal-completion `done` path.
Redirecting from `error`/`terminal` states to a distinct configurable error landing page
is explicitly OUT OF SCOPE for C10 (not requested by the proposal; the binding doc's
"Errore tecnico in intervista → redirect a pagina errore configurabile" case is
unimplemented and remains a future gap).

**Implementation dependency (flagged for design, not a spec requirement):** as of C7b,
no frontend code path calls `GET /api/candidate/session` —
`frontend/app/pages/interview/[token].vue:212-216` hardcodes an empty competency list
with the comment "In production, competency list comes from the C6 bootstrap endpoint."
Delivering this requirement therefore requires the design phase to wire a source for
`exit_redirect_url` (the bootstrap call or an equivalent) into the `done` state path;
this is a design-time concern, not a change to this requirement's observable contract.

#### Scenario: exit_redirect_url set — candidate redirected on done

- GIVEN a project with `exit_redirect_url = "https://hr.acme.com/beai/done?ref=acme-672"`
- WHEN the candidate's session reaches the `done` state (all competencies ended)
- THEN the browser is redirected to `https://hr.acme.com/beai/done?ref=acme-672`
- AND no evaluation-status check or poll precedes the redirect

#### Scenario: exit_redirect_url null — static done page shown, no redirect

- GIVEN a project with `exit_redirect_url = null`
- WHEN the candidate's session reaches the `done` state
- THEN the existing inline `done` branch in `frontend/app/pages/interview/[token].vue` is displayed unchanged
- AND no redirect navigation occurs and no further API calls are made

#### Scenario: Redirect fires identically for a pending evaluation

- GIVEN a project with `exit_redirect_url` set, and the candidate's evaluation will later resolve to `status = pending` (insufficient competency coverage)
- WHEN the candidate's session reaches the `done` state
- THEN the redirect fires exactly as in the completed case — the frontend has no visibility into evaluation status at redirect time and does not differentiate
