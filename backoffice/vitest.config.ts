import { defineConfig } from 'vitest/config'
import vue from '@vitejs/plugin-vue'
import { resolve } from 'node:path'

export default defineConfig({
  plugins: [vue()],
  test: {
    globals: true,
    environment: 'happy-dom',
    setupFiles: ['./tests/unit/setup.ts'],
    // Only run unit tests; Playwright E2E runs separately via playwright test
    include: ['tests/unit/**/*.spec.ts', 'tests/unit/**/*.test.ts'],
    exclude: ['tests/e2e/**', 'node_modules/**', '.nuxt/**'],
    coverage: {
      provider: 'v8',
      include: ['app/**', 'components/**', 'composables/**', 'pages/**', 'server/**'],
      exclude: ['.nuxt/**', 'types/api.ts', '*.config.*'],
      thresholds: {
        lines: 85,
      },
    },
  },
  resolve: {
    alias: {
      '~': resolve(__dirname, '.'),
      '@': resolve(__dirname, '.'),
    },
  },
})
