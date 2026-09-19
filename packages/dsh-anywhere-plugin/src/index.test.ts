import { describe, expect, it } from 'vitest'
import { Readable } from 'node:stream'
import { createHash } from 'node:crypto'
import { mkdir, mkdtemp, writeFile } from 'node:fs/promises'
import { mkdtempSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { dirname, join } from 'node:path'
import type { IncomingMessage, ServerResponse } from 'node:http'
import { EventEnvelopeSchema } from '@dsh-anywhere/protocol'
import { historyRecipient, CONNECTOR_DEVICE_ID, LIVE_REASONING_TRAIL_LIMIT, PairingRateLimiter, apply, inject, isSubagentSession, liveReasoningTrail, liveStreamChunkEvent, modeCatalogFromRemote, normalizeSessionEvent, normalizeSessionEvents, normalizeSessionSummary, readPairingMaterial, workspaceCatalog } from './index.js'
import { HttpError } from './http.js'
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

  it('preserves receipt metadata for image/file message history', () => {
    expect(normalizeSessionEvent('s1', {
      type: 'user/message',
      data: {
        id: 'u2',
        source: { kind: 'user' },
        content: [
          { type: 'text', text: '这是什么？' },
          { type: 'file', receiptId: 'receipt-1', name: 'photo.jpg', mediaType: 'image/jpeg' },
        ],
      },
    }, new Map())).toEqual({
      type: 'user.message.accepted', sessionId: 's1',
      payload: {
        id: 'u2', role: 'user', markdown: '这是什么？',
        attachments: [{ id: 'receipt-1', receiptId: 'receipt-1', name: 'photo.jpg', mediaType: 'image/jpeg' }],
      },
    })
  })

  it('embeds thumbnails for Mac-side images with stable ids', async () => {
    const dir = await mkdtemp(join(tmpdir(), 'dsh-attach-'))
    const hex = 'ab'.repeat(32)
    await mkdir(join(dir, 'attachments', 'v1', 'objects', 'ab'), { recursive: true })
    const png = Buffer.from(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
      'base64')
    await writeFile(join(dir, 'attachments', 'v1', 'objects', 'ab', hex), png)
    const previousHome = process.env.DSH_HOME
    process.env.DSH_HOME = dir
    try {
      const input = {
        type: 'user/message',
        data: {
          id: 'u3', source: { kind: 'user' },
          content: [{ type: 'image', attachment: { attachmentId: `sha256:${hex}`, mediaType: 'image/png', name: 'shot.png' } }],
        },
      }
      const first = normalizeSessionEvent('s1', input, new Map())
      const second = normalizeSessionEvent('s1', input, new Map())
      // Same input twice must not mint random ids (or replays duplicate rows).
      expect(first).toEqual(second)
      expect(first).toEqual({
        type: 'user.message.accepted', sessionId: 's1',
        payload: {
          id: 'u3', role: 'user', markdown: '',
          attachments: [{
            id: `sha256:${hex}`, name: 'shot.png', mediaType: 'image/png',
            thumbnail: `data:image/png;base64,${png.toString('base64')}`,
          }],
        },
      })
      // Assistant-side images ride the same path.
      expect(normalizeSessionEvent('s1', {
        type: 'assistant/message',
        data: { message: { id: 'a9', content: [{ type: 'text', text: '' }, input.data.content[0]] } },
      }, new Map())).toEqual({
        type: 'assistant.message.completed', sessionId: 's1',
        payload: {
          id: 'a9', role: 'assistant', markdown: '',
          attachments: [{
            id: `sha256:${hex}`, name: 'shot.png', mediaType: 'image/png',
            thumbnail: `data:image/png;base64,${png.toString('base64')}`,
          }],
        },
      })
    } finally {
      if (previousHome === undefined) delete process.env.DSH_HOME
      else process.env.DSH_HOME = previousHome
    }
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

  it('uses the live stream replacement only for the matching durable turn and never replays final stream text as a delta', () => {
    const replacement = new Map([['s1\u00001\u00002', 'stream-live-1']])
    const events = normalizeSessionEvents('s1', {
      type: 'assistant/message',
      data: {
        turn: 1,
        step: 2,
        message: { id: 'assistant-final-1', content: [{ type: 'text', text: 'finished' }] },
        stream: [{ type: 'text-chunks', time0: 1, index: 0, dt: [], texts: ['fin', 'ished'] }],
      },
    }, new Map(), new Map(), new Map(), replacement)

    expect(events).toContainEqual({
      type: 'assistant.message.completed', sessionId: 's1',
      payload: { id: 'assistant-final-1', role: 'assistant', markdown: 'finished', replacesMessageId: 'stream-live-1' },
    })
    expect(events.some((event) => event.type === 'assistant.message.delta')).toBe(false)
  })

  it('keeps a bounded trailing snapshot for live reasoning activity', () => {
    expect(liveReasoningTrail('before', ' after')).toBe('before after')
    const long = 'x'.repeat(LIVE_REASONING_TRAIL_LIMIT)
    expect(liveReasoningTrail(long, 'tail')).toHaveLength(LIVE_REASONING_TRAIL_LIMIT)
    expect(liveReasoningTrail(long, 'tail').endsWith('tail')).toBe(true)
  })

  it('projects a Harness reasoning-delta onto the temporary stream message', () => {
    const attempt = { key: 's1\u00001\u00002', sessionId: 's1', messageId: 'stream-1', reasoningTrail: '' }
    expect(liveStreamChunkEvent(attempt, { type: 'reasoning-delta', index: 0, text: 'planning' })).toEqual({
      type: 'assistant.reasoning', sessionId: 's1',
      payload: { messageId: 'stream-1', text: 'planning' },
    })
    expect(liveStreamChunkEvent(attempt, { type: 'reasoning-delta', index: 0, text: ' next' })).toEqual({
      type: 'assistant.reasoning', sessionId: 's1',
      payload: { messageId: 'stream-1', text: 'planning next' },
    })
    expect(liveStreamChunkEvent(attempt, { type: 'block-start', index: 1, blockType: 'text' })).toBeUndefined()
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

  it('accumulates usage across assistant turns while keeping the event usage per turn', () => {
    const tools = new Map<string, string>()
    const usage = new Map()
    const first = normalizeSessionEvents('s1', {
      type: 'assistant/message',
      data: {
        message: { id: 'a1', content: [{ type: 'text', text: 'one' }] },
        usage: { inputTokens: 10, outputTokens: 4, totalTokens: 14, cacheReadTokens: 6 },
      },
    }, tools, usage)
    const second = normalizeSessionEvents('s1', {
      type: 'assistant/message',
      data: {
        message: { id: 'a2', content: [{ type: 'text', text: 'two' }] },
        usage: { inputTokens: 20, outputTokens: 8, totalTokens: 28, cacheReadTokens: 2 },
      },
    }, tools, usage)

    expect(first.find((event) => event.type === 'assistant.message.completed')?.payload).toMatchObject({
      usage: { inputTokens: 10, outputTokens: 4, totalTokens: 14 },
    })
    expect(second.find((event) => event.type === 'assistant.message.completed')?.payload).toMatchObject({
      usage: { inputTokens: 20, outputTokens: 8, totalTokens: 28 },
    })
    expect(second.find((event) => event.type === 'usage.updated')?.payload).toMatchObject({
      usage: { inputTokens: 30, outputTokens: 12, totalTokens: 42, cacheReadTokens: 8 },
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

  it('keeps the Chinese blank-session placeholder until the native title projection arrives', () => {
    expect(normalizeSessionSummary({
      sessionId: 'session-new', cwd: '/Users/me/Code', updatedAt: 1, blank: true,
      projections: { asOfSeq: 1, values: { title: null } },
    }).title).toBe('新会话')
    expect(normalizeSessionSummary({
      sessionId: 'session-new', cwd: '/Users/me/Code', updatedAt: 2, blank: false,
      projections: { asOfSeq: 4, values: { title: '修复首页刷新闪烁' } },
    }).title).toBe('修复首页刷新闪烁')
  })
})

describe('native remote catalogs', () => {
  it('lists even an empty native workspace without deriving one from sessions', () => {
    const workspaces = workspaceCatalog({ workspaceRegistry: {
      list: () => [{ id: 'workspace-empty', title: 'Empty project', path: '/Users/me/Empty', sessionIds: [] }],
      archivedSessionIds: [],
      archiveSession: async () => undefined,
    } })
    expect(workspaces).toEqual([{ id: 'workspace-empty', title: 'Empty project', path: '/Users/me/Empty' }])
  })

  it('uses the actual Harness preset roster and rejects broken presets', () => {
    expect(modeCatalogFromRemote({ ok: true, value: { presets: [
      { id: 'standard', name: '标准', description: 'Mac preset', isDefault: true },
      { id: 'broken', name: 'Broken', broken: 'missing provider', isDefault: false },
      { id: 'raw', isDefault: false },
    ] } })).toEqual({
      defaultMode: 'standard',
      modes: [{ id: 'standard', name: '标准', description: 'Mac preset' }, { id: 'raw', name: 'raw' }],
    })
  })
})

describe('native bridge mutations', () => {
  const connectorToken = 'test-connector-token-that-is-long-enough'

  function mount(options: {
    create?: (request: { cwd?: string; workspaceId?: string; agentPreset?: string }) => Promise<{ sessionId: string }>
    prompt?: () => Promise<{ accepted: true }>
    rename?: (request: { sessionId: string; title: string }) => Promise<unknown>
    createWorkspace?: (path: string, title?: string) => Promise<{ id: string; path: string; title: string; sessionIds: readonly string[] }>
    directoryPicker?: unknown
    invoke?: (request: unknown) => Promise<unknown>
    findAttachmentByRequestId?: (requestId: string, signal: AbortSignal) => Promise<unknown | undefined | { state: 'found' | 'not-committed' | 'unknown'; response?: unknown }>
    dataDir?: string
  } = {}) {
    // Each mounted Bridge gets an isolated metadata file.  The real plugin
    // deliberately survives restarts in this file; sharing the user's default
    // directory between unit tests would replay an earlier request id and
    // make the tests depend on execution order.
    process.env.DSH_ANYWHERE_DATA_DIR = options.dataDir
      ?? mkdtempSync(join(tmpdir(), 'dsh-anywhere-bridge-test-'))
    let handler: ((req: IncomingMessage, res: ServerResponse) => void | Promise<void>) | undefined
    const context = {
      logger: { info: () => undefined, warn: () => undefined },
      webServer: {
        register: (route: { handler: (req: IncomingMessage, res: ServerResponse) => void | Promise<void> }) => {
          handler = route.handler
          return () => undefined
        },
        registerUpgrade: () => () => undefined,
      },
      sessionController: {
        list: async () => ({ items: [] }),
        create: options.create ?? (async () => ({ sessionId: 'session-new' })),
        ...(options.findAttachmentByRequestId === undefined ? {} : {
          findAttachmentByRequestId: options.findAttachmentByRequestId,
        }),
        ...(options.rename === undefined ? {} : { rename: options.rename }),
        selectModel: async () => undefined,
        modelCatalog: async () => ({ default: { provider: 'p', model: 'm' }, routableProviders: [], groups: [], failures: [] }),
        resolveAgent: async () => ({ error: 'none' }),
        prompt: options.prompt ?? (async () => ({ accepted: true })),
        cancel: () => ({ accepted: true }),
        inspect: async () => ({ events: [] }),
      },
      workspaceRegistry: {
        list: () => [],
        ...(options.createWorkspace === undefined ? {} : { create: options.createWorkspace }),
        archivedSessionIds: [],
        archiveSession: async () => undefined,
      },
      typertGateway: {
        invoke: options.invoke ?? (async () => ({ ok: true, value: { presets: [] } })),
      },
      ...(options.directoryPicker === undefined ? {} : { directoryPicker: options.directoryPicker }),
      on: () => undefined,
      effect: () => undefined,
    } as unknown as Context
    apply(context, { connectorToken })
    return async (method: string, url: string, body?: unknown, requestId?: string,
                  authorization = `Bearer ${connectorToken}`): Promise<{ status: number; body: unknown }> => {
      const request = Readable.from([body === undefined ? '' : JSON.stringify(body)]) as unknown as IncomingMessage
      Object.assign(request, {
        method,
        url,
        headers: {
          authorization,
          ...(requestId === undefined ? {} : { 'x-dsh-request-id': requestId }),
        },
        socket: { remoteAddress: '127.0.0.1' },
      })
      let status = 0
      let response = ''
      const reply = {
        writeHead: (value: number) => { status = value },
        end: (value?: string) => { response = value ?? '' },
      } as unknown as ServerResponse
      await handler!(request, reply)
      return { status, body: response.length === 0 ? undefined : JSON.parse(response) }
    }
  }

  it('creates a durable native workspace from the selected absolute host folder', async () => {
    const createWorkspace = async (path: string, title?: string) => ({ id: 'workspace-1', path, title: title ?? 'Code', sessionIds: [] })
    const request = mount({ createWorkspace })
    await expect(request('POST', '/dsh-anywhere/v1/workspaces', { path: '/Users/me/Code', title: 'Phone project' }))
      .resolves.toEqual({ status: 201, body: { workspace: { id: 'workspace-1', path: '/Users/me/Code', title: 'Phone project' } } })
  })

  it('does not rename a blank session, but routes an explicit rename to Harness', async () => {
    const renameCalls: { sessionId: string; title: string }[] = []
    const request = mount({ rename: async (value) => { renameCalls.push(value) } })
    expect((await request('POST', '/dsh-anywhere/v1/sessions', { cwd: '/Users/me/Code' })).status).toBe(201)
    expect(renameCalls).toEqual([])
    await expect(request('POST', '/dsh-anywhere/v1/sessions/session-new/rename', { title: '重命名后标题' }))
      .resolves.toMatchObject({ status: 202 })
    expect(renameCalls).toEqual([{ sessionId: 'session-new', title: '重命名后标题' }])
  })

  it('coalesces the same authenticated mutation across Connector processes', async () => {
    let creates = 0
    const request = mount({
      create: async () => {
        creates += 1
        await new Promise((resolve) => setTimeout(resolve, 10))
        return { sessionId: 'session-once' }
      },
    })
    const [first, duplicate] = await Promise.all([
      request('POST', '/dsh-anywhere/v1/sessions', { cwd: '/Users/me/Code' }, 'same-phone-request'),
      request('POST', '/dsh-anywhere/v1/sessions', { cwd: '/Users/me/Code' }, 'same-phone-request'),
    ])
    expect(creates).toBe(1)
    expect(duplicate).toEqual(first)
  })

  it('replays the durable create identity after a Bridge restart', async () => {
    const dataDir = mkdtempSync(join(tmpdir(), 'dsh-anywhere-bridge-restart-'))
    let creates = 0
    const firstRequest = mount({
      dataDir,
      create: async () => {
        creates += 1
        return { sessionId: 'session-durable' }
      },
    })
    await expect(firstRequest(
      'POST', '/dsh-anywhere/v1/sessions', { cwd: '/Users/me/Code' }, 'durable-create',
    )).resolves.toMatchObject({ status: 201, body: { sessionId: 'session-durable' } })

    const restartedRequest = mount({ dataDir, create: async () => ({ sessionId: 'should-not-run' }) })
    await expect(restartedRequest(
      'POST', '/dsh-anywhere/v1/sessions', { cwd: '/Users/me/Code' }, 'durable-create',
    )).resolves.toMatchObject({ status: 200, body: { sessionId: 'session-durable' } })
    expect(creates).toBe(1)
  })

  it('records the native create before optional setup can fail', async () => {
    const dataDir = mkdtempSync(join(tmpdir(), 'dsh-anywhere-bridge-setup-failure-'))
    let creates = 0
    const firstRequest = mount({
      dataDir,
      create: async () => {
        creates += 1
        return { sessionId: 'session-before-setup-failure' }
      },
      invoke: async (request: unknown) => {
        if ((request as { namespace?: string }).namespace === 'commands') {
          throw new Error('permission setup failed')
        }
        return { ok: true, value: { presets: [] } }
      },
    })
    await expect(firstRequest(
      'POST', '/dsh-anywhere/v1/sessions', { cwd: '/Users/me/Code', permissionMode: 'workspace-write' }, 'setup-failure',
    )).resolves.toMatchObject({ status: 502 })

    const restartedRequest = mount({ dataDir, create: async () => ({ sessionId: 'should-not-run' }) })
    await expect(restartedRequest(
      'POST', '/dsh-anywhere/v1/sessions', { cwd: '/Users/me/Code' }, 'setup-failure',
    )).resolves.toMatchObject({ status: 200, body: { sessionId: 'session-before-setup-failure' } })
    expect(creates).toBe(1)
  })

  it('resumes incomplete post-create setup instead of replaying partial success', async () => {
    const dataDir = mkdtempSync(join(tmpdir(), 'dsh-anywhere-bridge-setup-recovery-'))
    let creates = 0
    const firstRequest = mount({
      dataDir,
      create: async () => {
        creates += 1
        return { sessionId: 'session-needs-setup' }
      },
      invoke: async (request: unknown) => {
        if ((request as { namespace?: string }).namespace === 'commands') {
          throw new Error('permission setup failed')
        }
        return { ok: true, value: { presets: [] } }
      },
    })
    await expect(firstRequest(
      'POST', '/dsh-anywhere/v1/sessions', { cwd: '/Users/me/Code', permissionMode: 'workspace-write' }, 'setup-recovery',
    )).resolves.toMatchObject({ status: 502 })

    const restartedRequest = mount({ dataDir })
    await expect(restartedRequest(
      'POST', '/dsh-anywhere/v1/sessions', { cwd: '/Users/me/Code' }, 'setup-recovery',
    )).resolves.toMatchObject({ status: 200, body: { sessionId: 'session-needs-setup' } })
    expect(creates).toBe(1)
  })

  it('fails closed when durable session metadata is corrupt', async () => {
    const dataDir = mkdtempSync(join(tmpdir(), 'dsh-anywhere-bridge-corrupt-metadata-'))
    await writeFile(join(dataDir, 'session-metadata.json'), '{not-json')
    let creates = 0
    const request = mount({
      dataDir,
      create: async () => {
        creates += 1
        return { sessionId: 'should-not-run' }
      },
    })
    await expect(request(
      'POST', '/dsh-anywhere/v1/sessions', { cwd: '/Users/me/Code' }, 'corrupt-metadata',
    )).resolves.toMatchObject({ status: 503 })
    expect(creates).toBe(0)
  })

  it('does not execute a create whose durable operation identity is still pending', async () => {
    const dataDir = mkdtempSync(join(tmpdir(), 'dsh-anywhere-bridge-pending-'))
    const key = `${CONNECTOR_DEVICE_ID}\u0000pending-create`
    await writeFile(join(dataDir, 'session-metadata.json'), JSON.stringify({
      sessionCreations: { [key]: { pending: true } },
    }))
    let creates = 0
    const request = mount({
      dataDir,
      create: async () => {
        creates += 1
        return { sessionId: 'should-not-run' }
      },
    })
    await expect(request(
      'POST', '/dsh-anywhere/v1/sessions', { cwd: '/Users/me/Code' }, 'pending-create',
    )).resolves.toMatchObject({ status: 503 })
    expect(creates).toBe(0)
  })

  it('rejects oversized session request ids before native creation', async () => {
    let creates = 0
    const request = mount({
      create: async () => {
        creates += 1
        return { sessionId: 'should-not-run' }
      },
    })
    await expect(request(
      'POST', '/dsh-anywhere/v1/sessions', { cwd: '/Users/me/Code' }, 'x'.repeat(257),
    )).resolves.toMatchObject({ status: 400 })
    expect(creates).toBe(0)
  })

  it('does not let unauthenticated request ids consume trusted idempotency slots', async () => {
    const request = mount()
    for (let index = 0; index < 2_000; index += 1) {
      await expect(request(
        'POST', '/dsh-anywhere/v1/sessions', { cwd: '/Users/me/Code' }, `invalid-${index}`,
        'Bearer invalid-connector-token',
      )).resolves.toMatchObject({ status: 401 })
    }
    await expect(request(
      'POST', '/dsh-anywhere/v1/sessions', { cwd: '/Users/me/Code' }, 'trusted-after-invalid-flood',
    )).resolves.toMatchObject({ status: 201 })
  })

  it('does not permanently cache a prompt rejection under its request id', async () => {
    let attempts = 0
    const request = mount({
      prompt: async () => {
        attempts += 1
        if (attempts === 1) throw new Error('Harness was temporarily unavailable')
        return { accepted: true }
      },
    })
    await expect(request('POST', '/dsh-anywhere/v1/sessions/session-1/prompt', { text: 'hello', requestId: 'prompt-retry' }, 'prompt-retry'))
      .resolves.toMatchObject({ status: 503, body: { error: 'Harness was temporarily unavailable' } })
    await expect(request('POST', '/dsh-anywhere/v1/sessions/session-1/prompt', { text: 'hello', requestId: 'prompt-retry' }, 'prompt-retry'))
      .resolves.toMatchObject({ status: 202, body: { accepted: true, requestId: 'prompt-retry' } })
    expect(attempts).toBe(2)
  })

  it('lists paired-Mac folders when Harness selected its native chooser', async () => {
    const directory = await mkdtemp(join(tmpdir(), 'dsh-directory-browser-'))
    await Promise.all([
      mkdir(join(directory, 'Zebra')),
      mkdir(join(directory, 'alpha')),
      mkdir(join(directory, '.hidden')),
      writeFile(join(directory, 'not-a-folder.txt'), 'ignored', 'utf8'),
    ])
    const request = mount({ directoryPicker: { capability: () => ({ kind: 'native' }) } })
    await expect(request('GET', `/dsh-anywhere/v1/directories?path=${encodeURIComponent(directory)}`))
      .resolves.toEqual({
        status: 200,
        body: {
          path: directory,
          parentPath: dirname(directory),
          directories: [
            { name: '.hidden', path: join(directory, '.hidden') },
            { name: 'alpha', path: join(directory, 'alpha') },
            { name: 'Zebra', path: join(directory, 'Zebra') },
          ],
        },
      })
    await expect(request('GET', '/dsh-anywhere/v1/directories?path=not-an-absolute-path'))
      .resolves.toMatchObject({ status: 400, body: { error: 'cannot list "not-an-absolute-path": not an absolute path' } })
  })

  it('reports an unavailable directory browser when Harness provides no picker capability', async () => {
    const request = mount()
    await expect(request('GET', '/dsh-anywhere/v1/directories?path=%2FUsers%2Fme'))
      .resolves.toMatchObject({ status: 501, body: { error: 'Harness directory browsing is unavailable' } })
  })

  it('gives only the attachment route a bounded 10 MiB upload budget', async () => {
    let uploads = 0
    const request = mount({
      invoke: async () => {
        uploads += 1
        return { ok: true, value: { receiptId: 'receipt-1', file: { size: 825_000 } } }
      },
    })
    // This JSON body is larger than the ordinary 1 MiB readJson ceiling and
    // therefore proves the real route, rather than a mocked fetch, accepts it.
    await expect(request('POST', '/dsh-anywhere/v1/sessions/s1/attachments', {
      name: 'photo.jpg', data: 'A'.repeat(1_100_000),
    })).resolves.toMatchObject({ status: 201, body: { receiptId: 'receipt-1' } })
    expect(uploads).toBe(1)

    await expect(request('POST', '/dsh-anywhere/v1/sessions/s1/attachments', {
      name: 'too-large.bin', data: 'A'.repeat(Math.ceil((10 * 1024 * 1024) / 3) * 4 + 1),
    })).resolves.toMatchObject({ status: 413 })
    expect(uploads).toBe(1)
  })

  it('releases a pending attachment after a deterministic native rejection', async () => {
    let attempts = 0
    const request = mount({
      invoke: async () => {
        attempts += 1
        if (attempts === 1) throw new HttpError(501, 'upload service unavailable')
        return { ok: true, value: { receiptId: 'receipt-retry', file: { size: 3 } } }
      },
    })
    await expect(request(
      'POST', '/dsh-anywhere/v1/sessions/s1/attachments',
      { name: 'a.txt', data: 'YWJj' }, 'attachment-retry',
    )).resolves.toMatchObject({ status: 501 })
    await expect(request(
      'POST', '/dsh-anywhere/v1/sessions/s1/attachments',
      { name: 'a.txt', data: 'YWJj' }, 'attachment-retry',
    )).resolves.toMatchObject({ status: 201, body: { receiptId: 'receipt-retry' } })
    expect(attempts).toBe(2)
  })

  it('reconciles a committed attachment receipt after a Bridge restart', async () => {
    const dataDir = mkdtempSync(join(tmpdir(), 'dsh-anywhere-attachment-recovery-'))
    const requestId = 'attachment-recover'
    const key = `${CONNECTOR_DEVICE_ID}\u0000s1\u0000${requestId}`
    const nativeOperationId = createHash('sha256')
      .update(`attachment\0${key}`).digest('hex')
    await writeFile(join(dataDir, 'session-metadata.json'), JSON.stringify({
      attachmentUploads: {
        [key]: { pending: true, nativeOperationId },
      },
    }))
    let uploads = 0
    const request = mount({
      dataDir,
      invoke: async () => {
        uploads += 1
        return { ok: true, value: { receiptId: 'must-not-upload-again' } }
      },
      findAttachmentByRequestId: async (operationId) => {
        expect(operationId).toBe(nativeOperationId)
        return { receiptId: 'receipt-recovered', file: { size: 3 } }
      },
    })
    await expect(request(
      'POST', '/dsh-anywhere/v1/sessions/s1/attachments',
      { name: 'a.txt', data: 'YWJj' }, requestId,
    )).resolves.toMatchObject({ status: 200, body: { receiptId: 'receipt-recovered' } })
    expect(uploads).toBe(0)
  })

  it('retries after an adapter proves a pending upload never committed', async () => {
    const dataDir = mkdtempSync(join(tmpdir(), 'dsh-anywhere-attachment-not-committed-'))
    const requestId = 'attachment-not-committed'
    const key = `${CONNECTOR_DEVICE_ID}\u0000s1\u0000${requestId}`
    const nativeOperationId = createHash('sha256')
      .update(`attachment\0${key}`).digest('hex')
    await writeFile(join(dataDir, 'session-metadata.json'), JSON.stringify({
      attachmentUploads: {
        [key]: { pending: true, nativeOperationId },
      },
    }))
    let uploads = 0
    const request = mount({
      dataDir,
      invoke: async () => {
        uploads += 1
        return { ok: true, value: { receiptId: 'receipt-after-negative-recovery' } }
      },
      findAttachmentByRequestId: async () => ({ state: 'not-committed' }),
    })
    await expect(request(
      'POST', '/dsh-anywhere/v1/sessions/s1/attachments',
      { name: 'a.txt', data: 'YWJj' }, requestId,
    )).resolves.toMatchObject({ status: 201, body: { receiptId: 'receipt-after-negative-recovery' } })
    expect(uploads).toBe(1)
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

describe('subagent sessions stay out of the user list', () => {
  it('recognises a subagent by its spawn link or its origin marker', () => {
    // Either signal alone is enough: 18 of 40 rows were subagents in practice,
    // each titled with the task prompt handed to it.
    expect(isSubagentSession({ parentSessionId: 'session-parent' })).toBe(true)
    expect(isSubagentSession({ origin: 'subagent' })).toBe(true)
    expect(isSubagentSession({ title: 'iOS客户端开发' })).toBe(false)
  })

  it('passes the spawn link through summary normalization', () => {
    const summary = normalizeSessionSummary({
      sessionId: 'session-child',
      cwd: '/tmp/work',
      updatedAt: 1,
      parentSessionId: 'session-parent',
      origin: 'subagent',
    })
    // Without this the filter upstream has nothing to act on.
    expect(summary.parentSessionId).toBe('session-parent')
    expect(summary.origin).toBe('subagent')
    expect(isSubagentSession(summary)).toBe(true)
  })
});

describe('silent setup echoes', () => {
  it('drops the preset acknowledgement inside an armed window', async () => {
    const { armSilentSetupWindow, isSilentSetupEcho } = await import('./index.js')
    const echo = { type: 'command/done', data: { commandId: 'cmd-1', kind: 'success', text: 'preset workspace-write' } }
    expect(isSilentSetupEcho('s', echo)).toBe(false)
    armSilentSetupWindow('s')
    expect(isSilentSetupEcho('s', echo)).toBe(true)
    // Other sessions, other commands and other texts pass through.
    expect(isSilentSetupEcho('other', echo)).toBe(false)
    expect(isSilentSetupEcho('s', { type: 'command/done', data: { text: 'something else' } })).toBe(false)
    expect(isSilentSetupEcho('s', { type: 'tool/call', data: {} })).toBe(false)
  })
});

describe('history recipient routing', () => {
  it('routes connector history to the requesting phone and restricts direct clients', () => {
    expect(historyRecipient(CONNECTOR_DEVICE_ID, 'phone-1')).toBe('phone-1')
    expect(historyRecipient(CONNECTOR_DEVICE_ID, undefined)).toBe(CONNECTOR_DEVICE_ID)
    expect(historyRecipient(CONNECTOR_DEVICE_ID, '')).toBe(CONNECTOR_DEVICE_ID)
    expect(historyRecipient('phone-1', 'phone-2')).toBe('phone-1')
  })
})
