import { defineConfig, devices } from '@playwright/test'

/**
 * Playwright E2E configuration — 3 required browser projects per D14.
 *
 * Projects:
 *   chromium  — Desktop Chromium, full suite (all E2E specs)
 *   webkit    — Desktop Safari/WebKit, full suite (all E2E specs)
 *   mobile    — Mobile device viewport, SA-11 gate spec ONLY (asserts unsupported-experience)
 *
 * Firefox is intentionally excluded per NFR (product is desktop Chrome/Edge/Safari only).
 * Bun installs; Node runs the Playwright runner in CI.
 * SPA mode: backoffice serves static files; webServer uses `nuxt generate` + static serve.
 */
export default defineConfig({
  testDir: './tests/e2e',
  fullyParallel: true,
  forbidOnly: !!process.env['CI'],
  retries: process.env['CI'] ? 2 : 0,
  workers: process.env['CI'] ? 1 : undefined,
  reporter: [['html', { open: 'never' }], ['list']],
  use: {
    trace: 'on-first-retry',
    screenshot: 'only-on-failure',
  },

  projects: [
    {
      name: 'chromium',
      use: {
        ...devices['Desktop Chrome'],
      },
    },
    {
      name: 'webkit',
      use: {
        ...devices['Desktop Safari'],
      },
    },
    {
      // SA-11 — mobile viewport: asserts the unsupported-experience gate ONLY
      // This project only runs tests tagged with @sa11 or in the unsupported-gate spec
      name: 'mobile',
      use: {
        ...devices['Pixel 7'],
      },
      testMatch: ['**/unsupported-gate.spec.ts'],
    },
  ],

  // Base URL for the Nuxt dev server (started separately in CI)
  webServer: process.env['CI']
    ? {
        command: 'bunx serve .output/public -p 3000',
        url: 'http://localhost:3000',
        reuseExistingServer: false,
        timeout: 30_000,
      }
    : {
        command: 'bun run dev',
        url: 'http://localhost:3000',
        reuseExistingServer: true,
        timeout: 60_000,
      },
})
