# Reusable link visitor identity (visitors give a name and an email; the purge redacts the email)

Predecessor: `odd/tasks/reusable-interview-links.md` (released as api 0.63.0, frontend 0.20.0, backoffice 0.45.0,
wrapper 0.48.0). That feature created anonymous visitors; this one identifies them.
SDD change: `reusable-link-visitor-identity` (Engram `sdd/reusable-link-visitor-identity/*`: proposal #3474, spec index
#3480 plus six deltas, design index #3484 plus api #3481, ui #3482, slices #3483, retention #3486, tasks index #3491
with sub-keys api #3487, frontend #3488, backoffice #3489, wrapper #3490; 144 tasks).

## Objective
Before a reusable-link visitor starts the interview, the candidate page collects a full name and an email address and
sends them in the same single redemption request. The visitor participant is created with that identity. The retention
purge now redacts the email together with the name, so the data-protection promise holds for the new data.

## Problem and why
Reusable-link visitors were anonymous placeholders (`<label> #<n>`, a reserved-domain email). That made two things
impossible: attributing an interview to a person (operators could not tell visitors apart in the participants list),
and answering a GDPR access or erasure request, because no identifier BEAI held matched a data subject. Collecting a
name and an email fixes both, and the purge must then treat the email as personal data of the same class as the name.

## Scope (authorized)
- api: identity validation first and independent of the token (standard 422), trimmed name and lower-cased email stored,
  case-insensitive duplicate refusal (409 `duplicate_enrolment`, never a resume), reserved-domain addresses refused on
  all five enrolment paths, no mail ever sent to a visitor address, no identity in logs or Sentry, the
  `participant_pii` purge redacting `participants.email` per row (hash placeholder under a reserved domain, with a
  backfill predicate), the admin participants search `q` also matching the email, OpenAPI regeneration.
- frontend: vendored `Input` and `FieldError`, identity validation util, `ReusableIdentityForm` molecule, the redeem
  composable sending the identity and mapping 409 and 422, a non-secret reload flag and the `link_reopen` terminal, the
  page state machine, i18n it/en, unit and Playwright (chromium and webkit, axe).
- backoffice: copy only (invite checkbox description, link name help, the disclosure, the participants search
  placeholder), pins, snapshot.
- wrapper: this document, DESIGN.md section 16.19 and the 16.18 quotations, CLAUDE.md ruling 2, the G-43 note, the live
  specs (merge of the deltas), release pins.
- Out of scope: verifying the email (no code, no confirmation link), a consent checkbox, a privacy-policy link,
  tenant-editable notice text, per-tenant branding of the form, a public `/v1` field or contract change, mobile support,
  FR-006 multi-test portal.

## Constraints (binding)
- OD-1: the email is self-declared and UNVERIFIED. Squatting an address and a project-scoped enrolment oracle through
  the 409 are accepted and documented.
- OD-2: a short, fixed, localized (it/en) privacy notice above the submit button, NO checkbox, no link, no
  verification step; legal may adjust the wording without structural change.
- Full GDPR purge: `participant_pii` redacts the name to `[purged]` and the email to a non-identifying placeholder
  `<sha256 of candidate_ref>@purged.beai.invalid` in the same pass, with no new duration.
- The admin participants search `q` also matches the email (owner decision; the spec assumption that it already did was
  false).
- No legacy backward compatibility (greenfield): api first, then frontend, then backoffice, deployed back to back.
- The identity travels only in the single redemption body: never in the URL, storage, history, router state, logs,
  analytics or error reports. The token stays in a plain variable; the reload flag holds `'1'` only.
- Public `/v1` byte-identical (`openapi.v1.json`); the additive 422 cause is recorded only in `DECISIONS-NEEDED.md`.
- DESIGN.md carries every UI decision BEFORE the UI is implemented (wrapper-1 precedes fe-1b).
- `scripts/ci-guards.sh` requires `tests/unit/fixtures/reusable-link-scrub-cases.ts` byte-identical in frontend and
  backoffice: the identity scrub pin is a new frontend-only spec and the shared fixture is not edited.
- Repo language English; conventional commits; no AI attribution, no Co-Authored-By; Bun only in the Nuxt apps.

## Execution settings
- Strict TDD: ENABLED (source: session configuration). Runners: Pest (Postgres only) for the api, Vitest
  (`bun run test:unit`) for frontend and backoffice, Playwright (chromium and webkit; the frontend also its mobile
  project) for E2E.
- SDD: pace auto, artifact store Engram, delivery strategy `auto-chain`, chain strategy `stacked-to-main` (per repo:
  each slice branch is cut from the previous one and its PR targets that branch; the first PR of each repo targets that
  repo's `develop`). Review budget 400 changed lines; over-budget slices are reported with `size:exception`, never
  trimmed.
- Forecast: about 5,300 to 6,900 authored lines (api 2,300 to 2,700; frontend 1,500 to 1,750; backoffice 70 to 130;
  wrapper about 2,300, of which about 1,600 is the verbatim spec merge).
- Test env: throwaway Postgres on 5434, migrate before any export, the host has no phpredis.

## Route legend
D = delegated writer (one SDD apply executor per slice, one writer at a time per repo); I = direct inline by the
parent. Every slice touches 2+ non-trivial files, so each runs as D (writer trigger).

## Tasks
Each slice closes with at least one work-unit commit on its stacked branch; the hash and the checks are recorded in the
Evidence line when observed. Checkboxes are checked only with observed outcomes.

- [x] wrapper-1 (VI-wr-1.1 to 1.6) docs before the UI slices: this document, DESIGN.md 16.19 and the 16.18 quotes,
      CLAUDE.md ruling 2, the G-43 note [D]. Evidence: wrapper commit 992e0cd on `feature/vi-wrapper-1` (cut from
      `origin/develop` 62e3bb0; 4 files, +263/-16, docs only). Acceptance greps: no match for "interviews started
      from it" in DESIGN.md and none for "not matchable to a data subject" in CLAUDE.md; "purged.beai.invalid" has one
      match in CLAUDE.md; AGENTS.md is still a symlink to CLAUDE.md; the three 16.18 quotes equal the strings in the
      backoffice tasks. Guards: `scan_bun_only`, `scan_sanctum`, `scan_laravel12` and `scan_horizon` clean over the
      edited files. `task test:scripts` reports 24 passed and 1 failed ("minified JSON resolves the real path"); the
      identical failure occurs on `origin/develop` with the changes stashed, so it is environmental and pre-existing,
      not caused by this slice. The Engram mirror `odd/reusable-link-visitor-identity/tasks` was written from this file.
- [ ] api-1a (VI-api-1a.*) shared identity request helper, call sites migrated, pure refactor [D]. Evidence: pending.
- [ ] api-1b (VI-api-1b.*) identity required, trimmed, stored; TrimStrings key exception; 422 [D]. Evidence: pending.
- [ ] api-1c (VI-api-1c.*) `NotPlaceholderEmail`, `is()` normalization, limiter and arch pins [D]. Evidence: pending.
- [ ] api-2 (VI-api-2.*) duplicate email 409, constraint mapping, concurrency [D]. Evidence: pending.
- [ ] api-3 (VI-api-3.*) no mail to a visitor; no identity in logs or Sentry [D]. Evidence: pending.
- [ ] api-4a (VI-api-4a.*) the purge redacts the email with the name [D]. Evidence: pending.
- [ ] api-4b (VI-api-4b.*) reserved domains refused on all five enrolment paths [D]. Evidence: pending.
- [ ] api-5 (VI-api-5.*) admin participants `q` matches the email [D]. Evidence: pending.
- [x] fe-1a (VI-fe-1a.1 to 1a.7) vendored `Input` and `FieldError`, identity validation util, i18n keys [D]. Evidence:
      frontend commit 567ab80 on `feature/vi-fe-1a` (cut from `origin/develop` c4adc5d; 10 files, +568/-2, of which
      about 350 are tests and about 56 are locale copy). RED observed first for each of the three specs (module
      missing; 48 missing-key failures). Final: `bun run lint` exit 0 (3 warnings in the vendored `Input.vue`, none new
      in kind), `bun run typecheck` exit 0, `bun run format:check` exit 0, `bun run test:unit` 76 files / 1888 tests
      green, coverage 94.22% lines. Mutation checks: 7 on the validation util, 5 on the locale guards, 2 on the vendored
      components, each caught by a test. Deviation: the frontend `Input.vue` drops `disabled:pointer-events-none`
      (pre-commit review finding; DESIGN.md section 5 requires `not-allowed` on disabled controls, vendored source
      included); the backoffice copy still has it, a follow-up. Size: ~570 lines against ~250 forecast, tests dominate
      and nothing was trimmed (`size:exception` recommended). The host needed the git-ignored `public/proctor/` assets
      copied from the main checkout for `proctor-assets.spec.ts` (local setup, not committed).
- [ ] fe-1b (VI-fe-1b.*) `ReusableIdentityForm` molecule [D]. Evidence: pending.
- [ ] fe-2a (VI-fe-2a.*) api snapshot, composable, pending-flag util, `link_reopen` terminal, scrub pin [D]. Evidence:
      pending.
- [ ] fe-2b (VI-fe-2b.*) page state machine wiring [D]. Evidence: pending.
- [ ] fe-3 (VI-fe-3.*) Playwright chromium and webkit including axe [D]. Evidence: pending.
- [ ] bo-1 (VI-bo-1.*) copy, pins, snapshot [D]. Evidence: pending.
- [ ] wrapper-2a (VI-wr-2a.*) live specs: reusable-interview-links and participant-sso [D]. Evidence: pending.
- [ ] wrapper-2b (VI-wr-2b.*) live specs: interview-frontend and observability [D]. Evidence: pending.
- [ ] wrapper-2c (VI-wr-2c.*) live specs: admin-backoffice, data-retention, admin-read-api correction [D]. Evidence:
      pending.
- [ ] api-R, fe-R, bo-R (VI-api-R.*, VI-fe-R.*, VI-bo-R.*) release preparation, gated [D]. Evidence: pending.
- [ ] release chain (VI-wr-R.1 to R.4) gated on an explicit user request; no deploy is inferred [I]. Evidence: pending.
- [ ] wrapper-3 (VI-wr-3.1, 3.2) pins and close [D]. Evidence: pending.

## Route declaration and trigger evidence
Pending per slice. Planning artifacts came from sdd-* agents (mapping and preparation triggers); implementation slices
run through one bounded SDD apply executor each (writer trigger).

## Review and checks record (per task)
Pending per slice: for each commit, the focused test result, the full-suite or F-CHECKS result, the mutation checks, the
assessed review tier and its outcome (granted, declined, passive, under budget, already reviewed, unavailable), and every
failed, skipped or unavailable check recorded honestly.

## Decisions recorded (accepted, with rationale)
- OD-1 (owner decision) unverified self-typed email: redemption sends no mail, and verification would need delivery to
  an address nobody has confirmed; squatting and the project-scoped 409 oracle are accepted and documented.
- OD-2 (owner decision) short fixed it/en notice with no checkbox: a collection notice, not the full interview privacy
  notice (DESIGN.md section 12).
- The purge placeholder is `<sha256 hex of candidate_ref>@purged.beai.invalid` (84 characters, always valid, RFC 6761
  non-resolvable); the old `<ref>@invalid.beai.local` overflows for long references and `.local` is mDNS.
- Spec copy wins over design copy where they differ (R1); the shared scrub fixture is not edited (R6); the v1 note lives
  only in the decision log (R7); DESIGN.md section 17 is a procedure, so no changelog line is added (R10).

## Open follow-ups
- Legal confirmation of the privacy notice wording (OD-2); native Italian pass on every Italian string of the change.
- G-43 residual: the case-sensitive unique index lets a concurrent mixed-case insert from the admin, M2M or SSO paths
  race the visitor path.
- The admin participants `q` puts an email address in a GET query string: server access logs may carry it (the Sentry
  scrubber is pinned).
- Legacy anonymous rows created before this change stay anonymous (placeholder email, `<label> #<n>` name).
- Retention durations stay the data controller's decision; the purge remains disabled by default.
- Backoffice `Input.vue` still carries `disabled:pointer-events-none` (a disabled input cannot show `not-allowed`);
  fix it in bo-1 or a separate change, with a rendered-class-list test like the frontend one.
- The `task test:scripts` failure "minified JSON resolves the real path" is pre-existing on `develop` (environmental).

## Progress
- 2026-10-01: SDD planning artifacts saved to Engram (144 tasks); wrapper-1 started.
- 2026-10-01: wrapper-1 (992e0cd) and fe-1a (567ab80) committed locally, not pushed, no PR. Both are independent of the
  api slices. The native review of each candidate is the orchestrator's.
