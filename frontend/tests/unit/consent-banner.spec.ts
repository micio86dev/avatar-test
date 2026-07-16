/**
 * Unit tests for ConsentBanner component (GDPR scaffold — task 6.9).
 */
import { describe, it, expect, vi } from 'vitest'
import { mount } from '@vue/test-utils'
import ConsentBanner from '../../app/components/ConsentBanner.vue'

// Stub Nuxt's ref/defineEmits — available globally via setup.ts stubs
// but ref needs to be the Vue ref in the component
// The component uses Vue's ref() which is auto-imported by Nuxt

describe('ConsentBanner (GDPR scaffold)', () => {
  const tMock = (key: string) => {
    const t: Record<string, string> = {
      'consent.title': 'Informativa sulla privacy',
      'consent.description': 'Descrizione del consenso.',
      'consent.accept': 'Accetto',
      'consent.decline': 'Rifiuto',
      'consent.accept_aria': 'Accetto i termini',
      'consent.decline_aria': 'Rifiuto i termini',
    }
    return t[key] ?? key
  }

  it('renders the consent banner when mounted', () => {
    const wrapper = mount(ConsentBanner, {
      global: { mocks: { $t: tMock } },
    })
    expect(wrapper.find('[data-testid="consent-banner"]').exists()).toBe(true)
  })

  it('emits "accepted" when the accept button is clicked', async () => {
    const wrapper = mount(ConsentBanner, {
      global: { mocks: { $t: tMock } },
    })
    await wrapper.findAll('button')[0]!.trigger('click')
    expect(wrapper.emitted('accepted')).toBeTruthy()
    expect(wrapper.emitted('accepted')).toHaveLength(1)
  })

  it('hides the banner after accept', async () => {
    const wrapper = mount(ConsentBanner, {
      global: { mocks: { $t: tMock } },
    })
    await wrapper.findAll('button')[0]!.trigger('click')
    expect(wrapper.find('[data-testid="consent-banner"]').exists()).toBe(false)
  })

  it('emits "declined" when the decline button is clicked', async () => {
    const wrapper = mount(ConsentBanner, {
      global: { mocks: { $t: tMock } },
    })
    await wrapper.findAll('button')[1]!.trigger('click')
    expect(wrapper.emitted('declined')).toBeTruthy()
    expect(wrapper.emitted('declined')).toHaveLength(1)
  })

  it('hides the banner after decline', async () => {
    const wrapper = mount(ConsentBanner, {
      global: { mocks: { $t: tMock } },
    })
    await wrapper.findAll('button')[1]!.trigger('click')
    expect(wrapper.find('[data-testid="consent-banner"]').exists()).toBe(false)
  })
})
