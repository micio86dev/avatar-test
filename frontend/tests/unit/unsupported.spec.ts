/**
 * Unit tests for the unsupported-browser gate page (SA-11).
 */
import { describe, it, expect } from 'vitest'
import { mount } from '@vue/test-utils'
import UnsupportedPage from '../../app/pages/unsupported.vue'

describe('UnsupportedPage (SA-11 gate)', () => {
  it('renders the unsupported-gate data-testid element', () => {
    const wrapper = mount(UnsupportedPage, {
      global: {
        mocks: {
          $t: (key: string) => {
            const translations: Record<string, string> = {
              'unsupported.title': 'Browser non supportato',
              'unsupported.message': 'Accedi da un computer desktop.',
            }
            return translations[key] ?? key
          },
        },
      },
    })
    expect(wrapper.find('[data-testid="unsupported-gate"]').exists()).toBe(true)
  })

  it('renders the title heading', () => {
    const wrapper = mount(UnsupportedPage, {
      global: {
        mocks: {
          $t: (key: string) => {
            const t: Record<string, string> = {
              'unsupported.title': 'Browser non supportato',
              'unsupported.message': 'Accedi da un computer desktop.',
            }
            return t[key] ?? key
          },
        },
      },
    })
    expect(wrapper.find('h1').exists()).toBe(true)
    expect(wrapper.find('h1').text()).toBe('Browser non supportato')
  })

  it('does NOT render the health-status element', () => {
    const wrapper = mount(UnsupportedPage, {
      global: {
        mocks: {
          $t: (key: string) => key,
        },
      },
    })
    expect(wrapper.find('[data-testid="health-status"]').exists()).toBe(false)
  })
})
