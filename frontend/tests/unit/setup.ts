import { vi } from 'vitest'
import { ref, computed, reactive, watch, watchEffect, nextTick, toRef, toRefs } from 'vue'

// Expose Vue reactivity APIs as globals — Nuxt auto-imports them but Vitest doesn't
vi.stubGlobal('ref', ref)
vi.stubGlobal('computed', computed)
vi.stubGlobal('reactive', reactive)
vi.stubGlobal('watch', watch)
vi.stubGlobal('watchEffect', watchEffect)
vi.stubGlobal('nextTick', nextTick)
vi.stubGlobal('toRef', toRef)
vi.stubGlobal('toRefs', toRefs)

// Stub Nuxt compiler macros that are unavailable in Vitest context
vi.stubGlobal('definePageMeta', vi.fn())
vi.stubGlobal('useHead', vi.fn())
vi.stubGlobal(
  'useRuntimeConfig',
  vi.fn(() => ({ public: { apiBase: '', appEnv: 'local' } }))
)
vi.stubGlobal(
  'useNuxtApp',
  vi.fn(() => ({}))
)

// Stub Nitro server utilities (used in server/routes/)
// defineEventHandler wraps the handler fn — in tests we call it directly
vi.stubGlobal(
  'defineEventHandler',
  // Pass-through: returns the handler function itself so tests can invoke it
  (handler: (...args: unknown[]) => unknown) => handler
)
