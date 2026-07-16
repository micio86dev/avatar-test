import { type Page } from '@playwright/test'
import AxeBuilder from '@axe-core/playwright'

/**
 * Runs @axe-core accessibility checks on the current page at WCAG 2.1 AA level.
 * Call this after each navigation in E2E specs to enforce the D29 mandate.
 *
 * @throws {Error} if any WCAG 2.1 AA violations are found
 */
export async function checkA11y(page: Page): Promise<void> {
  const results = await new AxeBuilder({ page })
    .withTags(['wcag2a', 'wcag2aa', 'wcag21aa'])
    .analyze()

  if (results.violations.length > 0) {
    const report = results.violations
      .map(
        (v) =>
          `[${v.impact}] ${v.id}: ${v.description}\n  Nodes: ${v.nodes.map((n) => n.html).join(', ')}`
      )
      .join('\n\n')
    throw new Error(`WCAG 2.1 AA violations found:\n\n${report}`)
  }
}
