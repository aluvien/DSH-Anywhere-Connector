import { describe, expect, it } from 'vitest'
import { Readable } from 'node:stream'
import { mkdtemp, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import type { IncomingMessage, ServerResponse } from 'node:http'
import { EventEnvelopeSchema } from '@dsh-anywhere/protocol'
import { PairingRateLimiter, apply, inject, normalizeSessionEvent, normalizeSessionEvents, normalizeSessionSummary, readPairingMaterial } from './index.js'
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

  it('keeps reasoning out of the answer and emits it as its own event', () => {
    const events = normalizeSessionEvents('s1', {
      type: 'assistant/message',
      data: {
        message: {
          id: 'a1',
          content: [
            { type: 'reasoning', text: 'The user wants the short version.' },
            { type: 'text', text: 'Here it is.' },
          ],
        },
      },
    }, new Map())

    const completed = events.find((event) => event.type === 'assistant.message.completed')
    const reasoning = events.find((event) => event.type === 'assistant.reasoning')

    // The reply the phone renders must not contain chain-of-thought.
    expect((completed?.payload as { markdown: string }).markdown).toBe('Here it is.')
    expect(reasoning?.payload).toEqual({
      messageId: 'a1',
      text: 'The user wants the short version.',
    })
  })

  it('omits the reasoning event entirely when there is none', () => {
    const events = normalizeSessionEvents('s1', {
      type: 'assistant/message',
      data: { message: { id: 'a1', content: [{ type: 'text', text: 'Just the answer.' }] } },
    }, new Map())
    expect(events.some((event) => event.type === 'assistant.reasoning')).toBe(false)
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

describe('session list rows', () => {
  it('reads the display title from the title projection', () => {
    // SessionSummary has no `title` field, so reading item.title made every row
    // fall back to the folder name and a whole workspace looked like a stack of
    // identically named duplicates.
    const summary = normalizeSessionSummary({
      sessionId: 'session-1',
      cwd: '/Users/me/DSH-ANYWHERE',
      updatedAt: 1,
      projections: { asOfSeq: 3, values: { title: '\u54c8\u54c8' } },
    })
    expect(summary.title).toBe('\u54c8\u54c8')
  })

  it('falls back to the folder name only when no title exists', () => {
    expect(normalizeSessionSummary({
      sessionId: 'session-2',
      cwd: '/Users/me/DSH-ANYWHERE',
      updatedAt: 1,
      projections: { asOfSeq: 1, values: { title: null } },
    }).title).toBe('DSH-ANYWHERE')
  })

  it('does not invent a workspace from the working directory', () => {
    // Registering one phantom workspace per directory is what made the phone
    // list disagree with the Harness sidebar, which only lists real workspaces.
    const summary = normalizeSessionSummary({
      sessionId: 'session-4',
      cwd: '/Users/me/DSH-ANYWHERE',
      updatedAt: 1,
    })
    expect(summary.workspaceId).toBeUndefined()
    expect(summary.workspaceName).toBeUndefined()
    // The path is still reported so a row can show where the session lives.
    expect(summary.cwd).toBe('/Users/me/DSH-ANYWHERE')
  })

  it('ignores a blank projection and keeps the flat field as a fallback', () => {
    expect(normalizeSessionSummary({
      sessionId: 'session-3',
      cwd: '/Users/me/DSH-ANYWHERE',
      updatedAt: 1,
      title: 'Flat title',
      projections: { asOfSeq: 1, values: { title: '   ' } },
    }).title).toBe('Flat title')
  })
})

describe('pairing page material', () => {
  async function fixture(files: Record<string, unknown>): Promise<string> {
    const directory = await mkdtemp(join(tmpdir(), 'dsh-pairing-'))
    const configPath = join(directory, 'connector.json')
    for (const [name, value] of Object.entries(files)) {
      await writeFile(join(directory, name), JSON.stringify(value), 'utf8')
    }
    return configPath
  }

  const connector = { relayURL: 'wss://relay.example.com', machineId: 'machine_1', pairingSecret: 'long-lived-secret-value' }

  it('prefers a live one-time code over the long-lived secret', async () => {
    const configPath = await fixture({
      'connector.json': connector,
      'pairing-code.json': { machineId: 'machine_1', code: 'ABCD2345', expiresAt: Date.now() + 60_000 },
    })

    const material = await readPairingMaterial(configPath)

    // The code is narrower: it expires and is consumed on use.
    expect(material?.link).toContain('code=ABCD2345')
    expect(material?.link).not.toContain('secret=')
    expect(material?.expiresAt).toBeGreaterThan(Date.now())
  })

  it('falls back to the secret when no code is published', async () => {
    const material = await readPairingMaterial(await fixture({ 'connector.json': connector }))
    expect(material?.link).toContain('secret=long-lived-secret-value')
    expect(material?.expiresAt).toBeUndefined()
  })

  it('ignores an expired code rather than showing a dead one', async () => {
    // A stale file must not walk the user into a failure they cannot diagnose.
    const configPath = await fixture({
      'connector.json': connector,
      'pairing-code.json': { machineId: 'machine_1', code: 'ABCD2345', expiresAt: Date.now() - 1 },
    })

    const material = await readPairingMaterial(configPath)

    expect(material?.link).toContain('secret=long-lived-secret-value')
  })
});
