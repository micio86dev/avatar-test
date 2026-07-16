// https://nuxt.com/docs/api/configuration/nuxt-config
import tailwindcss from '@tailwindcss/vite'

export default defineNuxtConfig({
  compatibilityDate: '2025-07-15',
  devtools: { enabled: true },

  // SPA mode (D2 — backoffice is always client-side rendered; no SSR)
  ssr: false,

  // i18n — always multilingual (D12); it default, prefix_except_default, lazy
  modules: ['@nuxtjs/i18n'],
  i18n: {
    defaultLocale: 'it',
    strategy: 'prefix_except_default',
    lazy: true,
    langDir: 'i18n/locales/',
    locales: [
      { code: 'it', file: 'it.json' },
      { code: 'en', file: 'en.json' },
    ],
  },

  // Tailwind CSS v4 via Vite plugin (D26)
  vite: {
    plugins: [tailwindcss()],
  },

  // Global CSS
  css: ['~/assets/css/main.css'],

  // App head — htmlAttrs.lang for a11y (D29); noindex is ALWAYS injected in app.vue (D30)
  app: {
    head: {
      htmlAttrs: { lang: 'it' },
    },
  },

  // Security headers (D29 / task 7.8).
  // For the SPA (ssr: false), these are primarily applied at nginx level (see Dockerfile).
  // Nitro route rules are included here for dev server and `nuxt preview` consistency.
  nitro: {
    routeRules: {
      '/**': {
        headers: {
          'X-Frame-Options': 'DENY',
          'X-Content-Type-Options': 'nosniff',
          'Referrer-Policy': 'strict-origin-when-cross-origin',
          'Permissions-Policy': 'camera=(), microphone=(), geolocation=()',
        },
      },
    },
  },

  // Runtime config
  runtimeConfig: {
    public: {
      apiBase: '',
    },
  },
})
