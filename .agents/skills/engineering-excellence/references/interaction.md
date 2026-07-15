# Frontend UX & Interaction

Interactive elements must clearly communicate that they are interactive, and behave
predictably across mouse, keyboard, and touch input.

## Cursor

Always use `cursor: pointer` on every interactive element, including:

- buttons
- links styled as buttons
- clickable cards
- menu items
- tabs
- icon buttons
- dropdown triggers
- switches
- checkboxes and radio buttons with custom UI
- any element with a click handler

Never use `cursor: pointer` on non-interactive elements — it falsely signals affordance.

## States

Interactive elements should expose appropriate visual states:

- **Hover** — visible feedback that the element responds to pointer input.
- **Focus** — a visible focus indicator for keyboard users. Never remove focus outlines
  unless they are replaced with an accessible alternative.
- **Disabled** — a clear disabled appearance, and the element must not be operable
  (no click handler firing, `cursor` reflecting the disabled state).

## Semantic HTML

Prefer semantic HTML over generic elements wired up with handlers.

- Use `<button>`, `<a>`, `<input>`, and other native controls instead of clickable
  `<div>` or `<span>`.
- Native elements give you keyboard operability, focus management, and assistive-tech
  semantics for free. Avoid re-implementing them unless absolutely necessary.

See references/accessibility.md for the broader accessibility contract.

## Touch Targets

Interactive controls should provide sufficiently large touch targets (minimum
44×44px when appropriate).
