/**
 * Unit tests for the root app layout (app/app.vue).
 *
 * Tests:
 * - The component mounts without errors
 * - noindex meta is injected in local/staging env (D30)
 * - noindex is NOT injected in production env (D30)
 */
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { mount } from '@vue/test-utils'
import App from '../../app/app.vue'

// We need to override useRuntimeConfig per test
const mockUseRuntimeConfig = vi.fn()
vi.stubGlobal('useRuntimeConfig', mockUseRuntimeConfig)

const mockUseHead = vi.fn()
vi.stubGlobal('useHead', mockUseHead)

describe('App root layout', () => {
  beforeEach(() => {
    mockUseHead.mockClear()
  })

  it('mounts successfully', () => {
    mockUseRuntimeConfig.mockReturnValue({ public: { apiBase: '', appEnv: 'local' } })
    const wrapper = mount(App, {
      global: {
        stubs: {
          NuxtRouteAnnouncer: true,
          NuxtPage: true,
        },
      },
    })
    expect(wrapper.exists()).toBe(true)
  })

  it('injects noindex meta when appEnv is "local" (D30)', () => {
    mockUseRuntimeConfig.mockReturnValue({ public: { apiBase: '', appEnv: 'local' } })
    mount(App, {
      global: {
        stubs: {
          NuxtRouteAnnouncer: true,
          NuxtPage: true,
        },
      },
    })
    expect(mockUseHead).toHaveBeenCalledWith(
      expect.objectContaining({
        meta: expect.arrayContaining([
          expect.objectContaining({ name: 'robots', content: 'noindex, nofollow' }),
        ]),
      })
    )
  })

  it('injects noindex meta when appEnv is "staging" (D30)', () => {
    mockUseRuntimeConfig.mockReturnValue({ public: { apiBase: '', appEnv: 'staging' } })
    mount(App, {
      global: {
        stubs: {
          NuxtRouteAnnouncer: true,
          NuxtPage: true,
        },
      },
    })
    expect(mockUseHead).toHaveBeenCalledWith(
      expect.objectContaining({
        meta: expect.arrayContaining([
          expect.objectContaining({ name: 'robots', content: 'noindex, nofollow' }),
        ]),
      })
    )
  })

  it('does NOT inject noindex meta when appEnv is "production" (D30)', () => {
    mockUseRuntimeConfig.mockReturnValue({ public: { apiBase: '', appEnv: 'production' } })
    mount(App, {
      global: {
        stubs: {
          NuxtRouteAnnouncer: true,
          NuxtPage: true,
        },
      },
    })
    expect(mockUseHead).not.toHaveBeenCalled()
  })
})
