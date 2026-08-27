# DESIGN.md — BEAI UX/UI Reference

> **Authoritative**: this document is the single source of truth for all UX and UI
> decisions. No design decision that contradicts this file may be implemented without
> updating it first. All Tailwind `@theme` custom properties in `frontend` and
> `backoffice` MUST match the tokens defined here.

---

## 1. Design Principles

| Principle | Application |
|-----------|-------------|
| **Clarity** | Every element communicates its function without ambiguity. No decorative complexity. |
| **Trust** | Professional, calm aesthetic — candidates are in a high-stakes evaluation context. |
| **Focus** | Minimal chrome during the interview; maximum attention on the avatar and the question. |
| **Accessibility first** | WCAG 2.1 AA is a baseline requirement, not an afterthought. |
| **Desktop-optimized** | The product is desktop-only (Chrome 120+, Edge 120+, Safari 17+). No mobile support — the mobile viewport shows the unsupported-experience gate (SA-11). |
| **i18n by default** | Every visible string is i18n-keyed. No hardcoded text anywhere. |

---

## 2. Target Browsers & Viewport

| Browser | Supported | Notes |
|---------|-----------|-------|
| Chrome 120+ | Full | Primary target |
| Edge 120+ | Full | Chromium-based |
| Opera 100+ | Full | Chromium-based |
| Safari 17+ | Full | WebKit; tested via Playwright WebKit project |
| Firefox | **Not supported** | Excluded per NFR; users see the unsupported gate |
| Mobile (any browser) | **Not supported** | Mobile viewport triggers SA-11 gate; no functional UI |

**Minimum desktop resolution**: 1 280 × 800 px.
**Design viewport**: 1 440 px wide.
**Large desktop**: 1 920 px (fluid max-width containers).

---

## 3. Design Tokens

These tokens are the source of truth for the CSS `@theme {}` block in both Nuxt
apps (`assets/css/main.css`). They MUST be kept in sync.

### 3.1 Color Palette

> **Brand source of truth:** `docs/brand/quint-brand-guidelines.pdf` (official Quint
> guidelines — logo usage, negative versions, Pantone/CMYK, do's & don'ts). Demo
> implementation: `src/styles/brand.css`. Logo assets: `public/quint-logo.png` (logotype) +
> `public/quint-mark.png` (favicon source).

#### Brand

| Token | Value | Usage |
|-------|-------|-------|
| `--color-primary` | `#771AAF` | Quint purple (logo color) — headings, primary buttons, navigation active |
| `--color-primary-light` | `#C222D3` | Hover state of primary elements (light violet) |
| `--color-primary-dark` | `#4F1AAF` | Active / pressed state (dark violet) |
| `--color-accent` | `#E45526` | Quint institutional orange — CTAs, highlighted / active states |
| `--color-accent-light` | `#F19823` | Hover state of accent elements (orange) |
| `--color-accent-dark` | `#B8431E` | Active / pressed state of accent |
| `--color-lavender` | `#8373D2` | Supporting secondary (lavender) — subtle highlights, badges |

**Background** — pages use a very light brand gradient, not a flat fill:
`--color-bg-gradient: linear-gradient(135deg, #FAF7FD 0%, #F6F1FC 45%, #FDF4EF 100%)`
(near-white lavender→peach; supersedes flat `--color-neutral-50` for page backgrounds.
Strong purple/orange stay for accents only — per WCAG AA, orange `#E45526` is not used for
small body text.)

#### Neutrals

| Token | Value | Usage |
|-------|-------|-------|
| `--color-neutral-50` | `#f8fafc` | Page backgrounds |
| `--color-neutral-100` | `#f1f5f9` | Card / panel backgrounds |
| `--color-neutral-200` | `#e2e8f0` | Borders, dividers |
| `--color-neutral-400` | `#94a3b8` | Placeholder text, disabled icons |
| `--color-neutral-500` | `#64748b` | Form control borders (`input`/`select`/`textarea`/`checkbox`) — see §9.1 |
| `--color-neutral-600` | `#475569` | Secondary text, captions |
| `--color-neutral-800` | `#1e293b` | Primary text |
| `--color-neutral-900` | `#0f172a` | High-emphasis text, headings |

**`--color-neutral-500` and non-text contrast (D12).** shadcn-vue's default `--input`
token (`#e2e8f0`, i.e. `--color-neutral-200`) on the `#f8fafc`/white surfaces it sits on
measures ≈1.18:1, failing §9.1's binding **≥3:1 for UI components and graphical objects**.
`--color-neutral-500` fixes this at **≈4.55:1** on `--color-neutral-50` (≈4.76:1 on pure
white) while staying visually light — a deliberate step above the floor, not a bare pass.
Two alternatives were measured and rejected: `#94a3b8` (`--color-neutral-400`) at 2.6:1
still fails; `#475569` (`--color-neutral-600`) passes at 7.5:1 but reads as a heavy,
disproportionate outline for a border. `--input` in both apps' `@theme`/`:root` blocks
resolves to this token (`backoffice/app/assets/css/main.css`,
`frontend/app/assets/css/main.css`, identical per §17). axe-core has **no** non-text-contrast
rule, so this class of defect is a manual check, not an automated gate — verify with a real
contrast calculation, never by eye.

#### Semantic

| Token | Value | Usage |
|-------|-------|-------|
| `--color-success` | `#22c55e` | Success states, confirmations (non-text: icons/fills only, see §9.1) |
| `--color-success-light` | `#dcfce7` | Success backgrounds |
| `--color-success-dark` | `#166534` | Text/icon-safe success (7.1:1 on white, §9.1) — use for BARS success chips |
| `--color-warning` | `#f59e0b` | Warning states, time alerts (non-text: icons/fills only, see §9.1) |
| `--color-warning-light` | `#fef3c7` | Warning backgrounds |
| `--color-warning-dark` | `#92400e` | Text/icon-safe warning (7.1:1 on white, §9.1) — use for BARS warning chips |
| `--color-error` | `#ef4444` | Error states, validation failures |
| `--color-error-light` | `#fee2e2` | Error backgrounds |
| `--color-info` | `#3b82f6` | Informational states |
| `--color-info-light` | `#dbeafe` | Info backgrounds |

