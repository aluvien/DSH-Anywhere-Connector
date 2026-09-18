import { Readable } from 'node:stream'
import type { IncomingMessage, OutgoingHttpHeaders, ServerResponse } from 'node:http'
import { describe, expect, it } from 'vitest'
import { HttpError } from './http.js'
import { IdempotentHttpResponses } from './index.js'

function request(): IncomingMessage {
  return Readable.from([]) as unknown as IncomingMessage
}

function response(): { result: { status?: number; headers?: OutgoingHttpHeaders; body?: string | Buffer }; value: ServerResponse } {
  const result: { status?: number; headers?: OutgoingHttpHeaders; body?: string | Buffer } = {}
  const value = {
    writeHead(status: number, headers?: OutgoingHttpHeaders) {
      result.status = status
      result.headers = headers
      return value
    },
    end(body?: string | Buffer) {
      result.body = body
      return value
    },
  } as unknown as ServerResponse
  return { result, value }
}

describe('bridge idempotency cache', () => {
  it('never evicts an in-flight mutation when completed results fill the cache', async () => {
    const cache = new IdempotentHttpResponses()
    let executions = 0
    let release!: () => void
    const blocker = new Promise<void>((resolve) => { release = resolve })
    const firstResponse = response()
    const first = cache.respond('same', 'a'.repeat(64), request(), firstResponse.value, async (capture) => {
      executions += 1
      await blocker
      capture.writeHead(201)
      capture.end('first')
    })
    await new Promise((resolve) => setTimeout(resolve, 0))

    for (let index = 0; index < 2_000; index += 1) {
      const next = response()
      await cache.respond(`other-${index}`, 'b'.repeat(64), request(), next.value, async (capture) => {
        capture.writeHead(200)
        capture.end('other')
      })
    }

    const duplicateResponse = response()
    const duplicate = cache.respond('same', 'a'.repeat(64), request(), duplicateResponse.value, async (capture) => {
      executions += 1
      capture.writeHead(500)
      capture.end('duplicate')
    })
    release()
    await Promise.all([first, duplicate])
    expect(executions).toBe(1)
    expect(duplicateResponse.result.body).toBe('first')
  })

  it('rejects reuse of an idempotency key with a different request fingerprint', async () => {
    const cache = new IdempotentHttpResponses()
    const firstResponse = response()
    await cache.respond('same', 'a'.repeat(64), request(), firstResponse.value, async (capture) => {
      capture.writeHead(201)
      capture.end('first')
    })
    await expect(cache.respond('same', 'b'.repeat(64), request(), response().value, async () => undefined))
      .rejects.toMatchObject<HttpError>({ status: 409 })
  })

  it('allows a same-id retry after an explicit no-side-effect failure', async () => {
    const cache = new IdempotentHttpResponses()
    let executions = 0
    const first = response()
    await cache.respond('recoverable', 'c'.repeat(64), request(), first.value, async (capture) => {
      executions += 1
      capture.writeHead(503, { 'x-dsh-idempotency-outcome': 'retryable' })
      capture.end('try again')
    })
    const second = response()
    await cache.respond('recoverable', 'c'.repeat(64), request(), second.value, async (capture) => {
      executions += 1
      capture.writeHead(202)
      capture.end('accepted')
    })
    expect(executions).toBe(2)
    expect(second.result.body).toBe('accepted')
  })

  it('replays an unknown failure instead of repeating an ambiguous side effect', async () => {
    const cache = new IdempotentHttpResponses()
    let executions = 0
    const first = response()
    await cache.respond('unknown', 'd'.repeat(64), request(), first.value, async (capture) => {
      executions += 1
      capture.writeHead(500)
      capture.end('unknown')
    })
    const second = response()
    await cache.respond('unknown', 'd'.repeat(64), request(), second.value, async (capture) => {
      executions += 1
      capture.writeHead(201)
      capture.end('duplicated')
    })
    expect(executions).toBe(1)
    expect(second.result.body).toBe('unknown')
  })
})
