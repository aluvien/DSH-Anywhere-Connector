import { describe, expect, it } from 'vitest'
import { Readable } from 'node:stream'
import type { IncomingMessage, ServerResponse } from 'node:http'
import { EventEnvelopeSchema } from '@dsh-anywhere/protocol'
import { PairingRateLimiter, apply, inject, normalizeSessionEvent, normalizeSessionEvents } from './index.js'
import type { Context } from '@deepseek-ai/cordis'

describe('DeepSeek Harness event normalization', () => {
  it('injects the workspace registry used by the Harness archive source of truth', () => {
    expect(inject).toContain('workspaceRegistry')
  })

  it('converts user and assistant messages into the native wire shape', () => {
    const tools = new Map<string, string>()
    expect(normalizeSessionEvent('s1', {
      type: 'user/message',
      data: { id: 'u1', role: 'user', source: { kind: 'user' }, content: [{ type: 'text', text: 'hello' }] },
    }, tools)).toEqual({
      type: 'user.message.accepted', sessionId: 's1',
      payload: { id: 'u1', role: 'user', markdown: 'hello' },
    })
    expect(normalizeSessionEvent('s1', {
      type: 'assistant/message',
      data: { message: { id: 'a1', content: [{ type: 'text', text: 'world' }] } },
    }, tools)).toEqual({
      type: 'assistant.message.completed', sessionId: 's1',
      payload: { id: 'a1', role: 'assistant', markdown: 'world' },
    })
  })

  it('correlates a tool result with its call', () => {
    const tools = new Map<string, string>()
    normalizeSessionEvent('s1', {
      type: 'tool/call', data: { callId: 'c1', name: 'shell', arguments: '{"cmd":"pwd"}' },
    }, tools)
    expect(normalizeSessionEvent('s1', {
      type: 'tool/result',
      data: { message: { content: [{ type: 'tool-result', toolCallId: 'c1', content: [{ type: 'text', text: '/tmp' }] }] } },
    }, tools)).toEqual({
      type: 'tool.completed', sessionId: 's1',
      payload: { id: 'c1', name: 'shell', status: 'succeeded', detail: '/tmp' },
    })
  })

  it('produces payloads accepted by the strict protocol schema', () => {
    const normalized = normalizeSessionEvent('s1', {
      type: 'turn/start', data: { turn: 1 },
    }, new Map())!
    expect(() => EventEnvelopeSchema.parse({
      version: 1,
      messageId: 'm1',
      machineId: 'machine',
      deviceId: 'device',
      sessionId: normalized.sessionId,
      sequence: 1,
      timestamp: Date.now(),
      type: normalized.type,
      payload: normalized.payload,
    })).not.toThrow()
  })

  it('keeps the Harness permission preset rather than replacing it with its approval policy', () => {
    expect(normalizeSessionEvents('s1', {
      type: 'permission/preset', data: { preset: 'workspace-write' },
    }, new Map())).toEqual([{
      type: 'permission.updated', sessionId: 's1',
      payload: { sessionId: 's1', mode: 'workspace-write', approvalPolicy: 'ask' },
    }])
    expect(normalizeSessionEvents('s1', {
      type: 'approval/policy', data: { policy: 'ask' },
    }, new Map())).toEqual([])
  })

  it('derives a generation rate from a timed assistant stream', () => {
    const normalized = normalizeSessionEvents('s1', {
      type: 'assistant/message',
      data: {
        message: { id: 'a1', content: [{ type: 'text', text: 'world' }] },
        usage: { inputTokens: 10, outputTokens: 20, totalTokens: 30 },
        stream: [{ type: 'text-chunks', time0: 1_000, index: 0, dt: [500], texts: ['wo', 'rld'] }],
      },
    }, new Map())
    const usage = normalized.find((item) => item.type === 'usage.updated')
    expect(usage?.payload).toMatchObject({
      sessionId: 's1',
      usage: { outputTokens: 20, tokensPerSecond: 40 },
    })
  })
})

describe('DSH Anywhere pairing security', () => {
  it('rejects a short connector token when applying the plugin', () => {
    const context = {
      logger: { info: () => undefined },
    } as unknown as Context
    expect(() => apply(context, { connectorToken: 'too-short' })).toThrow(
      'connectorToken must be at least 32 characters when provided',
    )
  })

  it('returns 429 semantics after the configured number of failed attempts and clears on success', () => {
    const limiter = new PairingRateLimiter(2, 60_000)
    expect(limiter.tryConsume('198.51.100.7')).toBe(true)
    expect(limiter.tryConsume('198.51.100.7')).toBe(true)
    expect(limiter.tryConsume('198.51.100.7')).toBe(false)
    limiter.clear('198.51.100.7')
    expect(limiter.tryConsume('198.51.100.7')).toBe(true)
  })

  it('responds with HTTP 429 when /pair exceeds the configured failure limit', async () => {
    let handler: ((req: IncomingMessage, res: ServerResponse) => void | Promise<void>) | undefined
    const context = {
      logger: { info: () => undefined },
      webServer: {
        register: (route: { handler: (req: IncomingMessage, res: ServerResponse) => void | Promise<void> }) => {
          handler = route.handler
          return () => undefined
        },
        registerUpgrade: () => () => undefined,
      },
      on: () => undefined,
      effect: () => undefined,
    } as unknown as Context
    apply(context, {
      connectorToken: 'connector-token-that-is-at-least-32-characters',
      pairingRateLimitMaxAttempts: 2,
    })
    expect(handler).toBeDefined()

    const request = async (): Promise<number> => {
      const req = Readable.from([JSON.stringify({ code: '000000', deviceName: 'iPhone' })]) as unknown as IncomingMessage
      Object.assign(req, {
        method: 'POST',
        url: '/dsh-anywhere/v1/pair',
        headers: {},
        socket: { remoteAddress: '198.51.100.7' },
      })
      let status = 0
      const res = {
        writeHead: (value: number) => { status = value },
        end: () => undefined,
      } as unknown as ServerResponse
      await handler!(req, res)
      return status
    }

    expect(await request()).toBe(401)
    expect(await request()).toBe(401)
    expect(await request()).toBe(429)
  })
})
