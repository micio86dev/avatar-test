# BEAI Public API, Embed SDK and Developer Area — Implementation Report

Status: implementation complete on branch `feature/public-api` in all five repos.
**Nothing has been deployed, released, pushed (except `embed`, see §5) or merged.**
Sources: `SPEC.md`, `DECISIONS-NEEDED.md`, `odd/tasks/public-api.md`, and `git log` of each repo.
Figures below are the ones recorded in the task document; none were re-derived for this report.

## 1. Scope delivered, per SPEC §7 step

Commit hashes are per repo (`api`, `frontend`, `backoffice`, `embed`, wrapper). Each commit passed the
repo's `gga` pre-commit gate, and slices that fit the reviewer budget were also RDD-reviewed.

| Step | Delivered | Commits | Verified |
|---|---|---|---|
| P0 | Audit of API keys, media storage and admin serializers; Q1–Q6 answered; `DECISIONS-NEEDED.md` created | wrapper `883528e` | gga passed on 2nd attempt; RDD approved |
| 1 | Spectral lint and vendored-copy parity in wrapper CI; `assertMatchesContract` helper; `/api/v1/health`; `config/public_api.php` (`T-CONTRACT-002..005`) | api `479d631`, wrapper `b928e0e`, `287ad87` | pest 7/7 re-run by parent; shellcheck and dash re-run |
| 2 | Auth middleware, scopes, tenancy guard (`T-AUTH-001..009`) | api `24219b9`, follow-up `a49e7b1` | pest 354/354 and 426/426 (follow-up) re-run by parent |
| 3 | problem+json, pagination, rate limit, idempotency, request-id (`T-CONV-001..012`) | api `1ce0167`, follow-up `7f0e1ce` | pest 423/423 and 112/112 re-run by parent; full api suite 4036 green |
| 4 | Organization and project reads (`T-PRJ-001..005`, `T-EXPOSE-001/002`); found and fixed the `/v1` middleware-priority defect (G-35) | api `c807d32` | pest 567/567 re-run by parent; full suite 4087 green |
| 5 | Interview enrolment, lifecycle mapping, session tokens and exchange, `interview_events`, hosted page `/i/{token}` (`T-INT-001..016`, `T-TOK-001..014`) | api `cc6ecc3` re-cut as `cf29bf2`, `3520b3f`, `e1ef9eb`, `1a740aa`; follow-ups `c3f2dc7`, `ae16aa7`; frontend `3037435` | RDD approved all slices; 4 gga rounds, 23 findings fixed. The task doc still shows the S5 parent box unchecked although both sub-items are checked. |
| 6 | Transcript, answers, scoring, audio recording, events (`T-INT-017..025`) | api `9179443`, `a86269f`, `c9a7599`, `9e2e287`, follow-up `da87df1` | RDD approved all four slices; full suite 4261 green |
| 7 | Webhook delivery log and redeliver over the existing C10 path (`T-WHD-001..019`) | api `a8d4080` | gga round 2 approved; full suite 4282 green |
| 8 | Exports (`T-EXP-001..010`) and usage (`T-USAGE-001..004`) | api `11d96f4`, `171bf34`, `59414f2`, `510863c` | 7 gga rounds on the base commit; fixed a strand-on-crash export reclaim bug, a webhook redeliver race, a CSV formula-injection hole and test-mode reads of live data; pest 529/529 targeted |
| 9 | Test mode, `MockProvider` (zero outbound calls) and `RunMockInterviewJob` (`T-TEST-001..006`) | api `95ce204`, `0b8a555`, `52fe762`, `f19a152`, `35bdea5` | each commit RDD-reviewed; targeted suite 654–657 green; two round-3 decisions reversed (see G-53) |
| 10a | `@beai/embed` package core; new 4th submodule | embed `4743c05` scaffold … `2d7690d` (9 commits ahead of `develop`) | 55 Vitest tests; gz bundle 2.06KB against a 12KB budget |
| 10b | `/embed/{token}` page: shared `InterviewSession.vue`, read-only `GET /api/embed/frame-policy`, per-request `frame-ancestors` middleware (fail-safe `'none'`), tab-hidden and network-drop guards, postMessage bridge, error mapping | api `6e51c1c`, `50d9497`; frontend `72747c3`, `204f376`, `d525f89` | pest 24/24 (api embed tests); frontend vitest 1543; headers checked on a real built server (no `X-Frame-Options`, CSP `'none'` when the api is unreachable) |
| 10c | `resize` event, embed CI workflow with bundle-size gate, Playwright framing E2E, device-width gate for framed pages | frontend `6d9f236`, `dc0244e`; embed `2d7690d` | vitest 1561; Playwright gate and embed specs 34/34 (run before the last gate refactor) |
| 11a | `/v1`-only Scramble export (`openapi.v1.json`), `T-CONTRACT-001` equivalence test, API-key security scheme and server declared | api `319e327`, `b36ef7c`; frontend `44c6125`; backoffice `29c1005`, `ff7391f` | Contract and OpenApi tests green; 11 divergences allow-listed (G-54) |
| 11b | Self-hosted Scalar reference at `/developers/` in the backoffice nginx stage; wrapper CI guard for vendored-spec drift | backoffice `6f920c1`; wrapper `4a0fac2` | backoffice vitest 2445; headless render made zero external requests |
| 11c | SDKs for TS (`@beai/sdk`), PHP (`beai/beai-php`), Python (`beai`) generated in-tree under `sdks/` with openapi-generator 7.25.0; CI drift job | wrapper `2797291` | regeneration byte-identical; smoke script passes (TS client sends `Authorization: Bearer`, 58 PHP files linted, 60 Python files parsed) |
| 11d | `docs/quickstart.md` with tagged executable steps, run by `QuickstartTest` | api `613b47d` | passes; mutation-checked by the writer; no outbound HTTP |
| 12 | Permanent rule: no new public or export field without a `T-EXPOSE-001` entry | api `eef1a33`; wrapper `CLAUDE.md` (`AGENTS.md` is a symlink to it) | rule text only |
| 13 | This report | — | — |