#### Interview-specific

| Token | Value | Usage |
|-------|-------|-------|
| `--color-recording` | `#dc2626` | Recording indicator (live red dot) |
| `--color-avatar-bg` | `#0f172a` | Avatar panel background (dark, immersive) |

---

### 3.2 Typography

**Primary font**: Open Sans (Quint institutional font — per brand guidelines; sourced via `@fontsource/open-sans` — self-hosted, GDPR-safe; Google Fonts CDN is NOT permitted due to cross-origin data transfer obligations).
**Monospace font**: JetBrains Mono (code blocks, technical displays only).

```css
/* @theme block — paste into assets/css/main.css */
--font-sans: "Open Sans", ui-sans-serif, system-ui, -apple-system, sans-serif;
--font-mono: "JetBrains Mono", ui-monospace, "Cascadia Code", monospace;
```

#### Type Scale

| Token | rem | px (at 16px base) | Usage |
|-------|-----|-------------------|-------|
| `--text-xs` | `0.75rem` | 12 px | Labels, captions, badges |
| `--text-sm` | `0.875rem` | 14 px | Helper text, secondary metadata |
| `--text-base` | `1rem` | 16 px | Body text (default) |
| `--text-lg` | `1.125rem` | 18 px | Slightly emphasized body |
| `--text-xl` | `1.25rem` | 20 px | Subheadings |
| `--text-2xl` | `1.5rem` | 24 px | Section headings |
| `--text-3xl` | `1.875rem` | 30 px | Page titles |
| `--text-4xl` | `2.25rem` | 36 px | Hero / display text |

**Line height**: `1.5` for body; `1.25` for headings.
**Font weight**: `400` (regular), `500` (medium), `600` (semibold), `700` (bold).

---

### 3.3 Spacing System

Tailwind v4 uses the default spacing scale (multiples of 4 px). The custom spacing
tokens below supplement Tailwind's built-in scale for BEAI-specific layout needs.

| Token | Value | Usage |
|-------|-------|-------|
| `--spacing-section` | `4rem` (64 px) | Vertical section padding |
| `--spacing-panel` | `1.5rem` (24 px) | Card / panel internal padding |
| `--spacing-avatar-panel` | `2rem` (32 px) | Avatar panel internal padding |
| `--spacing-nav` | `4rem` (64 px) | Navigation bar height |
| `--spacing-sidebar` | `16rem` (256 px) | Backoffice sidebar width |

---

### 3.4 Border Radius

| Token | Value | Usage |
|-------|-------|-------|
| `--radius-sm` | `0.25rem` | Small badges, tags |
| `--radius-md` | `0.5rem` | Cards, modals, inputs |
| `--radius-lg` | `0.75rem` | Panels, dialogs |
| `--radius-xl` | `1rem` | Avatar panel, large card surfaces |
| `--radius-full` | `9999px` | Pills, avatars, recording indicator |

---

### 3.5 Shadows

| Token | Value | Usage |
|-------|-------|-------|
| `--shadow-sm` | `0 1px 2px 0 rgb(0 0 0 / 0.05)` | Subtle card lift |
| `--shadow-md` | `0 4px 6px -1px rgb(0 0 0 / 0.1)` | Cards, dropdowns |
| `--shadow-lg` | `0 10px 15px -3px rgb(0 0 0 / 0.1)` | Modals, popovers |
| `--shadow-avatar` | `0 25px 50px -12px rgb(0 0 0 / 0.5)` | Avatar panel elevation |

---

### 3.6 Z-Index Scale

| Layer | Value | Usage |
|-------|-------|-------|
| `--z-base` | `0` | Default document flow |
| `--z-dropdown` | `100` | Dropdowns, autocomplete |
| `--z-sticky` | `200` | Sticky headers, sticky sidebar |
| `--z-modal-backdrop` | `300` | Modal backdrop overlay |
| `--z-modal` | `400` | Modal / dialog content |
| `--z-toast` | `500` | Toast notifications |
| `--z-tooltip` | `600` | Tooltips |
| `--z-recording-indicator` | `700` | Live recording indicator (always on top) |

---

## 4. Tailwind v4 Configuration

### `assets/css/main.css` (both Nuxt apps)

```css
@import '@fontsource/open-sans';
@import "tailwindcss";
@plugin "@tailwindcss/forms";
@plugin "@tailwindcss/typography";

@theme {
  /* === Colors === */
  /* Normative Quint brand values — see §3.1 token table (authoritative) */
  --color-primary: #771aaf;
  --color-primary-light: #c222d3;
  --color-primary-dark: #4f1aaf;
  --color-accent: #e45526;
  --color-accent-light: #f19823;
  --color-accent-dark: #b8431e;

  /* Supporting secondary */
  --color-lavender: #8373d2;

  /* Page background gradient */
  --color-bg-gradient: linear-gradient(135deg, #faf7fd 0%, #f6f1fc 45%, #fdf4ef 100%);

  --color-neutral-50: #f8fafc;
  --color-neutral-100: #f1f5f9;
  --color-neutral-200: #e2e8f0;
  --color-neutral-400: #94a3b8;
  --color-neutral-600: #475569;
  --color-neutral-800: #1e293b;
  --color-neutral-900: #0f172a;

  --color-success: #22c55e;
  --color-success-light: #dcfce7;
  --color-warning: #f59e0b;
  --color-warning-light: #fef3c7;
  --color-error: #ef4444;
  --color-error-light: #fee2e2;
  --color-info: #3b82f6;
  --color-info-light: #dbeafe;

  --color-recording: #dc2626;
  --color-avatar-bg: #0f172a;

  /* === Typography === */
  /* Open Sans loaded via @fontsource/open-sans (self-hosted, GDPR-safe) */
  --font-sans: "Open Sans", ui-sans-serif, system-ui, -apple-system, sans-serif;
  --font-mono: "JetBrains Mono", ui-monospace, monospace;

  /* === Spacing === */
  --spacing-section: 4rem;
  --spacing-panel: 1.5rem;
  --spacing-avatar-panel: 2rem;
  --spacing-nav: 4rem;
  --spacing-sidebar: 16rem;

  /* === Border radius === */
  --radius-sm: 0.25rem;
  --radius-md: 0.5rem;
  --radius-lg: 0.75rem;
  --radius-xl: 1rem;
  --radius-full: 9999px;

  /* === Shadows === */
  --shadow-sm: 0 1px 2px 0 rgb(0 0 0 / 0.05);
  --shadow-md: 0 4px 6px -1px rgb(0 0 0 / 0.1);
  --shadow-lg: 0 10px 15px -3px rgb(0 0 0 / 0.1);
  --shadow-avatar: 0 25px 50px -12px rgb(0 0 0 / 0.5);
}
```

