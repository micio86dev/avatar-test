# New client framework version and Potential competencies

## Objective
A newly created client can create a project immediately, and a Potential project can select MTG and LAT in the
backoffice.

## Problem (found 2026-10-02)
1. Nothing created a `FrameworkVersion` for a new organization, so a new client had nothing to pin and no project could
   be created.
2. `GET /api/framework/potential-competencies` reported `bars_available: false` for MTG and LAT (coverage was framed as
   a role x competency question and these belong to no role). The backoffice `CompetencyPicker` disables options with
   `bars_available === false`, so a Potential project could not select its competencies.

## Decisions (shipped 2026-10-02, api v0.66.0)
- `CreateOrganization::create()` (admin endpoint and `beai:provision-organization`) calls `EnsureDefaultFrameworkVersion`
  in its transaction: no version yet -> one unlocked `1.0.0` ("Default framework version") pinned to the latest
  PUBLISHED catalogue revision; any existing version (even locked) -> no-op; no published revision -> nothing created,
  warning logged, organization still created.
- `beai:ensure-framework-versions [--org=<slug>] [--dry-run]` backfills; idempotent, tenant-isolated; runs as a
  NON-fatal step of `beai:deploy` after the catalogue seed.
- `bars_available` for a potential competency is true when it has >=1 `framework_bars_indicators` row with
  `role_id IS NULL` in its own revision; role-bound rows do not count. MTG and LAT have 3 role-less rows each.
- Backoffice: role-free picker wording for role-less projects; the catalogue role competencies form always shows
  `catalogue.roles.competencies.potentialNote`. Assigning a potential competency to a role stays refused.

## Constraints
- Repo language English. Conventional commits, no AI attribution. Git Flow x4, no deploy unless asked.
- Live specs updated: `project-config`, `framework-catalog`, `admin-backoffice`.

## Tasks
- [x] P1 api: potential-competency coverage -> backend#119
- [x] P2 api: default framework version, command and deploy step -> backend#120
- [x] P3 api: release 0.66.0 (backend#118), tag v0.66.0, deployed to Railway production 2026-10-02 16:57Z; `beai:deploy`
      logged "Created 0 default framework version(s) across 1 organization(s)"
- [x] P4 backoffice: role-free copy and role note -> backoffice#70
- [x] P5 backoffice: real-stack e2e for a Potential project -> backoffice#71 (RED before the fix: "MTG must be
      enabled"; GREEN after)
- [x] P6 local dev data: `beai:ensure-framework-versions` created `1.0.0` for quint-test-org, dev-org, aaaa
- [x] P7 consumers sync openapi: frontend 0.22.2 (tag v0.22.2, deployed); backoffice release 0.47.2 (backoffice#72)
- [x] P8 wrapper: live specs record the above (this change)

## Acceptance
A new organization created through the admin endpoint lists one pinnable version and a project can be created with it;
the Potential picker enables MTG and LAT.

## Open
- Wrapper 0.51.0 and 0.51.1 are released (tags `v0.51.0`, `v0.51.1` on the remote); nothing is pending there.
- The local nginx stale-upstream 502 (the backoffice keeps the old api IP after the api container is recreated) is
  MITIGATED, not removed: `depends_on.api.restart: true` restarts backoffice on `docker compose restart api`, but NOT
  on `up -d --force-recreate api` or `up -d --build api`; for those, `task stack:check` detects the 502 and prints
  `docker compose restart backoffice`. Only the backoffice goes stale: after the api moved IP (2026-10-02, twice) :3001
  answered a real 502 while the frontend on :3000 kept answering 200, since Node re-resolves `api` per connection
  (beai#60 and beai#61 wrongly included the frontend). The Dockerfile's literal `proxy_pass` is shared with production and was deliberately not changed.
- Playwright webkit flake seen once on `catalogue-edit-publish.spec.ts:294`, not reproducible (CI rerun green, 15 + 10
  local repeats green).
- Native reviews: the post-0.51.0 slice ended `correction_required` with hidden finding text. The likely cause is the
  inaccurate claim of beai#60 (recreating the api restarts the edge), corrected by beai#61; this is an inference.

## Route declaration and trigger evidence
Delegated writers per repo (2+ non-trivial files each); orchestrator did git, PRs, release and deploy.
