# Accessibility

Accessibility is a first-class engineering requirement, not a finishing touch.
It is never traded away for aesthetics.

When applicable:

- Target **WCAG 2.2 AA**.
- Prefer semantic HTML — it carries meaning and behavior that assistive technologies rely on.
- Preserve keyboard navigation for every interactive flow.
- Maintain visible focus states (see references/interaction.md).
- Use ARIA only when necessary. Native semantics are preferred; incorrect ARIA is worse
  than no ARIA.
- Never sacrifice accessibility for aesthetics — the two are not in conflict when done well.

## W3C Compliance

Standards-compliant markup is the foundation both accessibility and interoperability
build on.

- Generated HTML and CSS should strive to be **W3C compliant** whenever reasonably possible.
- Produce valid, well-structured documents: correct nesting, unique `id`s, and required
  attributes.
- Valid, semantic markup improves accessibility, cross-browser consistency, and
  machine readability for search engines and AI agents (see references/seo.md).