### `nuxt.config.ts` (both apps)

```ts
import tailwindcss from '@tailwindcss/vite'

export default defineNuxtConfig({
  vite: {
    plugins: [tailwindcss()],
  },
  css: ['~/assets/css/main.css'],
  app: {
    head: {
      htmlAttrs: { lang: 'it' },
    },
  },
})
```

---

## 5. Component Architecture (Atomic Design)

```
components/
  atoms/          # Single-purpose, stateless
    BaseButton.vue
    BaseInput.vue
    BaseLabel.vue
    BaseBadge.vue
    BaseIcon.vue
    BaseSpinner.vue
    BaseAvatar.vue        (avatar image/fallback)
    RecordingIndicator.vue
  molecules/      # Composed from atoms, one concern
    FormField.vue         (label + input + error)
    ToastNotification.vue
    ModalDialog.vue
    ConfirmDialog.vue
    ConsentBanner.vue     (GDPR consent — frontend only)
    TimerDisplay.vue      (interview countdown)
  organisms/      # Feature-level, may have local state
    NavBar.vue
    SidebarNav.vue        (backoffice only)
    AvatarPanel.vue       (frontend — interview view)
    QuestionCard.vue      (frontend — current question display)
    EvaluationReport.vue  (backoffice — BARS report viewer)
    CandidateTable.vue    (backoffice — candidate list)
  layouts/        # Nuxt layouts (app.vue + named layouts)
  pages/          # Nuxt pages (route-driven)
```

**Rules:**
- Atoms accept only props, emit only events, contain no business logic.
- Molecules contain UI composition logic only (show/hide, local state for UX).
- Organisms may call composables and emit domain-level events.
- No component may import directly from another repo's code.
- Every component must have a matching Vitest unit test.
- **Every clickable element MUST show `cursor: pointer`** — always, in both apps,
  with no exceptions. Tailwind v4's Preflight no longer sets it on `<button>`, so
  each app declares it globally in `app/assets/css/main.css` (`@layer base`) for
  `button`, `[role="button"]`, `a[href]`, `label[for]`, `summary`, `select` and
  `[tabindex]:not([tabindex="-1"])`. Disabled and `aria-disabled` states use
  `cursor: not-allowed` so the distinction stays visible. This applies to vendored
  shadcn-vue source as well — vendored components are not exempt. The cursor is an
  affordance signal, not decoration: without it interactive elements read as static
  text, which is also an accessibility regression for pointer users.

---

## 6. Responsive Strategy

The product is **desktop-only**. The responsive strategy is:

- **< 768 px (mobile)**: Show the SA-11 unsupported-experience gate. No functional UI rendered.
- **768 px – 1 023 px (tablet)**: Show the SA-11 gate (tablet is also unsupported). No functional UI.
- **≥ 1 024 px (desktop)**: Full application UI.

In practice:
```css
/* In the root layout — check viewport and show gate */
/* Implemented via Nuxt/Vue conditional rendering, not CSS-only */
```

The gate check is implemented in the root layout via `useWindowSize` composable
(or equivalent) and the `mobile` Playwright project validates it (SA-11 requirement).

**Desktop breakpoints used for layout adaptation:**

| Breakpoint | Width | Usage |
|------------|-------|-------|
| `lg` | 1 024 px | Minimum desktop; single-column panels |
| `xl` | 1 280 px | Standard desktop; side-by-side layouts unlock |
| `2xl` | 1 536 px | Wide desktop; max-width containers |

No `sm` or `md` breakpoints are used in production UI (those widths = unsupported).

---

## 7. Frontend (Candidate Interview App) — UX Flows

### 7.0 Standalone routes (`NoticeShell`)

The four non-interview routes — root landing, SA-11 gate, interview done,
interview error — all render through one component,
`app/components/molecules/NoticeShell.vue`. They exist for four different
reasons but share one job: tell a candidate in one glance what happened and
what to do next.

Layout is a two-column grid: a solid `--color-primary` brand band (wordmark +
tagline) beside a content column holding a tone chip, an `<h1>` and one
paragraph. Below `lg` it collapses to a single column, which is the SA-11 gate's
only rendering — that page is the one BEAI surface a phone visitor ever sees.

- `tone` (`info` / `success` / `warning` / `danger`) may change the **icon chip
  and nothing else**. The moment a tone starts altering copy or structure the
  four pages stop being one system.
- The SA-11 gate is `warning`, not `danger`: nothing failed and the candidate
  did nothing wrong. An error tone there reads as "your assessment broke".
- No action affordance unless a route passes one in. The root landing must stay
  free of forms, buttons and contact links — see `tests/unit/root-page.spec.ts`
  for why each of those is prohibited.

### 7.1 Entry (SSO / Magic-Link)

The candidate arrives via a signed magic-link JWT. The entry point:
1. Validates the JWT (expiry, signature, candidateRef, projectId, lang).
2. Sets the locale from the JWT `lang` field.
3. Shows the **GDPR consent screen** before any camera/mic access is requested.

