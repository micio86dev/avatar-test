// @ts-check
import { createConfigForNuxt } from '@nuxt/eslint-config/flat'

export default createConfigForNuxt({
  features: {
    tooling: true,
    stylistic: false, // Prettier handles formatting
  },
  dirs: {
    src: ['./app'],
  },
}).append({
  rules: {
    // Enforce no unused vars (D27 strict mode)
    'no-unused-vars': 'error',
    '@typescript-eslint/no-unused-vars': 'error',
  },
})
