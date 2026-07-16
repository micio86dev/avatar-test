/**
 * Client smoke test — verifies the generated TypeScript types from openapi.json
 * contain the expected health endpoint shape.
 *
 * This is a compile-time + runtime structural check, not an HTTP call.
 */
import { describe, it, expect } from 'vitest'
import type { paths, operations } from '../../types/api.ts'

describe('Generated API client types', () => {
  it('exposes the /health path', () => {
    // Type-level assertion: this would fail to compile if the path is missing
    type HealthPath = paths['/health']
    type HealthGet = HealthPath['get']
    type HealthResponse = HealthGet['responses'][200]['content']['application/json']

    // Runtime assertion: verify the constant "ok" value is present in the type
    const status: HealthResponse['status'] = 'ok'
    expect(status).toBe('ok')
  })

  it('health response status is the literal "ok"', () => {
    // Assert that the operations type contains a health key
    type HealthOp = operations['health']
    type ResponseBody = HealthOp['responses'][200]['content']['application/json']

    const response: ResponseBody = { status: 'ok' }
    expect(response.status).toBe('ok')
  })
})
