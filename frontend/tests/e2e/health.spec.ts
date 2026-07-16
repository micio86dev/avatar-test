import { test, expect } from '@playwright/test'
import { checkA11y } from './fixtures/a11y'

/**
 * E2E health check — runs under both `chromium` and `webkit` projects.
 *
 * Asserts:
 * - The /health page is reachable and returns HTTP 200
 * - The page renders the text "ok"
 * - No WCAG 2.1 AA violations (D29)
 *
 * This spec is intentionally excluded from the `mobile` project
 * (mobile only runs unsupported-gate.spec.ts — SA-11 gate).
 */
test.describe('Health page', () => {
  test('renders "ok" on the /health page', async ({ page }) => {
    await page.goto('/health')
    await expect(page.getByTestId('health-status')).toBeVisible()
    await expect(page.getByTestId('health-status')).toHaveText('ok')
  })

  test('GET /api/health returns {"status":"ok"}', async ({ request }) => {
    const response = await request.get('/api/health')
    expect(response.status()).toBe(200)
    const body = await response.json()
    expect(body).toEqual({ status: 'ok' })
  })

  test('passes WCAG 2.1 AA accessibility check', async ({ page }) => {
    await page.goto('/health')
    await checkA11y(page)
  })
})
