import { describe, it, expect, vi } from 'vitest'
import { mount } from '@vue/test-utils'
import UnsupportedPage from '../../app/pages/unsupported.vue'

describe('UnsupportedPage (SA-11 gate)', () => {
  it('renders the unsupported-gate element', () => {
    const wrapper = mount(UnsupportedPage, {
      global: {
        mocks: {
          $t: (key: string) => key,
        },
      },
    })
    expect(wrapper.find('[data-testid="unsupported-gate"]').exists()).toBe(true)
  })

  it('does NOT render health-status element', () => {
    const wrapper = mount(UnsupportedPage, {
      global: {
        mocks: {
          $t: (key: string) => key,
        },
      },
    })
    expect(wrapper.find('[data-testid="health-status"]').exists()).toBe(false)
  })

  it('renders i18n title key', () => {
    const tMock = vi.fn((key: string) => {
      const map: Record<string, string> = {
        'unsupported.title': 'Browser non supportato',
        'unsupported.message': 'Messaggio non supportato',
      }
      return map[key] ?? key
    })
    const wrapper = mount(UnsupportedPage, {
      global: {
        mocks: { $t: tMock },
      },
    })
    expect(wrapper.find('h1').text()).toBe('Browser non supportato')
  })
})
