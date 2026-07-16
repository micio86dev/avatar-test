import { test, expect } from '@playwright/test'
import { checkA11y } from './fixtures/a11y'

/**
 * SA-11 — Unsupported experience gate test.
 *
 * This spec runs under the `mobile` Playwright project (device: Pixel 7)
 * and also under desktop projects (chromium / webkit) to verify the page
 * itself is accessible.
 *
 * The mobile project asserts:
 * - The unsupported-gate page exists and is reachable at /unsupported
 * - The gate element with data-testid="unsupported-gate" is visible
 * - Full app features are NOT shown (the gate blocks them)
 *
 * Note: In C1 the mobile detection / redirect logic is scaffolded structurally.
 * The actual middleware that detects mobile and redirects → /unsupported
 * will be implemented in C7 (interview port).
 */
test.describe('SA-11 — Unsupported experience gate', () => {
  test('unsupported page renders the gate element', async ({ page }) => {
    // Navigate directly to the unsupported page
    await page.goto('/unsupported')

    // Verify the gate is shown (SA-11)
    await expect(page.getByTestId('unsupported-gate')).toBeVisible()
  })

  test('unsupported page does NOT render full interview features', async ({ page }) => {
    await page.goto('/unsupported')

    // Verify no interview-specific elements are present
    await expect(page.getByTestId('health-status')).not.toBeVisible()
  })

  test('unsupported page passes WCAG 2.1 AA accessibility check', async ({ page }) => {
    await page.goto('/unsupported')
    await checkA11y(page)
  })
})
