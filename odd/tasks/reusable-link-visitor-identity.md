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
Evidence line when observed. Checkboxes are checked only with observed outcomes. Delivery: stacked PRs per repo; the
orchestrator pushed them (api backend#104 to #111, frontend #46, #47, #50, #51, backoffice #64, wrapper beai#45).

- [x] wrapper-1 (VI-wr-1.1 to 1.6) docs before the UI slices: this document, DESIGN.md 16.19 and the 16.18 quotes,
      CLAUDE.md ruling 2, the G-43 note [D]. Evidence: wrapper commit 992e0cd on `feature/vi-wrapper-1` (cut from
      `origin/develop` 62e3bb0; 4 files, +263/-16, docs only), PR beai#45 (not merged at the time of writing).
      Acceptance greps: no match for "interviews started from it" in DESIGN.md and none for "not matchable to a data
      subject" in CLAUDE.md; "purged.beai.invalid" has one match in CLAUDE.md; AGENTS.md is still a symlink to
      CLAUDE.md; the three 16.18 quotes equal the strings in the backoffice tasks. Guards: `scan_bun_only`,
      `scan_sanctum`, `scan_laravel12` and `scan_horizon` clean over the edited files. `task test:scripts` reports 24
      passed and 1 failed ("minified JSON resolves the real path"); the identical failure occurs on `origin/develop`
      with the changes stashed, so it is environmental and pre-existing, not caused by this slice.
- [x] api-1a (VI-api-1a.1 to 1a.6) shared identity request helper, call sites migrated, pure refactor [D]. Evidence:
      commit 2ecd6d9 on `feature/vi-api-1a` (PR backend#104). Strict TDD as a refactor under a green net: 1179 tests /
      9078 assertions before and after, identical. Pint and PHPStan clean.
- [x] api-1b (VI-api-1b.1 to 1b.15) identity required, trimmed, stored; TrimStrings key exception; 422 [D]. Evidence:
      commit e3add33 (PR backend#105). RED observed per task (13 failing validation cases, 3 storage failures, the
      contract lacking the keys and the 422); 6 mutations caught; `php artisan serve` + curl: `{}` -> 422 with
      `display_name` and `email`, valid identity with an unknown token -> 404; `openapi.v1.json` byte-identical, second
      export byte-identical. About 551 added / 112 deleted authored lines (forecast about 400): tests dominate,
      `size:exception` recommended.
- [x] api-1c (VI-api-1c.1 to 1c.9) `NotPlaceholderEmail`, `is()` normalization, limiter and arch pins [D]. Evidence:
      commit 1f0a264 (PR backend#106). RED: rule class missing (12 errors), `is()` case-sensitive, reserved-domain
      redemption returned 200; arch guard on the readers of `link_token` proven with a temporary offending file; 4
      mutations caught, incl. the per-link bucket and the per-IP key. About 364 added / 19 deleted.
- [x] api-2 (VI-api-2.1 to 2.11) duplicate email 409, constraint mapping, concurrency [D]. Evidence: commit 0c00c44 (PR
      backend#107). RED: mixed-case duplicate returned 200, same-case duplicates 500 (21 failures); real concurrent
      processes on committed Postgres (one link, two links, operator versus redemption) end in one 200 and one 409; 7
      mutations caught. About 579 added / 41 deleted (`size:exception`).
- [x] api-3 (VI-api-3.1 to 3.9) no mail to a visitor; no identity in logs or Sentry [D]. Evidence: commit 90a6b89 (PR
      backend#108). RED: `email_sent` true and a job pushed for a visitor; the never-logs matrix covers 200, 403, 404,
      409, 422, 429 and a mint failure with a control; Scramble caught `email_sent` exporting as string until an explicit
      bool cast; 7 mutations caught. Mailpit harness not run (no Mailpit on the host): Queue and Notification fakes carry
      the proof. About 347 added / 16 deleted.
- [x] api-4a (VI-api-4a.1 to 4a.10) the purge redacts the email with the name [D]. Evidence: commit b42b49f (PR
      backend#109). RED: placeholder helpers undefined, email not redacted, no backfill, dry run counted 1 not 3,
      collision not reported, 16 instead of 84 characters; SQL twin agrees with the PHP derivation for ASCII, Unicode,
      emoji and 255-character references; harness DB: dry run reports 1, real run purges 1, third run 0. About 539
      added / 55 deleted (`size:exception`).
- [x] api-4b (VI-api-4b.1 to 4b.8) reserved domains refused on all five enrolment paths [D]. Evidence: commit 726bbfc
      (PR backend#110). RED: 22 failures (four non-redeem paths accepted a reserved-domain address); own-placeholder
      exception only on the two re-issue paths; 9 mutations caught; `openapi.v1.json` and `openapi.json` unchanged.
      About 397 added / 18 deleted.
- [x] api-5 (VI-api-5.1 to 5.7) admin participants `q` matches the email [D]. Evidence: commit 7adfcab (PR backend#111)
      plus three review fixes on the tip add5fe1: e92e3b6 (the purge counts only the participants it actually
      redacted), c2a11e8 (the duplicate-email guarantees made explicit and pinned) and add5fe1 (the transaction result
      narrowed with `is_array`). RED: 8 failures (email invisible to `q`); 4 mutations caught, incl. the email branch
      outside the nested OR group (escapes the organisation scope). Full api suite 7790 tests, 0 failed (orchestrator
      run on the tip).
- [x] fe-1a (VI-fe-1a.1 to 1a.7) vendored `Input` and `FieldError`, identity validation util, i18n keys [D]. Evidence:
      frontend commit 567ab80 on `feature/vi-fe-1a` (cut from `origin/develop` c4adc5d; 10 files, +568/-2, of which
      about 350 are tests and about 56 are locale copy), PR frontend#46 together with the build fix 6b05db5. RED
      observed first for each of the three specs. Mutation checks: 7 on the validation util, 5 on the locale guards, 2 on
      the vendored components, each caught. Deviation: the frontend `Input.vue` drops `disabled:pointer-events-none`
      (pre-commit review finding; DESIGN.md section 5 requires `not-allowed` on disabled controls).
- [x] fe-1b (VI-fe-1b.1 to 1b.3) `ReusableIdentityForm` molecule [D]. Evidence: commit 24a4733 (PR frontend#47; the
      body carries the wrapper commit 992e0cd). 2 files, +687 (tests 465); 39 tests; 17 mutations, all caught after one
      added test. The axe pass stays with fe-3 (no unit-level axe helper exists).
- [x] fe-2a (VI-fe-2a.1 to 2a.10) api snapshot, composable, pending-flag util, `link_reopen` terminal, scrub pin [D].
      Evidence: commit 0c50008 on `feature/vi-fe-2a`. The snapshot and generated types come from the api-5 tip, codegen
      check OK; composable body is exactly `{link_token, display_name, email}` with seven outcomes; a new
      frontend-only scrub spec (the shared fixture is untouched); the analytics plan pins `/interview/reusable` as
      replay-unsafe. Shipped together with fe-2b in PR frontend#50 (see the incidents).
- [x] fe-2b (VI-fe-2b.1 to 2b.3) page state machine wiring [D]. Evidence: commit d74c9e7 on `feature/vi-fe-2b` (3
      files, +892/-341). Form first with no request, one request per submit, 409 and 422 stay on the form, retry
      re-posts the held token and identity, reload flag leads to the reopen terminal. 75 page tests, 24 mutations all
      caught; the leave navigation is an awaited `router.replace` (see the incidents). Unit: lint, typecheck and format
      exit 0, 79 files / 2026 tests. Native review of this candidate: pending at the time of writing.
- [x] fe-3 (VI-fe-3.1 to 3.5) Playwright chromium and webkit including axe [D]. Evidence: commit 487a3aa on
      `feature/vi-fe-3` (PR frontend#51): every redeem scenario goes through the form, the 11 items of VI-fe-3.2, a held
      router navigation scenario that fails with `navigateTo`, and 8 axe states. Frontend unit 2030 tests green; host
      E2E (never in a container) 146 passed in the orchestrator run; the executor's earlier whole-suite run was 290
      passed, 3 skipped (chromium, webkit, mobile).
- [x] bo-1 (VI-bo-1.1 to 1.8) copy, pins, snapshot [D]. Evidence: three commits on `feature/vi-bo-1` (PR backoffice#64):
      e784cad (copy en/it, 3 unit specs, e2e), 50059ed (a disabled `Input` shows the not-allowed cursor, with a rendered
      class test) and 81c6302 (the api-5 snapshot and generated client, `info.version` kept at 0.64.0 because the api-5
      branch was cut before develop reached 0.64.0). Unit 209 files / 3383 passed, coverage 96.77%, lint warnings equal
      to the baseline (54), typecheck and format exit 0, Playwright chromium and webkit 408 passed. About 75 authored
      lines. The `bun run dev` harness is N/A (no local api); the mocked-route Playwright suite is the runtime proof.
- [x] wrapper-2a (VI-wr-2a.1 to 2a.5) live specs: reusable-interview-links and participant-sso [D]. Evidence: commit
      1beb683 on `feature/vi-wrapper-2a` (stacked on `feature/vi-wrapper-1`; 2 files, +760/-217). Requirement counts:
      reusable-interview-links 23 -> 26 (4 added, 1 removed, 7 replaced in full), participant-sso 39 -> 40 (1 added, 1
      replaced); no duplicate names, every requirement keeps at least one scenario. Acceptance grep for the old
      anonymous wording is empty (the Previously line of the token-oracle requirement was rephrased so the legacy
      `validate()` sentence no longer appears). `scan_bun_only` over `openspec/specs` clean; AGENTS.md still a symlink to
      CLAUDE.md. `task test:scripts`: the same single pre-existing failure.
- [x] wrapper-2b (VI-wr-2b.1 to 2b.3) live specs: interview-frontend and observability [D]. Evidence: commit 7ef288e on
      `feature/vi-wrapper-2b` (stacked on 2a; 3 files, +489/-80 before this record). Requirement counts:
      interview-frontend 40 -> 44 (4 added, 1 replaced in full), observability 18 -> 19 (1 added); no duplicate names,
      every requirement keeps at least one scenario. Reconciled with the merged frontend (read-only): the exit is an
      awaited `router.replace`, busy and failed replace the form with a notice and a Retry control, an unmappable 422 is
      the retryable failed state, field errors are `role="alert"` and the privacy notice describes the submit button,
      the reopen state is the terminal route with reason `link_reopen`. The wording-gap limitation of
      reusable-interview-links was closed because the `link_invalid` copy no longer claims expiry. `scan_bun_only` over
      `openspec/specs` clean; AGENTS.md still a symlink.
- [x] wrapper-2c (VI-wr-2c.1 to 2c.4) live specs: admin-backoffice, data-retention, admin-read-api correction [D].
      Evidence: commit 8af9adf on `feature/vi-wrapper-2c` (stacked on 2b; 3 files, +380/-70 before this record).
      Requirement counts: admin-backoffice 70 -> 70 (2 replaced in full), data-retention 6 -> 7 (1 added, the inventory
      replaced), admin-read-api 24 -> 24 (the search requirement modified, three scenarios added, name kept). Reconciled
      with the merged api (read-only): the purge placeholder is `<sha256 hex of candidate_ref>@purged.beai.invalid`
      (84 characters; PHP and SQL twins agree), each row is written alone and a 23505 collision is skipped with a
      warning that carries only the id, the count is the rows actually written, a legacy anonymous row is kept only when
      it is exactly its own legacy placeholder. The Purpose sentence now names `participants.email`; no statement says
      the email is retained. One scenario was added beyond the delta: the participants search box placeholder names the
      email (decision R4, pinned in bo-1). Wrapper chain checks: every requirement named in the spec index exists exactly
      once, none has zero scenarios, no duplicate names, `scan_bun_only` over `openspec/specs` clean, AGENTS.md still a
      symlink to CLAUDE.md.
- [ ] api-R, fe-R, bo-R (VI-api-R.*, VI-fe-R.*, VI-bo-R.*) release preparation, gated [D]. Evidence: pending.
- [ ] release chain (VI-wr-R.1 to R.4) gated on an explicit user request; no deploy is inferred [I]. Evidence: pending.
- [ ] wrapper-3 (VI-wr-3.1, 3.2) pins and close [D]. Evidence: pending.

## Route declaration and trigger evidence
Planning artifacts came from sdd-* agents (mapping and preparation triggers). Every implementation slice touched 2+
non-trivial files and ran through one bounded SDD apply executor (writer trigger), route D; one writer at a time per
repo, in separate worktrees under the home directory. The orchestrator did the pushes, the PRs, the native review
actions and the cross-repo test runs. wrapper-2a, 2b and 2c are mechanical spec merges; each ran as D because the merge
touches several large files and needs the reconciliation reading of the merged api, frontend and backoffice code.

## Review and checks record (per task)
Native reviews as reported by the orchestrator (receipt-driven development on; the executor ran none):
- api 1c + 2: approved with advisories. api 3 + 4a: approved with advisories. api 4b + 5: approved with advisories.
  Across these three reviews 8 findings were fixed and 7 were answered with evidence.
- api 1a + 1b: ESCALATED. The review ended with an inconclusive finding R3-001 of unknown causality, and the tooling
  does not expose its text, so it is neither fixed nor refuted. Open.
- frontend fe-1a: approved. fe-3: approved. fe-2a: the review opened a correction, resolved structurally by folding
  fe-2a into fe-2b (PR frontend#50); its lineage remains open because abandoning it needs a maintainer authorization.
  fe-2b: review pending.
- backoffice bo-1 and the wrapper slices: no native review result had been reported when this was written.
Functional checks (observed): api 7790 tests, 0 failed (full suite on the tip); frontend unit 2030, host E2E 146 passed;
backoffice unit 3383, E2E 408 (chromium and webkit). Per-slice focused results and mutation counts are in the Evidence
lines above. Known environmental noise: api tests that read the wrapper `docs/` directory error when the worktree sits
beside rather than inside the wrapper (EvaluationPayloadAssembler, ForgetLocaleCommand); `task test:scripts` has one
pre-existing failure.

## Incidents
- Build break from a bare `@` in an i18n message (fe-1a): vue-i18n compiles messages at build time and reads `@` as a
  linked message, so `nuxt build` failed. Unit tests read the raw JSON and could not see it; the first E2E run did.
  Fixed with `{'@'}` (6b05db5, in the fe-1a PR frontend#46) and guarded by a spec that compiles every message
  (`i18n-message-syntax.spec.ts`).
- fe-2a alone broke the candidate page: it redeemed with an empty identity (and 422 and 409 were first unhandled).
  fe-2a and fe-2b were therefore folded into one PR, frontend#50.
- Product race fixed in fe-2b: leaving the reusable page with `navigateTo` was dropped while a router navigation was in
  flight (a pasted fragment fires popstate before hashchange), stranding the visitor on the page. It is now an awaited
  `router.replace`, pinned by a unit double that behaves like Nuxt's and by an E2E scenario that holds a navigation in
  flight and fails with `navigateTo`.
- Pre-commit review rejected the first fe-1a commit (disabled `Input` cursor and an overclaiming comment); fixed, no
  hook bypass. The same defect in the backoffice copy was fixed in bo-1 (50059ed).
- api review fix: the purge counted rows it did not redact; fixed in e92e3b6 (count only what was actually redacted).
- Local setup: Larastan needs `APP_KEY` exported; the Scramble export needs `APP_NAME=BEAI`; a fresh frontend worktree
  needs the git-ignored `public/proctor/` assets; the bo-1 snapshot kept `info.version` 0.64.0.
- The reusable-interview-links delta (about 49 KB) was near the Engram size cap, so the data-retention precedence
  correction was applied at merge time, in wrapper-2a, instead of editing the artifact.

## Decisions recorded (accepted, with rationale)
- OD-1 (owner decision) unverified self-typed email: redemption sends no mail, and verification would need delivery to
  an address nobody has confirmed; squatting and the project-scoped 409 oracle are accepted and documented.
- OD-2 (owner decision) short fixed it/en notice with no checkbox: a collection notice, not the full interview privacy
  notice (DESIGN.md section 12).
- The purge placeholder is `<sha256 hex of candidate_ref>@purged.beai.invalid` (84 characters, always valid, RFC 6761
  non-resolvable); the old `<ref>@invalid.beai.local` overflows for long references and `.local` is mDNS.
- Spec copy wins over design copy where they differ (R1); the shared scrub fixture is not edited (R6); the v1 note lives
  only in the decision log (R7); DESIGN.md section 17 is a procedure, so no changelog line is added (R10).
- The live-spec merge follows the implementation where it differs from a delta, with a "Reconciled with the
  implementation" line: the mail refusal at the dispatch site (the invitation job is scalar-only), the
  `NotPlaceholderEmail` rule on all five enrolment paths, and the `TrimStrings` exception registered on the key rather
  than the route. The data-retention delta supersedes the purge statement of the reusable-interview-links delta.

## Open follow-ups
- Legal confirmation of the privacy notice wording (OD-2); native Italian pass on every Italian string of the change.
- api 1a + 1b review: the inconclusive finding R3-001 (unknown causality, text not exposed by the tooling) needs a
  maintainer to read it; and the abandoned-by-fold fe-2a review lineage needs a maintainer authorization to close.
- fe-2b native review is pending.
- G-43 residual: the case-sensitive unique index lets a concurrent mixed-case insert from the admin, M2M or SSO paths
  race the visitor path.
- The admin participants `q` puts an email address in a GET query string: server access logs may carry it (the Sentry
  scrubber is pinned); recorded in the live reusable-interview-links spec as a known limitation.
- Legacy anonymous rows created before this change stay anonymous (placeholder email, `<label> #<n>` name).
- Retention durations stay the data controller's decision; the purge remains disabled by default.
- Release preparation (api-R, fe-R, bo-R), the gated release chain and the wrapper pins (wrapper-3) are not started;
  the bo-1 and fe-2a snapshots must be re-synced from the api release branch (`info.version` changes).
- The `task test:scripts` failure "minified JSON resolves the real path" is pre-existing on `develop` (environmental).

## Progress
- 2026-10-01: SDD planning artifacts saved to Engram (144 tasks); wrapper-1 started.
- 2026-10-01: wrapper-1 (992e0cd) and fe-1a (567ab80) committed locally. Both are independent of the api slices.
- 2026-10-01: the api chain (1a to 5), the frontend chain (fe-1a to fe-3) and bo-1 were implemented, pushed as stacked PRs
  and reviewed natively by the orchestrator (see the review record).
- 2026-10-01: wrapper-2a (1beb683) merged the reusable-interview-links and participant-sso deltas into the live specs,
  reconciled with the merged api code. A follow-up commit on the same branch (cd7bbec) made the merged bodies follow the
  implementation (mail refusal at the dispatch site, trim exception on the key, reserved-domain rule).
- 2026-10-01: wrapper-2b (7ef288e) merged the interview-frontend and observability deltas.
- 2026-10-01: wrapper-2c (8af9adf) merged the admin-backoffice and data-retention deltas and corrected the admin-read-api
  search. The deltas of this change are fully applied to the live specs: 11 requirements added, 12 replaced in full and
  1 removed (the index counts), plus the admin-read-api search requirement modified by the owner decision. Next:
  release preparation (api-R, fe-R, bo-R), then the gated release chain and wrapper-3, none of which is started.
