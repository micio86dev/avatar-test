# Backoffice role-aware onboarding wizard + guide

## Objective

Give a logged-in backoffice user (admin / operator / viewer, and the superadmin
platform-scope views) a way to understand the dashboard's steps and logic,
tailored to what their role can actually see and do:

1. A **wizard**: a one-time, non-blocking, dismissible/re-openable coach-mark
   tour of the sidebar navigation, shown on first login, spotlighting only the
   nav items visible to that role, in order, ending on the existing Help
   button.
2. A **guide**: the existing `HelpSheet.vue` per-route side panel, enriched so
   its steps/glossary reflect what the current role can actually do on that
   page (not describe actions a viewer/operator cannot perform).

## Problem / why

Requested directly by the user (2026-09-21): "sviluppa un wizard e una guida
per spiegare bene tutti i passaggi e le logiche della piattaforma dashboard in
base al ruolo utente loggato. Cura molto la UI/UX con la skill del designer se
necessario." Confirmed scope: backoffice only (frontend candidate app has a
single linear flow with no roles, so the premise doesn't apply there).

## Constraints (binding, discovered during exploration)

- **`HelpSheet.vue`'s own docblock explicitly rules out a modal product tour**:
  "Not a documentation site and not a product tour... A modal tour would cover
  the thing it is describing." The wizard MUST NOT be a full-screen/modal
  overlay. User explicitly chose (AskUserQuestion, 2026-09-21): first-login
  coach-mark tour (non-blocking) + enriched guide, over a classic modal wizard.
- **Never gate on `roles`, only on `can(ability)`** (`useCurrentUser.ts`) — the
  anti-pattern is called out explicitly in `EvaluationAuditPanel.vue:78-108`.
- **Client vs platform scope is not a permission** (`visibleNavItemsFor`,
  `app/utils/nav-visibility.ts`, DESIGN.md §8.1). The tour must walk the same
  filtered nav list the sidebar actually renders, never a hardcoded list.
- **No `localStorage`/`sessionStorage` for anything auth-sensitive** (tokens
  are memory-only). A "tour seen" flag is a non-sensitive UI preference and
  follows the existing `analytics-consent.ts` / `ConsentBanner.vue` pattern.
- **DESIGN.md is authoritative**: no new UI decision ships without updating it
  first (project CLAUDE.md). This change adds a new §8.2.11 documenting the
  coach-mark tour pattern, so a future change doesn't quietly drop it (same
  reasoning DESIGN.md already applies to `HelpSheet`).
- **Motion**: reuse existing tokens/patterns (§10) — no animation by default
  beyond what's already defined; respect `prefers-reduced-motion`. No new
  z-index layer invented without necessity (reuse `--z-tooltip`/`--z-modal`
  scale as appropriate for an anchored, non-blocking callout).
- **i18n**: every string i18n-keyed, it/en, following the existing `help.*`
  nesting convention (`i18n/locales/{en,it}.json`).
- **Atomic design / container-presentational**: new presentational piece is a
  molecule; orchestration (composable + state) lives in an organism/composable,
  not inside the molecule.

## Scope

In scope: `backoffice` submodule only.
Out of scope: `frontend` (candidate app) — explicitly excluded by the user.
Out of scope: rebuilding `HelpSheet` from scratch, changing its per-route
topic keys, or turning it into a tab strip / different pattern.

## TDD

Strict TDD mode is ON for this session (source: Agent Teams Lite orchestrator
instructions). Runner: Vitest (`backoffice/tests/unit`) for units/components,
Playwright (`backoffice/tests/e2e`) for the end-to-end flow. RED observed
before implementation, then GREEN, then REFACTOR, for every task below.

## Tasks

- [x] **T1 — Onboarding storage utility.** `app/utils/onboarding-storage.ts`:
  `hasSeenOnboardingTour(storage, userId)` /
  `markOnboardingTourSeen(storage, userId)`, mirroring
  `app/utils/analytics-consent.ts`'s defensive-`window` pattern. Keyed per
  user id (not per role) so a role change doesn't quietly re-trigger it. Unit
  tests only.
- [x] **T2 — `useOnboardingTour` composable.** Reads `useCurrentUser()`
  (`user`, `can`) and `visibleNavItemsFor` to compute the ordered, role-filtered
  step list (one step per visible nav item, plus a final step anchored on the
  Help button). Exposes current step index, next/back/skip/finish, and
  seen-state via T1. No DOM/positioning logic here (that's the molecule's job).
