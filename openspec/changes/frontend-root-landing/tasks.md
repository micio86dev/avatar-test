# Tasks: Frontend Root Landing

> Strict TDD. One PR on `frontend`, off `develop`. Small enough that the
> chained-PR machinery would cost more than it returns.

## Review Workload Forecast

| Field | Value |
|-------|-------|
| Estimated production lines | ~40 (page + 4 i18n strings) |
| Estimated test lines | ~120 |
| 400-line budget risk | None |
| Chained PRs recommended | No |

## Phase 1 — RED

- [x] 1.1 `tests/unit/root-page.spec.ts`: the page renders `root.title` and `root.message` from i18n.
- [x] 1.2 RED: the page contains **no** `input`, **no** `form`, and **no** submit button. This is the scope guard — the failure it prevents is somebody adding a login field because a root route "should have one".
- [x] 1.3 RED: the rendered text contains no login / sign-up / support-contact affordance.
- [x] 1.4 `tests/e2e/root-landing.spec.ts`: `GET /` returns 200, not 404.
- [x] 1.5 RED: the document declares `noindex, nofollow`.
- [x] 1.6 RED: `<title>` is non-empty (WCAG 2.4.2).
- [x] 1.7 RED: axe reports no WCAG 2.1 AA violation.
- [x] 1.8 RED: on the mobile project, `/` redirects to `/unsupported` — asserts the existing global gate still covers the root.

## Phase 2 — GREEN

- [x] 2.1 `i18n/locales/it.json`: add `root.title`, `root.message`.
- [x] 2.2 `i18n/locales/en.json`: the same keys. Both locales in the same commit — a missing translation does not error, it silently renders the other language.
- [x] 2.3 `app/pages/index.vue`: `role="main"` labelled by its heading, copy via `$t()`, `useHead` with title + robots meta, `data-testid="root-landing"`. Modelled on `unsupported.vue`; no API call, no reactive state.
- [x] 2.4 Run Phase 1 to GREEN.

## Phase 3 — Gates

- [x] 3.1 `bun run format:check`
- [x] 3.2 `bun run typecheck` — 0 errors
- [x] 3.3 `bun run codegen:check` — unchanged (no API surface touched)
- [x] 3.4 `vitest run --coverage --coverage.thresholds.lines=85`
- [x] 3.5 `playwright test` — chromium, webkit, mobile
- [x] 3.6 Verify live: **DONE** — rebuilt the frontend image, `curl localhost:3000/` returns **HTTP 200** with `root-landing`, the `noindex, nofollow` meta and the Italian heading rendered by the real container.

## Phase 4 — Ship

- [x] 4.1 Open the PR against `frontend/develop`. **DONE** — micio86dev/frontend#11, CI green, merged (`0c285a4`).
- [x] 4.2 After merge, bump the wrapper submodule pointer. **DONE** — pinned to `0c285a4` in this change.

## Documented, Not Scoped

- **The `error` / `terminal` landing page.** `interview-frontend/spec.md` records
  it as out of C10 scope and "remains a future gap". Same family of problem —
  what a human sees when they fall off the happy path — and deliberately still
  open. This change fixes the root only.
- **A support contact on the root.** Rejected in design D2, not forgotten: BEAI
  holds no candidate contact data and is not their support channel. The party
  who sent the link is.