Commits ahead of `develop` on `feature/public-api` (`git rev-list --count develop..HEAD`): wrapper 33,
api 35, frontend 7, backoffice 4, embed 9.

## 2. Test evidence summary

Only figures recorded in the task document or produced during the steps above are cited:
full api suite 4036 (step 3), 4087 (step 4), 4261 (step 6), 4282 (step 7); frontend vitest 1561 and
backoffice vitest 2445 at their last runs; embed 55 Vitest tests; Playwright gate and embed specs 34/34.
These are point-in-time results per step, not a final run.

## Full-suite results

Final full runs on branch `feature/public-api` (2026-09-25), executed locally; the CI jobs
themselves have not run.

| Suite | Result |
|---|---|
| api pint `--test`, phpstan | pass, 0 errors |
| api Pest `--parallel` | 4396 tests: 4389 passed, 7 skipped, 0 failed |
| api coverage (informational; `--min=85` not passed) | lines 94.90%, methods 81.83%, classes 68.43% |
| frontend typecheck, lint, prettier | clean |
| frontend Vitest | 1561/1561 |
| frontend Playwright (chromium, webkit, mobile) | 153 passed, 1 skipped |
| backoffice typecheck, prettier | clean; lint 0 errors, 51 pre-existing warnings |
| backoffice Vitest | 2445/2445 |
| backoffice Playwright | 234 passed |
| embed typecheck, lint, prettier, Vitest | clean; 55/55 |
| embed build + bundle-size gate | 2.06 KB gzipped vs 12 KB budget |
| wrapper shellcheck (`-s sh`) and `dash -n` | clean on `sdks/*.sh`, `scripts/ci-guards.sh`, `scripts/verify-openapi-parity.sh` |

Not exercised: the `ci-guards.sh` self-tests (it is a function library when run directly), the
`public-api-sdks` CI job, the Docker image build, and mount-to-completed E2E against the mock provider.

## 3. Open decisions

**Needs an owner decision**
- **G-01** Audio recording ingestion: no provider returns a recording. Step 6 built storage and the signed endpoint only; confirm whether provider ingestion is wanted.
- **G-03** Real public hostnames (`api.`, `developers.`, `interview.`, `cdn.`); docs and the spec server URL still use `beai.example`.
- **G-32** Session-token exchange reuses the candidate JWT instead of the cookie in SPEC §3.5; confirm.
- **G-43** Normalise email case on the SSO ingress and replace the unique index with a functional `lower(email)` index (a migration with a possible backfill collision).
- **G-45** `participants.public_id` NOT NULL and rolling deploys; deploy order is new code first, then migration; the owner may prefer a trigger-based default.
- **G-51** Interview reads are not scoped by key mode, so a test key can read live interview data; decide whether `participants.mode` gates every public read.
- **G-54** Eleven recorded divergences between the `/v1` export and `openapi.yaml`; decide which side moves for each, and whether error-body schemas are compared.
- **G-55** Change the API so the `errors: null` schema is generator-safe, or keep the generation-time rewrite.

