# Tasks — Dashboard end-to-end coverage

## Phase 1 — test hooks (production, minimal)

- [x] 1.1 `MetricCard` forwards a `data-testid`.
- [x] 1.2 `pages/index.vue` names each of the five tiles, by metric rather than
      by position.

## Phase 2 — RED

- [x] 2.1 RED `tests/e2e/dashboard.spec.ts`: the five tiles render their values.
- [x] 2.2 RED same file: the activity feed renders rows, and its empty state
      when there are none.
- [x] 2.3 RED same file: a failed metrics load renders the error state and NOT
      the feed's empty state.
- [x] 2.4 RED same file: a 409 renders `not-ready`, not destructive.
- [x] 2.5 RED same file: selecting a period re-queries BOTH endpoints with the
      same range.
- [x] 2.6 RED same file: clearing the year clears the month and returns to
      all-time.
- [x] 2.7 RED same file: axe-core clean, following whatever pattern the existing
      specs use.

## Phase 3 — GREEN and proof

- [x] 3.1 Suite green on chromium AND webkit.
- [x] 3.2 Mutation-verify each assertion against a deliberately broken page,
      confirming the mutation landed before trusting the result.
- [x] 3.3 `bun run lint` and `bun run typecheck` exit 0.