**Consent screen requirements:**
- Privacy notice (data controller, data categories, retention, right to withdraw).
- Two actions: "Accept and continue" / "Decline and exit".
- Decline exits cleanly with a non-error message ("Thank you. You may close this window.").
- Consent acceptance is recorded server-side (audit log event).

### 7.2 Pre-Interview Check

After consent. The device check is the last screen before the assessment and the highest
abandonment risk in the product: BEAI holds no candidate contact data, so a candidate stuck
here is unreachable. Every state must be self-explanatory and recoverable on this screen.

**Layout** — single column, `max-w-xl` card, top to bottom:
1. **Camera preview** — fills the full width of the card's content column at the camera's
   **native aspect ratio**, read from the live video track (`getSettings()`, corrected by
   `loadedmetadata`). Never a hardcoded ratio, never cropped: `object-fit: contain`, ratio
   clamped to `[3/4, 21/9]` so a portrait camera cannot produce an overlong box. Background
   `--color-avatar-bg`; a `Skeleton` holds a 16:9 box until the first frame.
2. **Camera picker** and **microphone picker** — `Field` + `FieldLabel` + `Select`, populated
   from `enumerateDevices()` and kept current on `devicechange`. 44px trigger
   (`--spacing-control`), `border-input`. Disabled while a switch is in flight and
   permanently after the candidate continues. Blank platform labels fall back to
   "Camera 1" / "Microphone 1".
3. **Live microphone level meter** — `Progress`, `role="progressbar"`, **not** in a live
   region. A threshold marker shows the pass point. The screen-reader equivalent is the
   static "say a few words" instruction plus a single `role="status"` announcement when the
   level first crosses the threshold.
4. **Status rows** — camera and microphone, pass/fail. Indicator dots are `aria-hidden`;
   the adjacent text carries the semantics.
5. **Instructional copy per step**, and on any failure an `Alert` with browser-neutral
   permission-recovery guidance ("select the camera icon in your browser's address bar…")
   plus a **Retry** control. No failure state on this screen may be terminal.
6. **Continue** — enabled only when camera and microphone both pass. The mic gate is
   deliberately hard: a spoken assessment with a dead microphone is unusable.

Browser support (Chrome/Edge/Opera/Safari; Firefox and mobile gated by SA-11) is checked
before this screen renders. Every string is i18n-keyed in `it` and `en` — zero literals.
Device preference persistence: see the change design D4.

### 7.3 Interview View

The interview view is immersive and minimal:

```
┌─────────────────────────────────────────────────────────┐
│ [Brand logo]                        [Timer: 2:45]  [🔴] │  ← Navigation (--spacing-nav)
├─────────────────────────────────────────────────────────┤
│                                                         │
│        ┌─────────────────────────────────┐             │
│        │                                 │             │
│        │         AVATAR VIDEO            │             │
│        │         (HeyGen/Tavus)          │             │
│        │                                 │             │
│        └─────────────────────────────────┘             │
│                                                         │
│  ┌──────────────────────────────────────────────────┐  │
│  │  Question:                                        │  │
│  │  "Tell me about a time you led a cross-          │  │
│  │   functional team through ambiguity..."           │  │
│  └──────────────────────────────────────────────────┘  │
│                                                         │
│  [● Recording...  Your answer is being captured]        │
│                                                         │
│  [  Submit answer  ]    [Skip (1 remaining)]            │
│                                                         │
└─────────────────────────────────────────────────────────┘
```

- Background: `--color-avatar-bg` (dark, immersive).
- Avatar panel: centered, `--shadow-avatar`.
- Question card: `--color-neutral-100` background, `--radius-lg`.
- Recording indicator: pulsing red dot (`--color-recording`), always visible.
- Timer: amber warning when < 30 s (`--color-warning`), red when < 10 s (`--color-error`).
- All text i18n-keyed, zero hardcoded strings.

### 7.4 End Screen

After the last answer is submitted:
- Thank you message (i18n-keyed).
- Brief explanation: "Your evaluation is being processed. You will receive results via email."
- Close / redirect to the `exit_redirect_url` from the project configuration.

---

## 8. Backoffice (Admin Panel) — UX Flows

### 8.1 Layout

```
┌──────────────┬────────────────────────────────────────────┐
│              │  Top nav (global search, user menu)         │
│   Sidebar    ├────────────────────────────────────────────┤
│  (256 px)    │                                            │
│              │   Main content area                        │
│  Projects    │   (fluid, max-width 1 200 px, centered)    │
│  Candidates  │                                            │
│  Reports     │                                            │
│  Settings    │                                            │
│              │                                            │
└──────────────┴────────────────────────────────────────────┘
```

Sidebar: `--spacing-sidebar`, `--color-primary` background, white text.
Top nav height: `--spacing-nav`.
Content padding: `--spacing-section` horizontal, `--spacing-panel` vertical.

### 8.2 Key Views

| View | Description |
|------|-------------|
| Dashboard | KPI summary cards + recent candidate activity feed |
| Projects | Table of evaluation projects; create / configure / archive |
| Project detail | Candidate list + status breakdown + webhook log |
| Candidate detail | Timeline (lifecycle state), evaluation report (BARS), transcript |
| Evaluation report | BARS competency grid: each competency with indicator scores (1–5), mean score, reliability, excerpts |
| Settings | Organization profile, API keys, webhook config, user management (RBAC) |
| Data management | GDPR data deletion requests; export |

> **Scope note (`backoffice-missing-pages`).** This table describes the eventual admin
> panel surface, not what any single change ships. `/projects`, `/reports`, and
> `/settings` (Organization profile, API keys, Webhook defaults, Users & roles) are built
> by this change. **Project detail, the webhook log, and Data management remain unbuilt**
> — no route, no component — and stay out of scope until a future change picks them up.

### 8.2.1 Settings — section rail (not a tab strip)

`/settings` presents its four sections (Organization profile, API keys, Webhook
defaults, Users & roles) as a **vertical section rail**, 16 rem wide and sticky,
with the panel to its right. Each rail item carries an icon, the section label,
and a one-line description; the same label and description repeat as the panel
heading, so the nav and the content can never disagree.