- [x] **T3 — `CoachMark.vue` molecule.** Presentational anchored callout:
  props for target rect/element ref, title, body, step index/total; emits
  next/back/skip/finish. `role="dialog"` with `aria-describedby`, reachable by
  keyboard, `Escape` dismisses (§9.4), positioned relative to target without
  covering it, respects `prefers-reduced-motion`. No modal backdrop that blocks
  the rest of the page.
- [x] **T4 — `OnboardingTour.vue` organism.** Wires T2 + T3 into `SidebarNav`
  (or the layout that renders it): resolves target elements for each nav item
  by ref/selector, mounts only when `!hasSeenOnboardingTour`, calls
  `markOnboardingTourSeen` on finish/skip. Re-openable later via a control on
  the existing Help button (§8.2.4) — no new persistent nav entry.
- [x] **T5 — Role-aware `HelpSheet.vue` content.** Filter/adjust each route
  topic's steps (and glossary where relevant) by `can()`, so a viewer/operator
  never reads instructions for an action their role can't perform. Content-only
  change: no restructuring of the sheet itself (§8.2.4 constraints stay).
- [x] **T6 — i18n.** New `onboarding.*` namespace (it/en) for T3/T4 copy;
  role-conditional variants added under existing `help.*` keys for T5. Zero
  hardcoded strings.
- [x] **T7 — DESIGN.md §8.2.11.** Document the coach-mark tour pattern (why
  not a modal, why per-user not per-role storage, why it defers to the same
  filtered nav list as the sidebar) so it isn't quietly dropped later, per
  §17's update process.
- [x] **T8 — Playwright E2E.** First login shows the tour for each role
  (admin/operator/viewer) with the right step count; dismiss persists across
  reload; reopen from Help button; `HelpSheet` content differs by role on a
  shared route (e.g. `/settings`). Extends `tests/e2e/dashboard.spec.ts` /
  `sidebar-navigation.spec.ts` fixtures rather than inventing new mocking.

## Acceptance criteria

- Tour never blocks or covers the dashboard content (no modal backdrop).
- Tour only ever shows nav items the logged-in role can actually see.
- Tour is dismissible, persists dismissal per user, and is re-openable.
- `HelpSheet` content never instructs an action the current role cannot take.
- No `roles.includes(...)` gating introduced anywhere (only `can()`).
- All new/changed UI is WCAG 2.1 AA (focus, keyboard, contrast per §9).
- DESIGN.md updated before/alongside the new pattern ships.
- Vitest + Playwright green; each task's RED→GREEN→REFACTOR evidence recorded
  below as it completes.

## Delivery strategy

`ask-on-risk` (default). Forecast: ~350-450 authored lines across T1-T8 —
near the ~400-line advisory heuristic; will re-forecast after T1-T4 land and
ask once for a chain strategy if the running count clears it.

## Progress log

- 2026-09-21 — Exploration complete (delegated agent), two AskUserQuestion
  rounds resolved (backoffice-only scope; coach-mark + enriched-guide
  approach over modal wizard). Task file created. No source written yet.
- 2026-09-21 — T1-T8 implemented and committed on
  `feature/role-aware-onboarding-tour` (backoffice), commit `18feeec`
  "feat(onboarding): add the role-aware first-login guided tour". Manually
  verified end-to-end in a real browser: tour auto-opens for a first-time
  user, highlights the real sidebar/Help elements, next/back/skip/finish all
  work, dismissal persists across reload. 2391 backoffice tests green.
  Shipped via Git Flow: feature → `4e1b420` merge into develop → bumped to
  0.38.0 (`c9456fc`) → `release/0.38.0` → `2d99dc7` merge into main, tagged
  `v0.38.0` → merged back to develop. Railway deployment `8c796117` for
  commit `2d99dc7` is SUCCESS; live URL
  `backoffice-production-ec05.up.railway.app` spot-checked HTTP 200. Wrapper
  superproject repinned to backoffice v0.38.0 and bumped to 0.42.5, tagged
  `v0.42.5` on main, merged back to develop — this cycle was already
  complete before this note was written. `feature/role-aware-onboarding-tour`
  and `release/0.38.0` branches are already gone locally and on origin, so
  no cleanup action was needed.

## Next step

None — change is implemented, tested, deployed, and live. Close/archive
this feature document on request; otherwise no further action pending.
