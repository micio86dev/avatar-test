/**
 * D30 — backoffice noindex policy:
 * The admin panel ALWAYS injects noindex, nofollow — no environment conditional.
 */
import { describe, it, expect, vi } from 'vitest'
import { mount } from '@vue/test-utils'
import AppRoot from '../../app/app.vue'

describe('app.vue — noindex policy (D30)', () => {
  it('always calls useHead with noindex regardless of env', () => {
    const useHeadMock = vi.fn()
    vi.stubGlobal('useHead', useHeadMock)

    mount(AppRoot)

    expect(useHeadMock).toHaveBeenCalledWith(
      expect.objectContaining({
        meta: expect.arrayContaining([
          expect.objectContaining({
            name: 'robots',
            content: 'noindex, nofollow',
          }),
        ]),
      })
    )
  })

  it('useHead is called exactly once (no conditional branch)', () => {
    const useHeadMock = vi.fn()
    vi.stubGlobal('useHead', useHeadMock)

    mount(AppRoot)

    // Must be called exactly once — no env-conditional logic
    expect(useHeadMock).toHaveBeenCalledTimes(1)
  })
})