A horizontal tab strip is **not** used here, and must not be reintroduced:

- The sections are distinct destinations with different shapes (form, table +
  dialog, form, table), not peer views of one dataset — which is what a
  segmented tab strip signals.
- The labels run 11–28 characters in Italian, so a horizontal strip reflowed
  unpredictably between 1 280 px and 1 920 px.
- A rail scales to further sections (C12/C13) without reflowing.

Implementation stays on the reka-ui `Tabs` primitive with
`orientation="vertical"`, preserving `role="tab"` / `role="tabpanel"`, roving
arrow-key focus, and lazy panel mounting (only the visible panel is in the DOM).
Selected state: `bg-primary/10` with a `--color-primary` label and icon. Side
stripes (`border-left` accents) are **not** an allowed selected-state affordance.

### 8.2.2 Selected state on toggles

`ToggleGroup` / `Toggle` selected state is `--color-primary` fill with
`--primary-foreground` text (8.2:1, §9.1). The shadcn default `bg-muted` fill is
`--color-neutral-100` against a `--color-neutral-50` page — roughly 1.05:1, which
made a selected toggle indistinguishable from an unselected one. Unselected
toggles sit at `--muted-foreground`, so the state difference is carried by both
fill and text colour.

### 8.2.3 reka-ui state variants (CSS contract)

reka-ui exposes state as `data-state="active|checked|open|closed"` and axis as
`data-orientation="vertical|horizontal"`, while vendored shadcn-vue components
style those states with Tailwind's **bare** `data-active:` / `data-checked:` /
`data-open:` / `data-vertical:` variants, which compile to attribute-*presence*
selectors (`[data-active]`). Both Nuxt apps' `main.css` MUST therefore redefine
those variant names via `@custom-variant` to target the `data-state` /
`data-orientation` values. Without them every such rule is dead CSS.

### 8.2.4 Contextual help (`HelpSheet`)

Every backoffice route carries a **Help** button in the top nav that opens a
right-hand sheet scoped to that route: what the page is for, the steps in the
order they must happen, and a short glossary of the domain words that page uses.

Constraints that make it work, and that a future change must not quietly drop:

- **One topic per route**, keyed on the first path segment (so `/projects/42`
  and `/projects` share a topic). A help button that opens generic help on a
  specific page is worse than no help button.
- **Unknown routes fall back to the overview topic.** New routes are added more
  often than the topic map is updated; an empty panel is a bug the operator sees.
- **Steps are an `<ol>`, the glossary is a `<dl>`.** They are an order and a set
  of definitions respectively, and assistive tech announces them as such.
- Content lives entirely in `i18n/locales/{en,it}.json` under `help.*`.

The candidate app has the equivalent at its only decision point: `InterviewGuide`
sits on the consent screen, before consent, because that is the last moment a
candidate can read at their own pace. Five short lines, no more.

### 8.2.5 Interview session review

Each interview session has a review page of its own, reached from the
participant detail. It shows the session's timing and duration, the proctoring
timeline with its weighted risk score and band, the timed snapshot strip, and
the avatar cost estimate.

Not a panel on the participant detail: a participant has one session per
competency, and folding N proctoring timelines into a page that already carries
a lifecycle timeline, a transcript and a BARS report makes all four harder to
read.

Three rules this surface must keep:

- **The score never appears without its events.** A band an operator cannot
  check against the evidence that produced it is a verdict on a candidate, not
  an input to a judgement.
- **Cost is always labelled an estimate**, and shows a dash rather than zero
  when a session cannot be priced. No provider exposes a per-session billed
  amount; zero would claim the session was free.
- **Backoffice only, forever.** The integrity taxonomy is the list of behaviours
  being counted and the thresholds at which they count, so it must never be
  reachable with a candidate token. Enforced by
  `tests/Arch/C11/CandidateCannotReadProctoringArchTest.php`.

Snapshots reach the browser as short-lived signed URLs. `s3_key` never leaves
the server: a raw key implies either a public bucket of identifiable webcam
frames or a disclosed storage layout.

### 8.2.6 Avatar template portability

Avatar template configuration exports and imports as a versioned JSON document
(`beai.avatar-template/1`), **admin only in both directions**. The controls do
not render for other roles at all — a control that appears and then fails with
403 teaches the operator that the product is broken rather than that they lack
the right.

Imports arrive **inactive** and never overwrite: a colliding name creates under
a derived name. A file must not silently change which avatar an organization's
live interviews are running on.

### 8.3 BARS Report View

The evaluation report is the most complex view:

```
┌────────────────────────────────────────────────────────────┐
│  Candidate: Jane Doe — Role: MLL — Assessment: Standard    │
│  Status: Completed — Score: 3.8 / 5.0                      │
├────────────────────────────────────────────────────────────┤
│  Competency (?)  Indicator (?)  Reliability (?)  BARS (?)   │  ← glossary row
├────────────────────────────────────────────────────────────┤
│  Competency          │ Score │ Reliability │ Indicators     │
│  ───────────────────────────────────────────────────────   │
│  COL (Collaboration) │ 3.67  │ 100%        │ [5] [3] [3]   │
│  COM (Communication) │ 5.00  │ 100%        │ [5] [5] [5]   │
│  STG (Strategy)      │ 2.67  │ 83%         │ [4] [3] [1]   │
│  INN (Innovation)    │ 3.00  │ 67%         │ [3] [–] [3]   │
│  ...                 │  ...  │  ...        │ ...            │
├────────────────────────────────────────────────────────────┤
│  Evidence                                    [Expand all]   │
│  COL (Collaboration)                                        │
│    ▸ [5]  Aligns the team around a shared goal             │
│    ▾ [3]  Surfaces disagreement early                      │
│         Rationale: partial evidence, one episode only.      │
│         "When I led the restructuring of the team, I..."   │
│    ▸ [3]  Shares credit for collective outcomes            │
└────────────────────────────────────────────────────────────┘
```