**Technical follow-up**
- **G-52** Six plural `withoutGlobalScopes()` sites left in `EvaluationPayloadAssembler.php` (5) and `WebhookDeliveryRecorder.php` (1); convert to the allow-listed singular form.
- **G-56** API-side defects visible in the SDKs: default server `http://localhost/api/v1`, internal review notes in public docstrings, `evaluations.pending` typed `string`, `PublicInterview.metadata` typed `Array<any>`, empty `PublicInterviewProgress`, and a merged 409 `errors` typed non-null.

Resolved entries (G-00, G-02, G-04..G-31, G-33..G-42, G-44, G-46..G-50, G-53) are recorded in `DECISIONS-NEEDED.md`.

## 4. Disclosed gaps and unverified items

- **Mount-to-completed E2E** (`T-SDK` ≤ 60 s against the mock provider) is not covered; no e2e fixture reaches a real api. The quickstart test covers the api side in-process only.
- **Never run:** the `public-api-sdks` job, the docs CI steps, and the embed CI workflow; whether the pinned Java 21.0.12, PHP 8.5.11 and Python 3.13.15 resolve in the setup actions is unconfirmed.
- **Docker image build** of `backoffice` (nginx `/developers/` stage) was not run; the Docker daemon was not running. Only the nginx location rules were tested locally.
- **Scalar "Ask AI" control** behaviour on click was not checked.
- **SDK issues:** see G-55 and G-56. Python SDK was only parsed, not imported (needs pydantic).
- **Quickstart limits:** candidate-facing steps (`/embed/exchange`, `/candidate/interview/start`) are not in the `/v1` contract; the test client bypasses TLS, real rate limiting and queue timing; the embed snippet is not executed and its CDN URL and `onCompleted` callback are unverified.
- **Server host** in the spec is the reference's `.example` placeholder; the reference path is `/v1` while the app serves `/api/v1`, so SDK users must set `basePath`.
- **Native review:** the RDD review of the accumulated wrapper range since `059d7c0` and of the frontend range stopped with `lens_context_budget_exceeded` (G-50 pattern); those ranges were covered by per-commit gga review instead. The task-doc S5 parent checkbox is unchecked.
- Frontend E2E for the `frame-policy` lookup uses a stub server; the real api endpoint is covered by api tests only.

## 5. Release and deploy readiness

- **No deploy has been done and none is authorized.** Nothing has been merged into `develop` or `main`, no release branch exists for this work, and no version bump was made.
- **Remote state** (`git ls-remote --heads origin`, checked for this report):
  - wrapper (`avatar-test`), `api` (`backend`), `frontend`, `backoffice`: `develop` and `main` exist; **`feature/public-api` does not exist on the remote**. Nothing has been pushed.
  - `embed` (`micio86dev/embed`): repo created; `develop`, `main` and `feature/public-api` exist, but the remote `feature/public-api` is at `4743c05` (initial scaffold). Local HEAD is `2d7690d`, so nine commits are unpushed.
- **Remaining before Git Flow:**
  1. Push the five `feature/public-api` branches, submodules first (verify each push landed before the wrapper pins it).
  2. Full test suites across api, frontend, backoffice and embed, then fill in the placeholder in §2.
  3. Resolve or explicitly defer the open decisions in §3, especially G-51, G-45 and G-03.
  4. PR to `develop` per repo; then `release/*` branches with SemVer bumps (`VERSION` and manifests agree, `openapi.json` re-exported after the bump; wrapper pins tagged submodule releases); merge to `main`, tag `vM.m.p`, merge back to `develop`.
  5. Railway deploy only on explicit request, following the deploy order in G-45.
- SDK repositories (`beai-php`, PyPI package) were not created and nothing was published; splitting `sdks/` and publishing is a separate release-step decision.
