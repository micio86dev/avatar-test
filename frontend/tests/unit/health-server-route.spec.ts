/**
 * Unit test for the Nuxt server route /api/health.
 * Tests the handler function directly (not via HTTP).
 */
import { describe, it, expect } from 'vitest'
import healthHandler from '../../server/routes/api/health.get'

describe('Server route GET /api/health', () => {
  it('returns {status: "ok"}', () => {
    // Call the handler directly — defineEventHandler wraps but returns the fn
    // For Nitro server routes, the default export is the handler function
    const handler = healthHandler as unknown as () => { status: string }
    const result = handler()
    expect(result).toEqual({ status: 'ok' })
  })
})