**The evidence section is a disclosure, not a second listing.** An earlier
version of this view rendered the same evaluation twice: indicator text existed
only under "Excerpts", score and reliability only in the grid, and nothing
connected a chip to the excerpt that justified it. An operator looking at a chip
reading `2` had no path to the sentence the candidate actually said.

- Each accordion trigger carries **the same indicator chip the grid draws**, plus
  the indicator text, **in the grid's chip order** — so chip *N* and item *N* are
  the same indicator, and that correspondence is stated in copy, not left to be
  inferred.
- Expanding reveals the rationale and the verbatim excerpts. Collapsed by
  default: the grid is the summary, this is the detail. An "Expand all" control
  serves reading and printing the whole report.
- The competency mean and reliability appear **only in the grid**, never repeated
  in a group heading — a second occurrence of the same figure makes it ambiguous
  which one is authoritative.
- Terms whose meaning is not self-evident (competency, indicator, reliability,
  BARS) carry a glossary trigger above the table. The trigger MUST be a real
  focusable control with its definition also available to assistive tech without
  opening it — hover-only content leaves keyboard, touch and screen-reader users
  with the term and never its meaning.

- **Indicator scores are one integer from `{1, 2, 3, 4, 5}` ∪ `{-1}` — no decimals.** The
  catalog authors only three anchors (`anchor_5`, `anchor_3`, `anchor_1`); `4` and `2` are
  **residual levels** selected only when the evidence matches neither bounding anchor — see
  `openspec/specs/scoring-model/spec.md` ("Relational Rubric for Residual Score Levels") for
  the binding rubric and anchor-primacy tie-break; this document does not restate it.
  Indicator chips render **seven** states:

  | Score | State | Border | Display |
  |---|---|---|---|
  | `5` | `success` | solid | `5` |
  | `4` | `above-mid` (residual) | dashed | `4` |
  | `3` | `warning` | solid | `3` |
  | `2` | `below-mid` (residual) | dashed | `2` |
  | `1` | `error` | solid | `1` |
  | `-1` / `null` | `unassessable` | solid | `–` |
  | any other value | `invalid` | solid | the raw value |

  An out-of-domain value (e.g. `0`, `6`, a decimal) **MUST render as the loud `invalid`
  chip showing the raw value — it MUST NOT be laundered into the neutral `unassessable`
  chip**, which would silently hide a data-integrity defect from the operator.
- **`-1` means UNASSESSABLE** (no assessable evidence in the transcript). It is NOT a score.
  Render it as a neutral/muted chip showing `–` (en dash) with an accessible label such as
  "not assessable", never as the number `-1` and never on the error/warning/success scale.
  Unassessable indicators are **excluded from the competency mean** — see the `INN` row above,
  whose mean is 3.00 from two assessed indicators, not 1.67 from three.
- Competency mean: bold, a real decimal in `[1, 5]` (the mean of the **assessed** indicators
  only). Colored by threshold: `< 2.5 = error`, `2.5–3.5 = warning`, `> 3.5 = success`.
- A competency whose indicators are ALL unassessable has no mean. Render `–` with the same
  neutral treatment, never `0`.
- **Reliability: render the value the API returns, verbatim** (a percent string, e.g. `100%`).
  Do NOT map it to `High` / `Medium` / `Low` word bands — **no band thresholds exist**.
  Product decision #1 is **RATIFIED**: `reliability` = assessed / total indicators
  (`-1` excluded from the numerator), validity threshold `T = 0.5`, and **no bands**.
  The verbatim-percentage rule above is therefore settled, not provisional. Inventing
  bands would bake an unapproved business rule into the UI, where it would read as
  authoritative.
- Excerpts: monospace font (`--font-mono`), verbatim from transcript (validated by substring match).

---

## 9. Accessibility Guidelines (WCAG 2.1 AA)

### 9.1 Color Contrast

All text against its background MUST achieve:
- Normal text (< 18 pt / < 14 pt bold): **≥ 4.5:1**
- Large text (≥ 18 pt or ≥ 14 pt bold): **≥ 3:1**
- UI components and graphical objects: **≥ 3:1**

**Pre-verified contrast ratios for primary palette:**

| Text color | Background | Ratio | Pass |
|------------|------------|-------|------|
| `--color-neutral-800` (`#1e293b`) | `--color-neutral-50` (`#f8fafc`) | 16.4:1 | ✓ |
| `--color-neutral-900` (`#0f172a`) | white | 19.2:1 | ✓ |
| white | `--color-primary` (`#771aaf`) | 8.2:1 | ✓ AA (normal text) |
| white | `--color-accent` (`#e45526`) | 3.7:1 | ✗ FAILS 4.5:1 AA for normal text; passes 3:1 large-text/UI |
| white | `--color-accent-dark` (`#b8431e`) | 5.4:1 | ✓ AA (valid text-sized accent alternative) |
| white | `--color-primary-light` (`#c222d3`) | 4.7:1 | ≈ AA marginal (verify per use-case before body text) |
| white | `--color-error` (`#ef4444`) | 3.8:1 | ✗ (use `#b91c1c` for text on white) |
| `--color-success-dark` (`#166534`) | white | 7.1:1 | ✓ AA (verified for BARS `ScoreChip`/`CompetencyMean` text+icon, C11 PR B3) |
| `--color-warning-dark` (`#92400e`) | white | 7.1:1 | ✓ AA (verified for BARS `ScoreChip`/`CompetencyMean` text+icon, C11 PR B3) |
| `--destructive` (`#b91c1c`) | `--color-error-light` (`#fee2e2`) | ≈5.30:1 | ✓ AA (invalid `ScoreChip`, C11-follow BARS 1–5 widening) |

> ⚠️ Do NOT use `--color-accent` (`#e45526`) for small text on white — it fails the 4.5:1 AA threshold for normal text (3.7:1). Use `--color-accent-dark` (`#b8431e`, 5.4:1) for text-sized accent elements.

