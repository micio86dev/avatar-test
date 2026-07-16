import { test as base, type Page } from '@playwright/test'

/**
 * Fake interview provider fixture.
 *
 * Stubs external avatar/voice service calls so E2E tests never hit real
 * HeyGen/Tavus endpoints. Use this fixture in any test that exercises the
 * candidate interview flow (C7+). In C1 it is a structural scaffold only.
 */

interface FakeInterviewProvider {
  /** Stub: returns a pre-recorded session token without calling the real API. */
  getSessionToken(): Promise<string>
  /** Stub: simulates the provider emitting a question event. */
  emitQuestion(text: string): void
}

interface InterviewFixtures {
  fakeProvider: FakeInterviewProvider
}

export const test = base.extend<InterviewFixtures>({
  // eslint-disable-next-line no-empty-pattern
  fakeProvider: async ({}, use) => {
    const provider: FakeInterviewProvider = {
      async getSessionToken() {
        return 'fake-session-token-c1-scaffold'
      },
      emitQuestion(_text: string) {
        // Stub: no-op in C1; C7 will drive real events here
      },
    }
    await use(provider)
  },
})

export { expect } from '@playwright/test'
