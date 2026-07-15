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

#### Brand

| Token | Value | Usage |
|-------|-------|-------|
| `--color-primary` | `#1e3a5f` | Primary brand — headings, primary buttons, navigation active |
| `--color-primary-light` | `#2d5282` | Hover state of primary elements |
| `--color-primary-dark` | `#132740` | Active / pressed state |
| `--color-accent` | `#0d9488` | Teal accent — CTAs, highlighted states, progress indicators |
| `--color-accent-light` | `#14b8a6` | Hover state of accent elements |
| `--color-accent-dark` | `#0f766e` | Active / pressed state of accent |

#### Neutrals

| Token | Value | Usage |
|-------|-------|-------|
| `--color-neutral-50` | `#f8fafc` | Page backgrounds |
| `--color-neutral-100` | `#f1f5f9` | Card / panel backgrounds |
| `--color-neutral-200` | `#e2e8f0` | Borders, dividers |
| `--color-neutral-400` | `#94a3b8` | Placeholder text, disabled icons |
| `--color-neutral-600` | `#475569` | Secondary text, captions |
| `--color-neutral-800` | `#1e293b` | Primary text |
| `--color-neutral-900` | `#0f172a` | High-emphasis text, headings |

#### Semantic

| Token | Value | Usage |
|-------|-------|-------|
| `--color-success` | `#22c55e` | Success states, confirmations |
| `--color-success-light` | `#dcfce7` | Success backgrounds |
| `--color-warning` | `#f59e0b` | Warning states, time alerts |
| `--color-warning-light` | `#fef3c7` | Warning backgrounds |
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

**Primary font**: Inter (variable font, sourced via `@fontsource/inter` or CDN).
**Monospace font**: JetBrains Mono (code blocks, technical displays only).

```css
/* @theme block — paste into assets/css/main.css */
--font-sans: "Inter", ui-sans-serif, system-ui, -apple-system, sans-serif;
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
@import "tailwindcss";
@plugin "@tailwindcss/forms";
@plugin "@tailwindcss/typography";

@theme {
  /* === Colors === */
  --color-primary: #1e3a5f;
  --color-primary-light: #2d5282;
  --color-primary-dark: #132740;
  --color-accent: #0d9488;
  --color-accent-light: #14b8a6;
  --color-accent-dark: #0f766e;

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
  --font-sans: "Inter", ui-sans-serif, system-ui, -apple-system, sans-serif;
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

After consent:
1. Camera permission prompt (handled by the browser).
2. Microphone permission prompt.
3. Browser support check (if not Chrome/Edge/Opera/Safari → gate).
4. Device check summary (camera OK, mic OK, browser OK).
5. Start interview button.

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

### 8.3 BARS Report View

The evaluation report is the most complex view:

```
┌────────────────────────────────────────────────────────────┐
│  Candidate: Jane Doe — Role: MLL — Assessment: Standard    │
│  Status: Completed — Score: 3.8 / 5.0                      │
├────────────────────────────────────────────────────────────┤
│  Competency          │ Score │ Reliability │ Indicators     │
│  ───────────────────────────────────────────────────────   │
│  COL (Collaboration) │ 3.67  │ High        │ [4] [3] [4]   │
│  COM (Communication) │ 4.00  │ High        │ [4] [4] [4]   │
│  STG (Strategy)      │ 2.33  │ Medium      │ [2] [3] [2]   │
│  ...                 │  ...  │  ...        │ ...            │
├────────────────────────────────────────────────────────────┤
│  Excerpts (verbatim from transcript)                        │
│  "When I led the restructuring of the team, I..."          │
└────────────────────────────────────────────────────────────┘
```

- Indicator scores: colored chips (1–2 = error, 3 = warning, 4–5 = success scale).
- Competency mean: bold, colored by threshold (< 2 = error, 2–3 = warning, > 3 = success).
- Reliability: text badge.
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
| white | `--color-primary` (`#1e3a5f`) | 9.2:1 | ✓ |
| white | `--color-accent` (`#0d9488`) | 4.6:1 | ✓ AA |
| white | `--color-error` (`#ef4444`) | 3.8:1 | ✗ (use `#b91c1c` for text on white) |

> ⚠️ Do NOT use `--color-error` (#ef4444) as text on white. Use `#b91c1c` for error text.

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
- Preload Inter font via `<link rel="preload">` in `nuxt.config.ts` `app.head`.
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

All forms use `@tailwindcss/forms` for consistent base styling.

**Input states:**
- Default: `border-neutral-200 bg-white focus:border-accent focus:ring-accent`
- Error: `border-error bg-error-light focus:border-error focus:ring-error` + `aria-invalid="true"` + `aria-describedby` pointing to error message element
- Disabled: `opacity-50 cursor-not-allowed`

**Validation:**
- Client-side: VeeValidate or Zod-based composable; errors shown immediately after blur.
- Server-side: Laravel validation errors mapped to field-level messages via the typed API client.
- Error messages: always i18n-keyed (`$t('validation.required')` etc.), never hardcoded.

---

## 17. Updates to This Document

When updating `DESIGN.md`:
1. Update the relevant section.
2. Update the `@theme {}` block in `assets/css/main.css` in both Nuxt repos to match.
3. Update the Vitest snapshot tests for any affected components.
4. Reference the design decision ID (e.g. `D26`) if the change is architecture-level.
5. Commit all three changes (DESIGN.md + both Nuxt CSS files) in a single commit.