> **Select highlighted-option contrast (form-clarity-and-console-warnings, D-select).** `ui/select/SelectItem.vue`'s `focus:` (highlighted) state pairs white text with `--color-accent-dark`, never plain `--color-accent` — the request to make the highlight text white is legal ONLY on the darker token, because white on `--color-accent` is the 3.7:1 failure two rows up. Backoffice `tests/unit/theme.spec.ts` asserts the 5.4:1 ratio numerically (a small WCAG relative-luminance helper), not by eye, plus a source-level assertion that `SelectItem.vue`'s class list never regresses to `focus:bg-accent focus:text-accent-foreground`.

> ⚠️ Do NOT use `--color-error` (#ef4444) as text on white. Use `#b91c1c` for error text.

> ⚠️ Do NOT use `--color-success` (`#22c55e`) or `--color-warning` (`#f59e0b`) as text/icon color on white or on their own `-light` background — both measure well under 3:1 (a real @axe-core WCAG failure caught this exact pattern for `--color-success` during C11 PR B2's status badges, see `sdd/admin-dashboards/apply-progress`). Use `--color-success-dark`/`--color-warning-dark` for any text-sized or icon-sized success/warning element (BARS `ScoreChip`, `CompetencyMean`).

### 9.2 Focus Management

- Every interactive element MUST have a visible focus indicator (Tailwind's `ring` utilities).
- Focus order MUST follow DOM reading order (no `tabindex` gymnastics).
- Modals and dialogs MUST trap focus while open and restore it on close.
- After interview question transitions, focus MUST move to the new question element.

### 9.3 ARIA Patterns

- Use native HTML elements first (`<button>`, `<input>`, `<select>`); add ARIA only when semantic HTML is insufficient.
- Every `<img>` MUST have `alt` (decorative images use `alt=""`).
- Every icon-only button MUST have `aria-label` sourced from i18n.
- Dynamic content updates (interview status, recording state, timer) MUST use `aria-live="polite"` (or `"assertive"` for critical alerts like "recording stopped").
- Use `role="status"` for non-critical live regions.

### 9.4 Keyboard Navigation

| Action | Key |
|--------|-----|
| Submit answer | `Enter` (on focused submit button) |
| Navigate options | `Tab` / `Shift+Tab` |
| Dismiss modal | `Escape` |
| Activate button | `Space` or `Enter` |

No keyboard shortcut may conflict with browser or OS reserved shortcuts.

---

## 10. Motion & Animation

- **Default**: no animation (prefers-reduced-motion compliant).
- **When animations are enabled** (`@media (prefers-reduced-motion: no-preference)`):
  - Page transitions: fade (200 ms ease-in-out).
  - Recording indicator: pulse (1 s infinite ease-in-out).
  - Toast entry: slide-in from bottom (300 ms ease-out).
  - Modal entry: scale from 95% + fade (200 ms ease-out).
- All animations MUST respect `prefers-reduced-motion: reduce` → instant/no animation.
- No animation may autoplay for more than 5 seconds unless user-initiated and stoppable.

---

## 11. i18n Design Considerations

- **Date/time**: use `Intl.DateTimeFormat` with the active locale — never format dates manually.
- **Numbers**: use `Intl.NumberFormat` — scores, percentages, and counts all formatted locale-aware.
- **RTL**: not required in v1 (supported locales are it/en/es/fr/de/pt, all LTR).
- **Pluralization**: use i18n plural rules (e.g. `$t('candidates', { count })` with plural forms defined per locale).
- **Dynamic keys**: prefer named parameters over positional (`$t('greeting', { name: 'Jane' })` not `$t('greeting', ['Jane'])`).
- **Locale detection order**: user profile preference → JWT `lang` field (candidate) → browser `Accept-Language` → fallback `it`.

---

## 12. GDPR UI Considerations

| Element | Requirement |
|---------|-------------|
| Consent screen | Shown before camera/mic access is requested; explicit binary choice |
| Privacy notice | Inline (not behind a link); covers data categories, controller, retention, rights |
| Recording indicator | Visible throughout interview (live red dot + `aria-live` status) |
| Data deletion | Backoffice "Request deletion" button on candidate record; triggers a traceable server-side event |
| Cookie notice | Only if analytics cookies are set (none by default in C1); implement via a future consent manager |
| Data portability | Backoffice can export candidate evaluation as JSON/PDF (C11/C12 concern) |

---

## 13. noindex Implementation Reference

### `frontend/app.vue` (or root layout)

```vue
<script setup lang="ts">
const config = useRuntimeConfig()
const isNoIndex = config.public.appEnv !== 'production'

useHead({
  meta: isNoIndex
    ? [{ name: 'robots', content: 'noindex, nofollow' }]
    : [],
})
</script>
```

### `backoffice/app.vue` (always noindex)

```vue
<script setup lang="ts">
useHead({
  meta: [{ name: 'robots', content: 'noindex, nofollow' }],
})
</script>
```

### `nuxt.config.ts` (shared pattern, add runtimeConfig)

```ts
export default defineNuxtConfig({
  runtimeConfig: {
    public: {
      appEnv: process.env.NUXT_PUBLIC_APP_ENV ?? 'local',
    },
  },
})
```

---

## 14. Lighthouse Targets

| Metric | Target | App |
|--------|--------|-----|
| Performance | ≥ 90 | `frontend` + `backoffice` |
| Accessibility | **100** | Both apps |
| Best Practices | **100** | Both apps |
| SEO | ≥ 90 | `frontend` landing page only |
| LCP | < 2.5 s | Both apps |
| CLS | < 0.1 | Both apps |
| INP | < 200 ms | Both apps |

**Strategy to hit targets:**
- Preload Open Sans via `@fontsource/open-sans` (self-hosted import in `main.css`; no `<link rel="preload">` needed — @fontsource handles font-face declarations).
- Use `@nuxtjs/image` for optimized images (C7+).
- Tailwind v4 JIT ensures minimal CSS bundle (zero dead utility classes).
- SSR (frontend) serves pre-rendered HTML — LCP resolved at document load.
- SPA (backoffice) uses code-splitting and lazy routes for chunk optimization.
- `nuxt.config.ts`: enable `experimental.payloadExtraction` for SSR hydration optimization.

---

## 15. Icon System

Use **Heroicons v2** (MIT licensed; Vue component wrappers via `@heroicons/vue`).

```bash
bun add @heroicons/vue
```

Usage:
```vue
<template>
  <CheckCircleIcon class="h-5 w-5 text-success" aria-hidden="true" />
</template>
```

- Decorative icons: `aria-hidden="true"`.
- Semantic icons (icon-only buttons): wrap with a `<span class="sr-only">` i18n label or use `aria-label` on the parent button.

---

## 16. Form Design

> **D11 reconciliation.** This section previously named `@tailwindcss/forms` as the
> primary form-styling mechanism and "VeeValidate or Zod" for client-side validation.
> `@tailwindcss/forms` genuinely is installed and loaded — that half was never stale —
> but its actual role is a Preflight-level reset, not visual styling, and neither
> VeeValidate nor Zod is a dependency of either app. The semantics below (`aria-invalid`,
> `aria-describedby`, i18n-keyed messages, errors after blur) are preserved verbatim from
> the prior version; only the named stack and the state classes change.

1. **Structure.** `FieldGroup` > `Field` > `FieldLabel` + control + `FieldError` /
   `FieldDescription` (shadcn-vue). Never a raw `div` with `space-y-*`. `FieldSet` +
   `FieldLegend` for grouped checkboxes/radios (e.g. a competency picker).
2. **Base styling.** `@tailwindcss/forms` stays installed as a Preflight-level reset
   only — it normalizes native control appearance so shadcn-vue's own classes have a
   consistent base to override, not the other way around. Visual state (default, focus,
   invalid, disabled) lives entirely in the vendored shadcn-vue component classes; pages
   must not re-style controls with ad hoc `class` overrides.
3. **Validation.** No VeeValidate, no Zod. Per-field validate functions run **on blur**
   and again on submit — all fields validated on submit, never short-circuited by `&&`,
   so a form submitted empty flags every invalid field at once, not one at a time.
   Server-side: Laravel `422` responses map to the same field-level messages through the
   typed API client. Error messages are always i18n-keyed (`$t('validation.required')`
   etc.), never hardcoded.
4. **Accessibility (unchanged, binding).** `data-invalid` on `Field`, `aria-invalid` on
   the control, `aria-describedby` pointing at the message element's `id`, id convention
   `{form}-{field}-error`.
5. **Two-level feedback contract (ratified).** Field-level validation messages render
   directly under their own field (`FieldError`, associated via `aria-describedby`).
   Independently, the form-level submit outcome renders as a `role="alert"
   aria-live="polite"` banner **adjacent to the submit CTA** — not detached at the top of
   the card — because that is where the eye already is after pressing the button, and
   because an outcome that cannot be attributed to a single field (e.g. "invalid
   credentials", which must not disclose which field was wrong) must not masquerade as a
   field error. Reference implementation: `backoffice/app/pages/login.vue:11-26` (field
   level) and `:47-63` (form-level banner), tested in
   `backoffice/tests/unit/login.spec.ts`.
6. **i18n.** Every message is a key in `i18n/locales/{en,it}.json`. No literal string
   ever, in either the field-level or the form-level message.
7. **Disabled / immutable fields** carry a `FieldDescription` explaining *why* the field
   is disabled (e.g. "locked after project activation"). A silently disabled field with no
   explanation reads as a bug, not a rule.
8. **Control sizing (D12).** Default control height is `--spacing-control` (44px —
   `Input`, `Select` trigger, `Button`; `min-height` for `Textarea`); dense contexts
   (table filter rows, inline table actions) use `--spacing-control-sm` (36px). Border
   color resolves to `--color-neutral-500` for ≥3:1 non-text contrast — see §3.1, §9.1.

   **Native `<select>` is excluded from the dense size and always uses the 44px
   default.** A native select cannot shrink gracefully: its option line box plus
   the platform's own vertical padding does not fit, and unlike a styled div it
   clips rather than overflowing visibly. Every native `<select>` and every raw
   `<input>` that cannot go through the vendored components uses the single
   `formControlClass` in `app/components/ui/form-control` — four hand-written
   variants had already drifted across three files, one of them at 32px and
   visibly cutting its own text.
9. **Testing.** Assertions target `data-testid`, never CSS selectors, per §5.
10. **Select highlighted-option contrast (form-clarity-and-console-warnings).** The
    highlighted option in a `Select` MUST render white text on `--color-accent-dark`
    (5.4:1), never on plain `--color-accent` (3.7:1, fails 4.5:1 AA) — see §9.1's
    dedicated note for the numbers and the token pairing. This binds every current
    and future `focus:`/`hover:`/`data-highlighted:` variant that styles a select
    highlight, not only `SelectItem.vue`'s existing `focus:` state.
11. **The `novalidate` + `Field`/`FieldError` contract binds every backoffice form,
    present and future** (generalised from the four forms that originally wrote
    §16's rules 3-5), not only forms `login.vue`/`ProjectForm.vue` happened to
    introduce it on. Enforced mechanically, not by review discipline, by
    `backoffice/tests/unit/arch/form-contract.spec.ts` — a repo-wide Vitest guard
    over `app/**/*.vue` (novalidate present, `FieldError` imported, no `catch`
    that silently drops a server 422 without reaching the shared
    `applyServerFieldErrors` mapper), mirroring the `api/tests/Arch/**` pattern.

---

## 17. Updates to This Document

When updating `DESIGN.md`:
1. Update the relevant section.
2. Update the `@theme {}` block in `assets/css/main.css` in both Nuxt repos to match.
3. Update the Vitest snapshot tests for any affected components.
4. Reference the design decision ID (e.g. `D26`) if the change is architecture-level.
5. Commit all three changes (DESIGN.md + both Nuxt CSS files) in a single commit.
