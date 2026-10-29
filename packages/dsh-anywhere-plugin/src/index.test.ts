import { describe, expect, it, vi } from 'vitest'
import { Readable } from 'node:stream'
import { createHash } from 'node:crypto'
import { mkdir, mkdtemp, writeFile, readFile } from 'node:fs/promises'
import { mkdtempSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { dirname, join } from 'node:path'
import type { IncomingMessage, ServerResponse } from 'node:http'
import { EventEnvelopeSchema } from '@dsh-anywhere/protocol'
import { historyRecipient, CONNECTOR_DEVICE_ID, LIVE_REASONING_TRAIL_LIMIT, PairingRateLimiter, apply, inject, isSubagentSession, liveReasoningTrail, liveStreamChunkEvent, modeCatalogFromRemote, normalizeSessionEvent, normalizeSessionEvents, normalizeSessionSummary, readPairingMaterial, workspaceCatalog } from './index.js'
import { HttpError } from './http.js'
import type { Context } from '@deepseek-ai/cordis'
import { ReplayBuffer } from './replay.js'

describe('DeepSeek Harness event normalization', () => {
  it('keeps durable file attachments and uses only Host-owned storage paths for original bytes', () => {
    const file = { attachmentId: 'sha256:' + 'ab'.repeat(32), name: 'report.pdf', bytes: 10 }
    const image = { attachmentId: 'sha256:' + 'cd'.repeat(32), mediaType: 'image/png', width: 1, height: 1, bytes: 10 }
    const source = { type: 'user/message', data: { id: 'u', source: { kind: 'user' }, content: [
      { type: 'file', attachment: file, hostPath: '/untrusted/block-path' }, { type: 'image', attachment: image } ] } }
    const paths = { fileHostPath: vi.fn(() => '/host/files/report.pdf'), imageHostPath: vi.fn(() => '/host/objects/image') }
    const result = normalizeSessionEvents('s', source, new Map(), undefined, undefined, undefined, paths)
    expect(result[0]).toMatchObject({ type: 'user.message.accepted', payload: { attachments: [
      { name: 'report.pdf', hostPath: '/host/files/report.pdf' }, { hostPath: '/host/objects/image', mediaType: 'image/png' } ] } })
    expect(paths.fileHostPath).toHaveBeenCalledWith(file)
    expect(paths.imageHostPath).toHaveBeenCalledWith(image)
    const fallback = normalizeSessionEvents('s', source, new Map())
    expect(fallback[0]).toMatchObject({ payload: { attachments: [{ name: 'report.pdf' }, { mediaType: 'image/png' }] } })
    expect((fallback[0]?.payload as { attachments: unknown[] }).attachments.every((item) => !('hostPath' in (item as object)))).toBe(true)
    expect(normalizeSessionEvents('s', source, new Map())[0]?.payload).toEqual(fallback[0]?.payload)
    const invalid = normalizeSessionEvents('s', source, new Map(), undefined, undefined, undefined, { fileHostPath: () => { throw new Error('invalid ref') } })
    expect(invalid[0]).toMatchObject({ payload: { attachments: [{ name: 'report.pdf' }, { mediaType: 'image/png' }] } })
  })
  it('preserves structured turn terminal reasons instead of treating every object as completed', () => {
    for (const [kind, state] of [['error', 'failed'], ['aborted', 'cancelled'], ['max-tokens', 'max-tokens'], ['interrupted', 'interrupted']]) {
      expect(normalizeSessionEvents('s', { type: 'turn/end', data: { turn: 1, reason: { kind } } }, new Map()))
        .toEqual([{ type: 'turn.state.changed', sessionId: 's', payload: { sessionId: 's', state } }])
    }
  })
  it('retains the Host sequence as the native fork boundary', () => {
    const events = normalizeSessionEvents('s', { seq: 42, type: 'assistant/message',
      data: { message: { id: 'a', content: [{ type: 'text', text: 'Done' }] } } }, new Map())
    expect(events).toContainEqual({ type: 'assistant.message.completed', sessionId: 's',
      payload: { id: 'a', role: 'assistant', markdown: 'Done', nativeSequence: 42 } })
  })
  it('replays todo whole-list snapshots and preserves an explicit empty list', () => {
    const todos = [{ content: 'Read source', status: 'completed' }, { content: 'Verify', status: 'in_progress' }]
    expect(normalizeSessionEvents('s', { type: 'todo/write', data: { todos } }, new Map()))
      .toEqual([{ type: 'todo.changed', sessionId: 's', payload: { sessionId: 's', todos } }])
    expect(normalizeSessionEvents('s', { type: 'todo/write', data: { todos: [] } }, new Map()))
      .toEqual([{ type: 'todo.changed', sessionId: 's', payload: { sessionId: 's', todos: [] } }])
    expect(normalizeSessionEvents('s', { type: 'todo/write', data: { todos: [{ content: 'bad', status: 'invented' }] } }, new Map())).toEqual([])
  })
  it('preserves durable plan and goal changes without inventing activation', () => {
    const tools = new Map<string, string>()
    expect(normalizeSessionEvents('s', { type: 'plan/mode', data: { active: true } }, tools))
      .toEqual([{ type: 'plan.changed', sessionId: 's', payload: { sessionId: 's', active: true } }])
    const goal = { id: 'g', revision: 1, objective: 'Ship it', phase: 'active', maxGoalRounds: 12 }
    expect(normalizeSessionEvents('s', {
      type: 'goal/change', data: { operation: 'create', goal, roundsStarted: 0 },
    }, tools)).toEqual([{ type: 'goal.changed', sessionId: 's', payload: { sessionId: 's', goal, roundsStarted: 0 } }])
    expect(normalizeSessionEvents('s', { type: 'goal/change', data: { operation: 'clear' } }, tools))
      .toEqual([{ type: 'goal.changed', sessionId: 's', payload: { sessionId: 's', goal: null, roundsStarted: 0 } }])
    expect(normalizeSessionEvents('s', { type: 'goal/change', data: { operation: 'create', goal: {} } }, tools)).toEqual([])
    expect(normalizeSessionEvents('s', { type: 'user/message', data: {
      source: { kind: 'goal', goalId: 'g', revision: 1, round: 3 },
    } }, tools)).toEqual([{ type: 'goal.round', sessionId: 's', payload: { sessionId: 's', id: 'g', round: 3 } }])
  })
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
      payload: { id: 'c1', name: 'shell', status: 'succeeded', detail: '/tmp', resultContent: [{ type: 'text', text: '/tmp' }] },
    })
  })

  it('keeps native result metadata, failure diagnostics and full image references on tools', () => {
    const meta = { diffs: [{ path: 'src/中文.swift', oldText: 'before', newText: 'after' }] }
    const error = { message: 'denied', code: 'PERMISSION' }
    const content = [{ type: 'text', text: 'diagnostic' }, { type: 'image', attachment: { attachmentId: 'sha256:' + 'ef'.repeat(32), mediaType: 'image/png' } }]
    const result = normalizeSessionEvents('s', { seq: 7, time: 2500, type: 'tool/result',
      data: { meta, error, message: { content: [{ type: 'tool-result', toolCallId: 'c', isError: true, content }] } } },
      new Map([['c', 'edit']]), undefined, undefined, undefined, { imageHostPath: () => '/native/image' })
    expect(result[0]).toMatchObject({ type: 'tool.completed', payload: { id: 'c', name: 'edit', status: 'failed',
      detail: 'diagnostic', resultMeta: meta, resultContent: content, error, nativeSequence: 7, finishedAt: 2500,
      attachments: [{ mediaType: 'image/png', hostPath: '/native/image' }] } })
    expect(EventEnvelopeSchema.safeParse({ version: 1, messageId: 'e', deviceId: 'd', machineId: 'm',
      sequence: 1, timestamp: Date.now(), ...result[0] }).success).toBe(true)
  })

  it('keeps exact subcall addresses, arguments, outcomes and native times during replay', () => {
    const data = { rootCallId: 'root', parentCallId: 'nested', subCallId: 'child', name: 'grep', arguments: { pattern: '检查' } }
    const started = normalizeSessionEvents('s', { seq: 8, time: 1000, type: 'tool/ptc-dispatch-start', data }, new Map())
    expect(started).toEqual([{ type: 'tool.started', sessionId: 's', payload: { id: 'child', name: 'grep',
      rootCallId: 'root', parentCallId: 'nested', status: 'running', detail: '{"pattern":"检查"}', startedAt: 1000, nativeSequence: 8 } }])
    const finished = normalizeSessionEvents('s', { seq: 9, time: 1500, type: 'tool/ptc-dispatch',
      data: { ...data, isError: true, content: [{ type: 'text', text: 'aborted' }] } }, new Map())
    expect(finished[0]).toMatchObject({ type: 'tool.completed', payload: { id: 'child', rootCallId: 'root', parentCallId: 'nested',
      name: 'grep', arguments: '{"pattern":"检查"}', detail: 'aborted', status: 'failed', finishedAt: 1500, nativeSequence: 9 } })
    expect(normalizeSessionEvents('s', { type: 'tool/ptc-dispatch', data: { name: 'grep' } }, new Map())).toEqual([])
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
    control?: (signal: AbortSignal) => AsyncIterable<unknown>
    inspect?: (sessionId: string) => Promise<{ events: unknown[]; meta?: unknown; inheritedEventCount?: number }>
    page?: (request: unknown) => Promise<unknown>
    sessionQuery?: unknown
    sessionProjections?: unknown
    updateQueue?: (request: unknown) => Promise<unknown>
    fork?: (request: { sessionId: string; atSeq?: number }) => Promise<{ sessionId: string }>
    create?: (request: { cwd?: string; workspaceId?: string; agentPreset?: string }) => Promise<{ sessionId: string }>
    prompt?: () => Promise<{ accepted: true }>
    rename?: (request: { sessionId: string; title: string }) => Promise<unknown>
    createWorkspace?: (path: string, title?: string) => Promise<{ id: string; path: string; title: string; sessionIds: readonly string[] }>
    directoryPicker?: unknown
    invoke?: (request: unknown) => Promise<unknown>
    connection?: unknown
    attachmentStore?: unknown
    upgrade?: (handler: (req: IncomingMessage, socket: never, head: Buffer) => void) => void
    responseHeaders?: (headers: unknown) => void
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
    const cleanups: Array<() => unknown> = []
    const context = {
      get: (name: string) => name === 'attachments' ? options.attachmentStore : name === 'sessionQuery' ? options.sessionQuery : name === 'sessionProjections' ? options.sessionProjections : undefined,
      logger: { info: () => undefined, warn: () => undefined },
      webServer: {
        register: (route: { handler: (req: IncomingMessage, res: ServerResponse) => void | Promise<void> }) => {
          handler = route.handler
          return () => undefined
        },
        registerUpgrade: (route: { handler: (req: IncomingMessage, socket: never, head: Buffer) => void }) => { options.upgrade?.(route.handler); return () => undefined },
      },
      sessionController: {
        ...(options.control === undefined ? {} : { control: options.control }),
        ...(options.page === undefined ? {} : { page: options.page }),
        ...(options.updateQueue === undefined ? {} : { updateQueue: options.updateQueue }),
        ...(options.fork === undefined ? {} : { fork: options.fork }),
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
        inspect: options.inspect ?? (async () => ({ events: [] })),
      },
      workspaceRegistry: {
        list: () => [],
        ...(options.createWorkspace === undefined ? {} : { create: options.createWorkspace }),
        archivedSessionIds: [],
        archiveSession: async () => undefined,
      },
      ...(options.connection === undefined ? {} : { connection: options.connection }),
      typertGateway: {
        invoke: options.invoke ?? (async () => ({ ok: true, value: { presets: [] } })),
      },
      ...(options.directoryPicker === undefined ? {} : { directoryPicker: options.directoryPicker }),
      on: () => undefined,
      effect: (callback: () => unknown) => {
        if (options.control !== undefined) {
          const cleanup = callback()
          if (typeof cleanup === 'function') cleanups.push(cleanup as () => unknown)
        }
      },
    } as unknown as Context
    apply(context, { connectorToken })
    const send = async (method: string, url: string, body?: unknown, requestId?: string,
                  authorization = `Bearer ${connectorToken}`, schemaRevision: string | null = "12"): Promise<{ status: number; body: unknown }> => {
      const request = Readable.from([body === undefined ? '' : JSON.stringify(body)]) as unknown as IncomingMessage
      Object.assign(request, {
        method,
        url,
        headers: {
          authorization,
          ...(schemaRevision === null ? {} : { 'x-dsh-schema-revision': schemaRevision }),
          ...(requestId === undefined ? {} : { 'x-dsh-request-id': requestId }),
          ...(url.endsWith('/configuration') && body !== undefined ? { 'x-dsh-request-hash': createHash('sha256').update(JSON.stringify(body)).digest('hex') } : {}),
        },
        socket: { remoteAddress: '127.0.0.1' },
      })
      let status = 0
      let response = ''
      const reply = {
        writeHead: (value: number, headers: unknown) => { status = value; options.responseHeaders?.(headers) },
        end: (value?: string) => { response = value ?? '' },
      } as unknown as ServerResponse
      await handler!(request, reply)
      return { status, body: response.length === 0 ? undefined : JSON.parse(response) }
    }
    return Object.assign(send, { dispose: () => { for (const cleanup of cleanups.reverse()) cleanup() } })
  }

  it('refuses legacy Connector websocket upgrades before replaying richer events', () => {
    let upgrade: ((req: IncomingMessage, socket: never, head: Buffer) => void) | undefined
    mount({ upgrade: handler => { upgrade = handler } })
    const socket = { write: vi.fn(), destroy: vi.fn() }
    for (const revision of [undefined, '10', '11']) {
      const request = { url: '/dsh-anywhere/v1/events', headers: { authorization: `Bearer ${connectorToken}`, ...(revision === undefined ? {} : { 'x-dsh-schema-revision': revision }) } } as IncomingMessage
      upgrade!(request, socket as never, Buffer.alloc(0))
      expect(socket.write).toHaveBeenLastCalledWith(expect.stringContaining('426 Upgrade Required'))
    }
    expect(socket.destroy).toHaveBeenCalledTimes(3)
  })
  it('rejects an obsolete Connector before reads, writes or idempotency reservation, while keeping health readable', async () => {
    const invoke = vi.fn(async () => ({ TEST_KEY: { configured: false, writable: true } }))
    const request = mount({ invoke })
    const body = { kind: 'credential', action: 'set', ref: 'TEST_KEY', value: 'never-forward' }
    await expect(request('GET', '/dsh-anywhere/v1/health', undefined, undefined, `Bearer ${connectorToken}`, null)).resolves.toMatchObject({ status: 200, body: { schemaRevision: 12, minimumConnectorSchemaRevision: 12 } })
    for (const revision of [null, '10', '11', '11junk']) {
      await expect(request('POST', '/dsh-anywhere/v1/configuration', body, 'same-id', `Bearer ${connectorToken}`, revision)).resolves.toMatchObject({ status: 426 })
      await expect(request('GET', '/dsh-anywhere/v1/configuration?section=credentials&refs=%5B%22TEST_KEY%22%5D', undefined, undefined, `Bearer ${connectorToken}`, revision)).resolves.toMatchObject({ status: 426 })
    }
    expect(invoke).not.toHaveBeenCalled()
    await expect(request('GET', '/dsh-anywhere/v1/configuration?section=credentials&refs=%5B%22TEST_KEY%22%5D', undefined, undefined, `Bearer ${connectorToken}`, '12')).resolves.toMatchObject({ status: 200 })
    expect(invoke).toHaveBeenCalledTimes(1)
  })
  it('does not cache or journal model probes under a repeated request id', async () => {
    const dataDir = mkdtempSync(join(tmpdir(), 'dsh-discovery-'))
    let calls = 0
    const request = mount({ dataDir, invoke: async (value) => {
      expect(value).toMatchObject({ namespace: 'llm', method: 'discoverModels', args: { settingsNs: 'llm-test', request: { apiKey: 'temporary-secret' } } })
      calls += 1; return [{ id: `model-${calls}` }]
    } })
    const body = { settingsNs: 'llm-test', request: { apiKey: 'temporary-secret' } }
    await expect(request('POST', '/dsh-anywhere/v1/configuration/discover', body, 'probe')).resolves.toEqual({ status: 200, body: { settingsNs: 'llm-test', models: [{ id: 'model-1' }] } })
    await expect(request('POST', '/dsh-anywhere/v1/configuration/discover', body, 'probe')).resolves.toMatchObject({ body: { models: [{ id: 'model-2' }] } })
    expect(calls).toBe(2)
    const persisted = await readFile(join(dataDir, 'session-metadata.json'), 'utf8').catch(() => '')
    expect(persisted).not.toContain('temporary-secret'); expect(persisted).not.toContain('model-1')
  })
  it('journals credential acknowledgements and fingerprints without storing the submitted secret', async () => {
    const dataDir = mkdtempSync(join(tmpdir(), 'dsh-configuration-secret-'))
    let writes = 0
    const request = mount({ dataDir, invoke: async (value) => {
      const call = value as { namespace: string; method: string; args: unknown }
      if (call.namespace === 'credentials' && call.method === 'describe') return { TEST_KEY: { configured: false, writable: true } }
      expect(call).toMatchObject({ namespace: 'credentials', method: 'set', args: { ref: 'TEST_KEY', value: 'not-a-real-secret-never-persist' } })
      writes += 1; return undefined
    } })
    const body = { kind: 'credential', action: 'set', ref: 'TEST_KEY', value: 'not-a-real-secret-never-persist' }
    const expected = { status: 202, body: { kind: 'credential', requestId: 'credential-1', ref: 'TEST_KEY' } }
    await expect(request('POST', '/dsh-anywhere/v1/configuration', body, 'credential-1')).resolves.toEqual(expected)
    await expect(request('POST', '/dsh-anywhere/v1/configuration', body, 'credential-1')).resolves.toEqual(expected)
    await expect(request('POST', '/dsh-anywhere/v1/configuration', { ...body, value: 'different' }, 'credential-1')).resolves.toMatchObject({ status: 409 })
    expect(writes).toBe(1)
    const persisted = await readFile(join(dataDir, 'session-metadata.json'), 'utf8')
    expect(persisted).not.toContain(body.value)
    expect(persisted).toContain('fingerprint')
  })
  it('keeps uncertain configuration writes parked and does not echo adapter exceptions', async () => {
    let writes = 0
    const request = mount({ invoke: async (value) => {
      const call = value as { method: string }
      if (call.method === 'describe') return { TEST_KEY: { configured: false, writable: true } }
      writes += 1; throw new Error('secret-must-not-appear-in-errors')
    } })
    const body = { kind: 'credential', action: 'set', ref: 'TEST_KEY', value: 'secret-must-not-appear-in-errors' }
    const first = await request('POST', '/dsh-anywhere/v1/configuration', body, 'unknown-setting')
    expect(first.status).toBe(503); expect(JSON.stringify(first.body)).not.toContain(body.value)
    await expect(request('POST', '/dsh-anywhere/v1/configuration', body, 'unknown-setting')).resolves.toMatchObject({ status: 503 })
    expect(writes).toBe(1)
    await expect(request('GET', '/dsh-anywhere/v1/configuration?section=credentials&refs=%5B%22NOT-A-REF%22%5D')).resolves.toMatchObject({ status: 400 })
  })
  it('saves native message feedback once and returns the same confirmed receipt on retry', async () => {
    const item = { messageId: 'a', rating: 'negative', note: '保留备注', version: 'v2', createdAt: 1, updatedAt: 2 }
    const invoke = vi.fn(async () => ({ ok: true, value: item }))
    const request = mount({ invoke })
    const payload = { action: 'put', messageId: 'a', rating: 'negative', note: '保留备注', ifVersion: 'v1' }
    const expected = { status: 202, body: { sessionId: 's', messageId: 'a', requestId: 'f1', item } }
    await expect(request('POST', '/dsh-anywhere/v1/sessions/s/feedback', payload, 'f1')).resolves.toEqual(expected)
    await expect(request('POST', '/dsh-anywhere/v1/sessions/s/feedback', payload, 'f1')).resolves.toEqual(expected)
    expect(invoke).toHaveBeenCalledTimes(1)
    expect(invoke).toHaveBeenCalledWith(expect.objectContaining({ namespace: 'messageFeedback', method: 'put', args: { request: {
      sessionId: 's', messageId: 'a', rating: 'negative', note: '保留备注', ifVersion: 'v1' } } }))
  })

  it('reads references through Agent-scoped native interfaces and preserves canonical session mentions', async () => {
    const invoke = vi.fn(async (request: unknown) => (request as { namespace: string }).namespace === 'fileReferences'
      ? { ok: true, value: [{ path: '目录/a b.ts', kind: 'file' }] }
      : { ok: true, value: [{ sessionId: 'a/b', label: 'Another session', mention: '@[Another session](dsh-session:ImEvYiI)', sameWorkspace: false }] })
    const request = mount({ invoke })
    await expect(request('GET', '/dsh-anywhere/v1/sessions/s/references?kind=file&query=%E7%9B%AE%E5%BD%95%2F')).resolves.toMatchObject({ status: 200,
      body: { sessionId: 's', kind: 'file', query: '目录/', items: [{ insertion: '@"目录/a b.ts"' }] } })
    expect(invoke).toHaveBeenCalledWith(expect.objectContaining({ namespace: 'fileReferences', method: 'list', args: { agentId: 's', query: '目录/' } }))
    await expect(request('GET', '/dsh-anywhere/v1/sessions/s/references?kind=session&query=Another')).resolves.toMatchObject({ status: 200,
      body: { items: [{ sourceSessionId: 'a/b', insertion: '@[Another session](dsh-session:ImEvYiI)' }] } })
    expect(invoke).toHaveBeenCalledWith(expect.objectContaining({ namespace: 'sessionReferenceResolver', method: 'candidates', args: { agentId: 's', query: 'Another' } }))
    await expect(request('GET', '/dsh-anywhere/v1/sessions/s/references?kind=invented')).resolves.toMatchObject({ status: 400 })
  })

  it('keeps uncertain feedback parked and makes explicit CAS conflicts reviewable', async () => {
    const invoke = vi.fn(async () => { throw new Error('response lost') })
    const uncertain = mount({ invoke })
    const payload = { action: 'put', messageId: 'a', rating: 'positive', ifVersion: null }
    await expect(uncertain('POST', '/dsh-anywhere/v1/sessions/s/feedback', payload, 'unknown')).resolves.toMatchObject({ status: 503 })
    await expect(uncertain('POST', '/dsh-anywhere/v1/sessions/s/feedback', payload, 'unknown')).resolves.toMatchObject({ status: 503 })
    expect(invoke).toHaveBeenCalledTimes(1)
    const rejected = mount({ invoke: async () => ({ ok: false, error: { code: 'version-conflict', current: null } }) })
    await expect(rejected('POST', '/dsh-anywhere/v1/sessions/s/feedback', payload, 'conflict')).resolves.toMatchObject({ status: 409 })
  })

  it('returns a coherent feedback snapshot and uses the native delete token', async () => {
    const item = { messageId: 'a', rating: 'positive', version: 'v1', createdAt: 1, updatedAt: 1 }
    const invoke = vi.fn(async (input: unknown) => (input as { method: string }).method === 'list'
      ? { ok: true, value: { items: [item] } } : { ok: true, value: { absent: true } })
    const request = mount({ invoke, inspect: async () => ({ events: [
      { seq: 7, type: 'feedback/message-put', data: { sessionId: 's', item } }, { seq: 8, type: 'step/end', data: {} } ] }) })
    await expect(request('GET', '/dsh-anywhere/v1/sessions/s/feedback')).resolves.toEqual({ status: 200, body: { sessionId: 's', nativeSequence: 8, items: [item] } })
    await expect(request('POST', '/dsh-anywhere/v1/sessions/s/feedback', { action: 'delete', messageId: 'a', ifVersion: 'v1' }, 'delete'))
      .resolves.toEqual({ status: 202, body: { sessionId: 's', messageId: 'a', requestId: 'delete', item: null } })
    expect(invoke).toHaveBeenCalledWith(expect.objectContaining({ method: 'delete', args: { request: { sessionId: 's', messageId: 'a', ifVersion: 'v1' } } }))
  })

  it('replays existing control state to a phone that opens after the control baseline', async () => {
    const appended = vi.spyOn(ReplayBuffer.prototype, 'append')
    const request = mount({
      control: async function* (signal) {
        yield { type: 'baseline', value: {
          queues: { child: [{ id: 'item', placement: 'queued', message: { id: 'item', content: [
            { type: 'text', text: 'Next' },
            { type: 'image', attachment: { attachmentId: 'sha256:' + 'ef'.repeat(32), mediaType: 'image/png' } },
            { type: 'file', attachment: { attachmentId: 'sha256:' + 'ab'.repeat(32), name: 'spec.pdf', bytes: 1 } },
          ] } }] },
          jobs: { child: [{ id: 'job', kind: 'shell', label: 'Build', status: 'running', startedAt: 1 }] },
          projections: { child: { asOfSeq: 8, values: { plan: { active: false, pending: true } } } },
        } }
        await new Promise<void>((resolve) => {
          if (signal.aborted) resolve()
          else signal.addEventListener('abort', () => resolve(), { once: true })
        })
      },
      attachmentStore: { imageHostPath: () => '/host/image', fileHostPath: () => '/host/spec.pdf' },
      invoke: async (value) => (value as { namespace: string }).namespace === 'subagents'
        ? { ok: true, value: { parentAvailable: true, entries: [{ kind: 'child', id: 'child', mode: 'continuable', label: 'Task', activity: 'running', hasChildren: false }] } }
        : { ok: true, value: undefined },
    })
    try {
      await expect(request('POST', '/dsh-anywhere/v1/sessions/child/open',
        { parentSessionId: 'parent', subagentMode: 'continuable', deviceId: 'late-phone' })).resolves.toMatchObject({ status: 202 })
      const targeted = appended.mock.calls.map(([event]) => event).filter((event) => event.deviceId === 'late-phone')
      expect(targeted).toContainEqual(expect.objectContaining({ type: 'jobs.changed', payload: expect.objectContaining({ sessionId: 'child', available: true, jobs: expect.arrayContaining([expect.objectContaining({ id: 'job' })]) }) }))
      expect(targeted).toContainEqual(expect.objectContaining({ type: 'queue.changed', payload: expect.objectContaining({ sessionId: 'child', items: expect.arrayContaining([expect.objectContaining({ id: 'item' })]) }) }))
      expect(targeted).toContainEqual(expect.objectContaining({ type: 'queue.changed', payload: expect.objectContaining({ items: expect.arrayContaining([
        expect.objectContaining({ attachments: expect.arrayContaining([expect.objectContaining({ hostPath: '/host/image' }), expect.objectContaining({ name: 'spec.pdf', hostPath: '/host/spec.pdf' })]) }) ]) }) }))
      expect(targeted).toContainEqual(expect.objectContaining({ type: 'plan.projection', payload: expect.objectContaining({ sessionId: 'child', active: false, pending: true }) }))
    } finally { request.dispose(); appended.mockRestore() }
  })

  it('serves an authenticated empty pending-decision baseline with a Host epoch', async () => {
    const request = mount()
    const result = await request('GET', '/dsh-anywhere/v1/decisions')
    expect(result).toMatchObject({ status: 200, body: { approvals: [], questions: [], stateVersion: { revision: 0 } } })
    expect((result.body as { stateVersion: { epoch: string } }).stateVersion.epoch).toBeTruthy()
    await expect(request('GET', '/dsh-anywhere/v1/decisions', undefined, undefined, 'Bearer wrong'))
      .resolves.toMatchObject({ status: 401 })
  })
  it('reads optional reminders with the Host cold projector and exact fork inheritance metadata', async () => {
    const meta = { id: 'child', createdAt: 1000 }, events = [{ seq: 0, type: 'schedule/change', data: { inherited: true } }]
    const restore = vi.fn((_checkpoint: unknown, _events: unknown, _base: unknown, _meta: unknown, _inherited: unknown) => ({ snapshot: { asOfSeq: 0, values: { schedule: [] } } }))
    const invoke = async () => ({ ok: true, value: { parentAvailable: false,
      entries: [{ kind: 'child', id: 'child', mode: 'one-shot', activity: 'inactive', hasChildren: false }] } })
    const request = mount({ inspect: async () => ({ events, meta, inheritedEventCount: 1 }), sessionProjections: { restore }, invoke })
    await expect(request('GET', '/dsh-anywhere/v1/sessions/child/schedules?parentSessionId=p&subagentMode=one-shot')).resolves.toMatchObject({ status: 200, body: { supported: true, available: true, items: [], seq: 0 } })
    expect(restore).toHaveBeenCalledWith({}, events, 0, meta, 1)
    await expect(request('GET', '/dsh-anywhere/v1/sessions/child/schedules?parentSessionId=p&subagentMode=continuable')).resolves.toMatchObject({ status: 403 })
    await expect(mount({ invoke })('GET', '/dsh-anywhere/v1/sessions/child/schedules?parentSessionId=p&subagentMode=one-shot')).resolves.toMatchObject({ status: 501 })
  })
  it('reads exact native history pages through a verified child address without activating it', async () => {
    const events = [{ seq: 0, time: 0, type: 'request/header', data: { header: { config: { model: 'm' } } } },
      { seq: 1, time: 1000, type: 'user/message', data: { id: 'u', source: { kind: 'user' }, content: [{ type: 'text', text: 'Hello' }] } }]
    const nativePage = vi.fn(async (_request: unknown) => ({ records: events.map((event) => ({ type: 'event', event })), hasMore: false }))
    const request = mount({ inspect: async () => ({ events }), page: nativePage, invoke: async () => ({ ok: true, value: { parentAvailable: false,
      entries: [{ kind: 'child', id: 'child', mode: 'one-shot', activity: 'inactive', hasChildren: false }] } }) })
    await expect(request('GET', '/dsh-anywhere/v1/sessions/child/history')).resolves.toMatchObject({ status: 404 })
    await expect(request('GET', '/dsh-anywhere/v1/sessions/child/history?parentSessionId=parent&subagentMode=continuable')).resolves.toMatchObject({ status: 403 })
    expect(nativePage).not.toHaveBeenCalled()
    await expect(request('GET', '/dsh-anywhere/v1/sessions/child/history?parentSessionId=parent&subagentMode=one-shot&atSeq=1')).resolves.toMatchObject({ status: 200,
      body: { sessionId: 'child', throughSeq: 1, fromSeq: 0, toSeq: 1, hasMore: false, focus: { nativeSequence: 1 }, rows: [{ type: 'user.message.accepted' }] } })
    expect(nativePage.mock.calls[0]![0]).toEqual({ address: { kind: 'subagent', parentSessionId: 'parent', childSessionId: 'child', mode: 'one-shot' }, throughSeq: 1, beforeSeq: 2, maxMessages: 20 })
    await expect(request('GET', '/dsh-anywhere/v1/sessions/child/history?parentSessionId=parent&subagentMode=one-shot&throughSeq=5')).resolves.toMatchObject({ status: 409 })
  })
  it('routes native search read-only and rejects invalid or unavailable capability', async () => {
    const searchSessions = vi.fn(async (_request: unknown) => ({ items: [], nextCursor: undefined }))
    const request = mount({ sessionQuery: { searchSessions, searchEvents: vi.fn() } })
    await expect(request('GET', '/dsh-anywhere/v1/search?query=%E4%BD%A0%E5%A5%BD')).resolves.toMatchObject({ status: 200, body: { query: '你好', items: [], hasMore: false } })
    expect(searchSessions.mock.calls[0]![0]).toMatchObject({ query: '你好', sessionFilters: [{ kind: 'id', values: [] }] })
    await expect(request('GET', '/dsh-anywhere/v1/search?query=%20%20')).resolves.toMatchObject({ status: 400 })
    await expect(mount()('GET', '/dsh-anywhere/v1/search?query=x')).resolves.toMatchObject({ status: 501 })
  })
  it('returns full child lifecycle independently of the requested execution page', async () => {
    const events = [{ seq: 0, time: 1000, type: 'turn/start', data: { turn: 0 } }, { seq: 1, time: 2000, type: 'turn/end', data: { turn: 0, reason: { kind: 'completed' } } },
      { seq: 2, time: 10000, type: 'turn/start', data: { turn: 1 } }, { seq: 3, time: 13000, type: 'turn/end', data: { turn: 1, reason: { kind: 'completed' } } }]
    const request = mount({ inspect: async () => ({ events, meta: { createdAt: 9000 }, inheritedEventCount: 2 }),
      invoke: async () => ({ parentAvailable: false, entries: [{ kind: 'child', id: 'child', mode: 'one-shot', activity: 'inactive', hasChildren: false }] }) })
    await expect(request('GET', '/dsh-anywhere/v1/sessions/child/execution?parentSessionId=parent&subagentMode=one-shot&limit=1&beforeSeq=3')).resolves.toMatchObject({ status: 200,
      body: { records: [{ nativeSequence: 2 }], lifecycle: { inheritedEventCount: 2, ownEventCount: 2, throughSeq: 3, turnsStarted: 1, turnsEnded: 1, endedTurnMilliseconds: 3000 } } })
  })
  it('pages execution history only through a verified parent address', async () => {
    const events = [{ seq: 0, type: 'turn/start', data: { turn: 1 } }, { seq: 2, type: 'step/start', data: { turn: 1, step: 1 } },
      { seq: 5, type: 'turn/end', data: { turn: 1, reason: { kind: 'aborted', reason: 'user' } } }]
    const request = mount({ inspect: async () => ({ events }), invoke: async () => ({ ok: true, value: { parentAvailable: false,
      entries: [{ kind: 'child', id: 'child', mode: 'one-shot', activity: 'inactive', hasChildren: false }] } }) })
    await expect(request('GET', '/dsh-anywhere/v1/sessions/child/execution')).resolves.toMatchObject({ status: 404 })
    await expect(request('GET', '/dsh-anywhere/v1/sessions/child/execution?parentSessionId=parent&subagentMode=continuable')).resolves.toMatchObject({ status: 403 })
    await expect(request('GET', '/dsh-anywhere/v1/sessions/child/execution?parentSessionId=parent&subagentMode=one-shot&limit=2')).resolves.toMatchObject({ status: 200,
      body: { sessionId: 'child', hasMore: true, beforeSeq: 2, records: [{ nativeSequence: 2 }, { nativeSequence: 5 }] } })
    await expect(request('GET', '/dsh-anywhere/v1/sessions/child/execution?parentSessionId=parent&subagentMode=one-shot&beforeSeq=2')).resolves.toMatchObject({ status: 200,
      body: { hasMore: false, beforeSeq: 0, records: [{ nativeSequence: 0 }] } })
    await expect(request('GET', '/dsh-anywhere/v1/sessions/child/execution?beforeSeq=-1')).resolves.toMatchObject({ status: 400 })
  })

  it('publishes workflow history and a complete catalog to the opening phone', async () => {
    const appended = vi.spyOn(ReplayBuffer.prototype, 'append')
    const events = [
      { seq: 0, type: 'turn/start', data: { turn: 1 } },
      { seq: 1, type: 'step/start', data: { turn: 1, step: 1 } },
      { seq: 2, time: 1_000, type: 'tool-workflow/run-start', data: { runId: 'run', name: 'Review' } },
      { seq: 3, type: 'tool-workflow/agent-start', data: { runId: 'run', seq: 1, label: 'Read source', phase: '', childId: 'member' } },
      { seq: 4, type: 'tool-workflow/agent-end', data: { runId: 'run', seq: 1, outcome: 'failed' } },
      { seq: 5, time: 5_000, type: 'tool-workflow/run-end', data: { runId: 'run', stopReason: 'completed' } },
    ]
    const request = mount({ inspect: async () => ({ events }), invoke: async (value) =>
      (value as { namespace: string }).namespace === 'subagents'
        ? { ok: true, value: { parentAvailable: false, entries: [{ kind: 'child', id: 'child', mode: 'one-shot', activity: 'inactive', hasChildren: false }] } }
        : { ok: true, value: undefined },
    })
    try {
      await expect(request('POST', '/dsh-anywhere/v1/sessions/child/open',
        { parentSessionId: 'parent', subagentMode: 'one-shot', deviceId: 'phone-workflow' })).resolves.toMatchObject({ status: 202 })
      const workflow = appended.mock.calls.map(([event]) => event).filter((event) => event.type === 'workflow.changed' && event.deviceId === 'phone-workflow')
      expect(workflow).toContainEqual(expect.objectContaining({ historyBatchId: expect.any(String),
        payload: expect.objectContaining({ sessionId: 'child', run: expect.objectContaining({ id: 'run', status: 'completed',
          members: [expect.objectContaining({ phase: '', childId: 'member', status: 'failed' })] }) }) }))
      expect(workflow.at(-1)).toMatchObject({ payload: { sessionId: 'child', inTranscript: false, run: { id: 'run', status: 'completed' } } })
    } finally { request.dispose(); appended.mockRestore() }
  })

  it('lists workspace files through the native session scope and requires authentication', async () => {
    const calls: unknown[] = []
    const request = mount({ invoke: async (value) => {
      calls.push(value)
      expect(value).toMatchObject({ namespace: 'workspaceFiles', method: 'list', args: { workspaceFileScopeId: 's', path: '项目' } })
      return { ok: true, value: { path: '项目', entries: [{ name: '图.png', type: 'file', size: 5 }, { name: 'src', type: 'directory' }], truncated: false } }
    } })
    await expect(request('GET', '/dsh-anywhere/v1/sessions/s/workspace/files?path=%E9%A1%B9%E7%9B%AE', undefined, undefined, 'Bearer wrong')).resolves.toMatchObject({ status: 401 })
    expect(calls).toHaveLength(0)
    await expect(request('GET', '/dsh-anywhere/v1/sessions/s/workspace/files?path=%E9%A1%B9%E7%9B%AE')).resolves.toMatchObject({ status: 200,
      body: { sessionId: 's', path: '项目', entries: [{ name: '图.png' }, { name: 'src' }], truncated: false } })
    expect(calls).toHaveLength(1)
  })
  it('translates the mobile root path to Native dot and maps thrown Host capability failures', async () => {
    const request = mount({ invoke: async (value) => {
      expect(value).toMatchObject({ namespace: 'workspaceFiles', method: 'list', args: { workspaceFileScopeId: 's', path: '.' } })
      return { path: '', entries: [], truncated: false }
    } })
    await expect(request('GET', '/dsh-anywhere/v1/sessions/s/workspace/files?path=')).resolves.toMatchObject({ status: 200, body: { path: '', entries: [] } })
    const unavailable = mount({ invoke: async () => { throw { code: 'gateway/namespace-not-found', message: 'No Native files capability' } } })
    await expect(unavailable('GET', '/dsh-anywhere/v1/sessions/s/workspace/files?path=')).resolves.toMatchObject({ status: 501 })
  })
  it('reads bounded original bytes and checks the native version after reading', async () => {
    const request = mount({ invoke: async (value) => {
      const call = value as { method: string }
      expect(value).toMatchObject({ namespace: 'workspaceFiles', args: { workspaceFileScopeId: 's', path: '图.png' } })
      if (call.method === 'readBytes') {
        expect(value).toMatchObject({ args: { range: { offset: 3, length: 3 } } })
        return { ok: true, value: { absolutePath: '/workspace/图.png', version: 'v1', bytes: 6, offset: 3, data: 'YWJj', eof: true } }
      }
      expect(call.method).toBe('stat')
      return { ok: true, value: { absolutePath: '/workspace/图.png', version: 'v1', bytes: 6 } }
    } })
    const path = '/dsh-anywhere/v1/sessions/s/workspace/bytes?path=%E5%9B%BE.png&offset=3&length=3&version=v1'
    await expect(request('GET', path)).resolves.toMatchObject({ status: 200, body: { sessionId: 's', offset: 3, data: 'YWJj', version: 'v1', eof: true } })
    await expect(request('GET', path.replace('version=v1', 'version=old'))).resolves.toMatchObject({ status: 409 })
    await expect(request('GET', path.replace('length=3', 'length=9999999'))).resolves.toMatchObject({ status: 400 })
  })
  it('rejects files that change while reading and preserves Host access failures', async () => {
    const request = mount({ invoke: async (value) => (value as { method: string }).method === 'readBytes'
      ? { ok: true, value: { absolutePath: '/workspace/a', version: 'v1', offset: 0, data: 'YQ==', eof: true } }
      : { ok: true, value: { absolutePath: '/workspace/a', version: 'v2' } } })
    await expect(request('GET', '/dsh-anywhere/v1/sessions/s/workspace/bytes?path=a&offset=0&length=3')).resolves.toMatchObject({ status: 409 })
    const denied = mount({ invoke: async () => ({ ok: false, error: { code: 'fs/denied', message: 'Host denied file access' } }) })
    await expect(denied('GET', '/dsh-anywhere/v1/sessions/s/workspace/bytes?path=/outside&offset=0&length=3')).resolves.toMatchObject({ status: 400, body: { error: 'Host denied file access' } })
    const old = mount({ invoke: async () => ({ ok: false, error: { code: 'gateway/namespace-not-found', message: 'No workspaceFiles service' } }) })
    await expect(old('GET', '/dsh-anywhere/v1/sessions/s/workspace/files?path=')).resolves.toMatchObject({ status: 501 })
  })

  it('uses the optional native attachment service when replaying a child record', async () => {
    const appended = vi.spyOn(ReplayBuffer.prototype, 'append')
    const request = mount({ attachmentStore: { fileHostPath: () => '/host/files/a.pdf' },
      inspect: async () => ({ events: [{ type: 'user/message', data: { id: 'u', source: { kind: 'user' }, content: [
        { type: 'file', attachment: { attachmentId: 'sha256:' + 'ab'.repeat(32), name: 'a.pdf', bytes: 3 } }] } }] }),
      invoke: async () => ({ ok: true, value: { parentAvailable: false, entries: [{ kind: 'child', id: 'child', mode: 'one-shot', activity: 'inactive', hasChildren: false }] } }),
    })
    try {
      await expect(request('POST', '/dsh-anywhere/v1/sessions/child/open', { parentSessionId: 'parent', subagentMode: 'one-shot', deviceId: 'phone' })).resolves.toMatchObject({ status: 202 })
      expect(appended.mock.calls.map(([event]) => event)).toContainEqual(expect.objectContaining({ deviceId: 'phone', type: 'user.message.accepted',
        payload: expect.objectContaining({ attachments: [expect.objectContaining({ name: 'a.pdf', hostPath: '/host/files/a.pdf' })] }) }))
    } finally { request.dispose(); appended.mockRestore() }
  })

  it('forks the native log at the exact boundary once across retries', async () => {
    let calls = 0
    const request = mount({ fork: async (value) => {
      expect(value).toEqual({ sessionId: 'parent', atSeq: 42 })
      calls += 1
      return { sessionId: 'child' }
    } })
    await expect(request('POST', '/dsh-anywhere/v1/sessions/parent/fork', { atSeq: 42 }, 'fork-1'))
      .resolves.toMatchObject({ status: 201, body: { sessionId: 'child' } })
    await expect(request('POST', '/dsh-anywhere/v1/sessions/parent/fork', { atSeq: 42 }, 'fork-1'))
      .resolves.toMatchObject({ status: 201, body: { sessionId: 'child' } })
    expect(calls).toBe(1)
  })
  it('reads a Native undefined goal as an empty baseline and creates through goals.create exactly once', async () => {
    let created = false, mutations = 0
    const goal = { id: 'native-goal', revision: 1, objective: 'Read on mobile', phase: 'active', maxGoalRounds: 7, roundsStarted: 0, activation: 'armed' }
    const request = mount({ invoke: async (value) => {
      const call = value as { method: string }
      if (call.method === 'get') return created ? goal : undefined
      expect(value).toMatchObject({ namespace: 'goals', method: 'create', args: { agentId: 's', request: { objective: 'Read on mobile', maxGoalRounds: 7 } } })
      expect((value as { args: Record<string, unknown> }).args).not.toHaveProperty('ref')
      created = true; mutations += 1
      return { ref: { id: goal.id, revision: goal.revision } }
    } })
    await expect(request('GET', '/dsh-anywhere/v1/sessions/s/goal')).resolves.toMatchObject({ status: 200, body: { goal: null, roundsStarted: 0 } })
    const body = { action: 'create', objective: goal.objective, maxGoalRounds: 7 }
    await expect(request('POST', '/dsh-anywhere/v1/sessions/s/goal', body, 'goal-create')).resolves.toMatchObject({ status: 202, body: { action: 'create', ref: { id: goal.id, revision: 1 } } })
    await expect(request('POST', '/dsh-anywhere/v1/sessions/s/goal', body, 'goal-create')).resolves.toMatchObject({ status: 202 })
    expect(mutations).toBe(1)
    await expect(request('POST', '/dsh-anywhere/v1/sessions/s/goal', body, 'new-create')).resolves.toMatchObject({ status: 409 })
    expect(mutations).toBe(1)
  })
  it('retains an unknown Native goal creation without creating it a second time', async () => {
    let mutations = 0
    const request = mount({ invoke: async (value) => {
      if ((value as { method: string }).method === 'get') return undefined
      mutations += 1; throw new Error('Native creation acknowledgement lost')
    } })
    const body = { action: 'create', objective: 'Keep original request' }
    await expect(request('POST', '/dsh-anywhere/v1/sessions/s/goal', body, 'unknown-create')).resolves.toMatchObject({ status: 503 })
    await expect(request('POST', '/dsh-anywhere/v1/sessions/s/goal', body, 'unknown-create')).resolves.toMatchObject({ status: 503 })
    expect(mutations).toBe(1)
  })
  it('edits the exact goal revision once and keeps the native edit request envelope', async () => {
    let mutations = 0
    const goal = { id: 'g', revision: 2, objective: 'Original', phase: 'active', maxGoalRounds: 12,
      roundsStarted: 3, activation: 'armed', createdAt: 1, updatedAt: 2 }
    const request = mount({ invoke: async (value) => {
      const call = value as { method: string }
      if (call.method === 'get') return { ok: true, value: goal }
      expect(value).toMatchObject({ namespace: 'goals', method: 'edit', args: { agentId: 's',
        ref: { id: 'g', revision: 2 }, request: { objective: 'Updated', maxGoalRounds: 18 } } })
      mutations += 1
      return { ok: true, value: { ...goal, revision: 3, objective: 'Updated', maxGoalRounds: 18 } }
    } })
    const body = { action: 'edit', ref: { id: 'g', revision: 2 }, objective: 'Updated', maxGoalRounds: 18 }
    await expect(request('POST', '/dsh-anywhere/v1/sessions/s/goal', body, 'goal-edit'))
      .resolves.toMatchObject({ status: 202, body: { sessionId: 's', requestId: 'goal-edit', action: 'edit', ref: { id: 'g', revision: 3 } } })
    await expect(request('POST', '/dsh-anywhere/v1/sessions/s/goal', body, 'goal-edit')).resolves.toMatchObject({ status: 202 })
    expect(mutations).toBe(1)
    await expect(request('GET', '/dsh-anywhere/v1/sessions/s/goal')).resolves.toMatchObject({ status: 200, body: {
      sessionId: 's', goal: { id: 'g', revision: 2 }, roundsStarted: 3, activation: 'armed' } })
  })
  it('rejects stale goal revisions before mutation and retains unknown native outcomes', async () => {
    let mutations = 0
    const goal = { id: 'g', revision: 2, objective: 'Original', phase: 'active', maxGoalRounds: 12, roundsStarted: 3, activation: 'armed' }
    const request = mount({ invoke: async (value) => {
      if ((value as { method: string }).method === 'get') return { ok: true, value: goal }
      mutations += 1
      throw new Error('lost native goal response')
    } })
    const path = '/dsh-anywhere/v1/sessions/s/goal'
    await expect(request('POST', path, { action: 'pause', ref: { id: 'g', revision: 1 } }, 'stale-goal')).resolves.toMatchObject({ status: 409 })
    expect(mutations).toBe(0)
    const body = { action: 'pause', ref: { id: 'g', revision: 2 } }
    await expect(request('POST', path, body, 'unknown-goal')).resolves.toMatchObject({ status: 503 })
    await expect(request('POST', path, body, 'unknown-goal')).resolves.toMatchObject({ status: 503 })
    expect(mutations).toBe(1)
  })
  it('edits the exact native queue occurrence once and preserves authored text', async () => {
    let calls = 0
    const request = mount({ updateQueue: async (value) => {
      expect(value).toEqual({ sessionId: 's', itemId: 'item-1', action: { kind: 'edit', content: [{ type: 'text', text: '  revised\ntext  ' }] } })
      calls += 1
      return { accepted: true }
    } })
    const body = { itemId: 'item-1', action: 'edit', text: '  revised\ntext  ' }
    await expect(request('POST', '/dsh-anywhere/v1/sessions/s/queue', body, 'queue-1')).resolves.toMatchObject({ status: 202 })
    await expect(request('POST', '/dsh-anywhere/v1/sessions/s/queue', body, 'queue-1')).resolves.toMatchObject({ status: 202 })
    expect(calls).toBe(1)
    await expect(request('POST', '/dsh-anywhere/v1/sessions/s/queue', { itemId: 'item-1', action: 'edit', text: '  ' }, 'bad-edit')).resolves.toMatchObject({ status: 400 })
  })

  it('does not retry a native fork whose result is uncertain', async () => {
    let calls = 0
    const request = mount({ fork: async () => { calls += 1; throw new Error('lost native response') } })
    await expect(request('POST', '/dsh-anywhere/v1/sessions/parent/fork', {}, 'fork-unknown'))
      .resolves.toMatchObject({ status: 503 })
    await expect(request('POST', '/dsh-anywhere/v1/sessions/parent/fork', {}, 'fork-unknown'))
      .resolves.toMatchObject({ status: 503 })
    expect(calls).toBe(1)
  })

  it('reports unsupported native fork instead of copying conversation text', async () => {
    await expect(mount()('POST', '/dsh-anywhere/v1/sessions/parent/fork', {}, 'fork-old'))
      .resolves.toMatchObject({ status: 501 })
  })

  it('reads the native session command directory including attachment declarations', async () => {
    const commands = [{ name: 'plan', description: 'Plan first', input: { hint: 'Task', attachments: true } },
      { name: 'custom', description: 'Plugin command' }]
    const request = mount({ invoke: async (value) => {
      expect(value).toMatchObject({ namespace: 'commands', method: 'list', args: { agentId: 's' } })
      return { ok: true, value: commands }
    } })
    await expect(request('GET', '/dsh-anywhere/v1/sessions/s/commands'))
      .resolves.toMatchObject({ status: 200, body: { sessionId: 's', commands } })
  })
  it('reads native child catalogs and validates the complete address before history', async () => {
    const catalog = { parentAvailable: false, entries: [{ kind: 'child', id: 'child', mode: 'one-shot',
      activity: 'inactive', hasChildren: false, label: 'Inspect source' }] }
    const request = mount({ invoke: async (value) => {
      const call = value as { namespace: string; args: unknown }
      if (call.namespace !== 'subagents') return {}
      expect(call.args).toEqual({ parentSessionId: 'parent' })
      return { ok: true, value: catalog }
    } })
    await expect(request('GET', '/dsh-anywhere/v1/sessions/parent/subagents'))
      .resolves.toMatchObject({ status: 200, body: { parentSessionId: 'parent', ...catalog } })
    await expect(request('POST', '/dsh-anywhere/v1/sessions/child/open',
      { parentSessionId: 'parent', subagentMode: 'one-shot' })).resolves.toMatchObject({ status: 202 })
    await expect(request('POST', '/dsh-anywhere/v1/sessions/child/open',
      { parentSessionId: 'parent', subagentMode: 'continuable' })).resolves.toMatchObject({ status: 403 })
    await expect(request('POST', '/dsh-anywhere/v1/sessions/not-owned/open',
      { parentSessionId: 'parent', subagentMode: 'one-shot' })).resolves.toMatchObject({ status: 403 })
  })

  it('delivers continuable messages once through the exact live parent address', async () => {
    let calls = 0
    const request = mount({ invoke: async (value) => {
      expect(value).toMatchObject({ namespace: 'subagents', method: 'prompt', args: { request: {
        requestId: 'child-prompt', parentSessionId: 'parent', childSessionId: 'child', mode: 'continuable',
        delivery: 'steer', content: [{ type: 'text', text: '  Continue\ncarefully  ' }], clientTimeZone: 'Asia/Shanghai' } } })
      calls += 1
      return { ok: true, value: { messageId: 'inbox-message' } }
    } })
    const body = { parentSessionId: 'parent', mode: 'continuable', delivery: 'steer', text: '  Continue\ncarefully  ', clientTimeZone: 'Asia/Shanghai' }
    const path = '/dsh-anywhere/v1/sessions/parent/subagents/child/prompt'
    await expect(request('POST', path, body, 'child-prompt')).resolves.toMatchObject({ status: 202, body: { accepted: true, messageId: 'inbox-message' } })
    await expect(request('POST', path, body, 'child-prompt')).resolves.toMatchObject({ status: 202 })
    expect(calls).toBe(1)
    await expect(request('POST', path, { ...body, parentSessionId: 'wrong' }, 'wrong-parent')).resolves.toMatchObject({ status: 400 })
    await expect(request('POST', path, { ...body, mode: 'one-shot' }, 'wrong-mode')).resolves.toMatchObject({ status: 400 })
    expect(calls).toBe(1)
  })

  it('keeps child image admission in the native parent transport and deduplicates the complete multipart request', async () => {
    const image = { type: 'image', mediaType: 'image/jpeg', name: 'photo.jpg', data: 'A'.repeat(1_100_000) }
    const invoke = vi.fn(async () => ({ ok: true, value: { messageId: 'image-inbox' } }))
    const request = mount({ invoke })
    const path = '/dsh-anywhere/v1/sessions/parent/subagents/child/prompt'
    const body = { parentSessionId: 'parent', mode: 'continuable', delivery: 'queue', text: '', images: [image] }
    await expect(request('POST', path, body, 'image-child')).resolves.toMatchObject({ status: 202 })
    await expect(request('POST', path, body, 'image-child')).resolves.toMatchObject({ status: 202 })
    expect(invoke).toHaveBeenCalledTimes(1)
    expect(invoke).toHaveBeenCalledWith(expect.objectContaining({ namespace: 'subagents', method: 'prompt', args: { request: {
      requestId: 'image-child', parentSessionId: 'parent', childSessionId: 'child', mode: 'continuable', delivery: 'queue', content: [image] } } }))
    await expect(request('POST', path, { ...body, text: '看图回答' }, 'image-and-text')).resolves.toMatchObject({ status: 202 })
    expect(invoke).toHaveBeenLastCalledWith(expect.objectContaining({ args: { request: expect.objectContaining({ content: [{ type: 'text', text: '看图回答' }, image] }) } }))
    await expect(request('POST', path, { ...body, images: [{ type: 'image', attachment: { attachmentId: 'forged' } }] }, 'forged-child')).resolves.toMatchObject({ status: 400 })
    expect(invoke).toHaveBeenCalledTimes(2)
  })

  it('interrupts by parent without requiring an available parent catalog', async () => {
    const request = mount({ invoke: async (value) => {
      expect(value).toMatchObject({ namespace: 'subagents', method: 'interruptByParent',
        args: { parentSessionId: 'offline-parent', childSessionId: 'child', mode: 'continuable' } })
      return { ok: true, value: { accepted: true } }
    } })
    await expect(request('POST', '/dsh-anywhere/v1/sessions/offline-parent/subagents/child/interrupt',
      { parentSessionId: 'offline-parent', mode: 'continuable' }, 'stop-child')).resolves.toMatchObject({ status: 202 })
  })

  it('retains uncertain subagent acceptance and handles explicit native rejection', async () => {
    let calls = 0
    const uncertain = mount({ invoke: async () => { calls += 1; throw new Error('lost response') } })
    const body = { parentSessionId: 'parent', mode: 'continuable', delivery: 'queue', text: 'continue' }
    const path = '/dsh-anywhere/v1/sessions/parent/subagents/child/prompt'
    await expect(uncertain('POST', path, body, 'uncertain-child')).resolves.toMatchObject({ status: 503 })
    await expect(uncertain('POST', path, body, 'uncertain-child')).resolves.toMatchObject({ status: 503 })
    expect(calls).toBe(1)
    const rejected = mount({ invoke: async () => ({ ok: false, error: { code: 'subagent/unauthorized', message: 'wrong parent' } }) })
    await expect(rejected('POST', path, body, 'unauthorized-child')).resolves.toMatchObject({ status: 409 })
  })

  it('does not treat a malformed command directory as an empty catalog', async () => {
    await expect(mount({ invoke: async () => ({ ok: true, value: [{}] }) })('GET', '/dsh-anywhere/v1/sessions/s/commands'))
      .resolves.toMatchObject({ status: 502 })
  })
  it('uses the native skill request envelope and keeps skill invocation policy', async () => {
    const skills = [{ name: 'review', description: 'Review code', modelInvocable: false }]
    const request = mount({ invoke: async (value) => {
      const call = value as { namespace: string; method: string; args: unknown }
      if (call.namespace === 'commands') return { ok: true, value: [] }
      expect(call).toMatchObject({ namespace: 'skills', method: 'list', args: { request: { sessionId: 's' } } })
      return { ok: true, value: { skills } }
    } })
    await expect(request('GET', '/dsh-anywhere/v1/sessions/s/commands'))
      .resolves.toMatchObject({ status: 200, body: { sessionId: 's', commands: [], skills } })
  })

  it('reads modes through a Host-created Peer on the new gateway', async () => {
    const peer = { signal: new AbortController().signal, dispose: async () => undefined }
    let calls = 0
    const request = mount({
      connection: { createPeer: () => peer },
      invoke: async (value) => {
        const call = value as { namespace: string; peer: typeof peer }
        expect(call.namespace).toBe('agentPresets')
        expect(call.peer).toBe(peer)
        expect(call.peer.signal.aborted).toBe(false)
        calls += 1
        return { presets: [{ id: 'standard', name: 'Standard', isDefault: true }] }
      },
    })
    await expect(request('GET', '/dsh-anywhere/v1/modes', undefined, undefined, 'Bearer invalid'))
      .resolves.toMatchObject({ status: 401 })
    expect(calls).toBe(0)
    await expect(request('GET', '/dsh-anywhere/v1/modes')).resolves.toMatchObject({
      status: 200, body: { defaultMode: 'standard', modes: [{ id: 'standard', name: 'Standard' }] },
    })
  })

  it('marks catalog failures retryable without claiming an unknown mutation', async () => {
    let headers: unknown
    const request = mount({
      invoke: async () => { throw new Error('native catalog failed') },
      responseHeaders: value => { headers = value },
    })
    await expect(request('GET', '/dsh-anywhere/v1/modes')).resolves.toMatchObject({ status: 500 })
    expect(headers).toMatchObject({ 'x-dsh-idempotency-outcome': 'retryable' })
  })

  it('creates a durable native workspace from the selected absolute host folder', async () => {
    const createWorkspace = async (path: string, title?: string) => ({ id: 'workspace-1', path, title: title ?? 'Code', sessionIds: [] })
    const request = mount({ createWorkspace })
    await expect(request('POST', '/dsh-anywhere/v1/workspaces', { path: '/Users/me/Code', title: 'Phone project' }))
      .resolves.toEqual({ status: 201, body: { workspace: { id: 'workspace-1', path: '/Users/me/Code', title: 'Phone project' } } })
  })

  it('replays a durable command result after the Bridge is restarted', async () => {
    const dataDir = mkdtempSync(join(tmpdir(), 'dsh-anywhere-command-recovery-'))
    let firstInvocations = 0
    const first = mount({
      dataDir,
      invoke: async (request) => {
        if ((request as { namespace?: string }).namespace === 'commands') firstInvocations += 1
        return { ok: true, value: { matched: true, result: { kind: 'text', text: 'done' } } }
      },
    })
    await expect(first(
      'POST', '/dsh-anywhere/v1/sessions/s1/command', { line: '/irreversible' }, 'command-recovery',
    )).resolves.toMatchObject({ status: 202 })
    expect(firstInvocations).toBe(1)

    let secondInvocations = 0
    const second = mount({
      dataDir,
      invoke: async (request) => {
        if ((request as { namespace?: string }).namespace === 'commands') secondInvocations += 1
        return { ok: true, value: { matched: true, result: { kind: 'text', text: 'duplicate' } } }
      },
    })
    await expect(second(
      'POST', '/dsh-anywhere/v1/sessions/s1/command', { line: '/irreversible' }, 'command-recovery',
    )).resolves.toMatchObject({ status: 202, body: { ok: true } })
    expect(secondInvocations).toBe(0)
  })

  it('replays a durable workspace result after the Bridge is restarted', async () => {
    const dataDir = mkdtempSync(join(tmpdir(), 'dsh-anywhere-workspace-recovery-'))
    let firstInvocations = 0
    const first = mount({
      dataDir,
      createWorkspace: async (path, title) => {
        firstInvocations += 1
        return { id: 'workspace-recovery', path, title: title ?? 'Code', sessionIds: [] }
      },
    })
    const body = { path: '/Users/me/Recovery', title: 'Recovery' }
    await expect(first('POST', '/dsh-anywhere/v1/workspaces', body, 'workspace-recovery'))
      .resolves.toMatchObject({ status: 201, body: { workspace: { id: 'workspace-recovery' } } })
    expect(firstInvocations).toBe(1)

    let secondInvocations = 0
    const second = mount({ dataDir })
    await expect(second('POST', '/dsh-anywhere/v1/workspaces', body, 'workspace-recovery'))
      .resolves.toMatchObject({ status: 201, body: { workspace: { id: 'workspace-recovery' } } })
    expect(secondInvocations).toBe(0)
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

  it('compacts only explicitly completed session-create tombstones', async () => {
    const dataDir = mkdtempSync(join(tmpdir(), 'dsh-anywhere-bridge-session-compact-'))
    let creates = 0
    const request = mount({
      dataDir,
      create: async () => ({ sessionId: `session-${++creates}` }),
    })
    await expect(request(
      'POST', '/dsh-anywhere/v1/sessions', { cwd: '/Users/me/Code' }, 'compact-me',
    )).resolves.toMatchObject({ status: 201, body: { sessionId: 'session-1' } })
    const key = `${CONNECTOR_DEVICE_ID}\u0000compact-me`
    await expect(request(
      'POST', '/dsh-anywhere/v1/admin/session-creations/compact', { keys: [key] },
    )).resolves.toEqual({ status: 200, body: { removed: 1 } })
    const restartedRequest = mount({
      dataDir,
      create: async () => ({ sessionId: `session-${++creates}` }),
    })
    await expect(restartedRequest(
      'POST', '/dsh-anywhere/v1/sessions', { cwd: '/Users/me/Code' }, 'compact-me',
    )).resolves.toMatchObject({ status: 201, body: { sessionId: 'session-2' } })
    expect(creates).toBe(2)
  })

  it('lists and explicitly reconciles unknown remote mutation tombstones', async () => {
    const dataDir = mkdtempSync(join(tmpdir(), 'dsh-anywhere-bridge-remote-reconcile-'))
    const key = `${CONNECTOR_DEVICE_ID}\u0000/sessions/s1/command\u0000unknown-command`
    await writeFile(join(dataDir, 'session-metadata.json'), JSON.stringify({
      remoteMutations: { [key]: { pending: true, createdAt: 1 } },
    }))
    const request = mount({ dataDir })
    await expect(request('GET', '/dsh-anywhere/v1/admin/remote-mutations/pending?limit=1'))
      .resolves.toEqual({ status: 200, body: { items: [{ key, createdAt: 1 }] } })
    await expect(request('POST', '/dsh-anywhere/v1/admin/remote-mutations/reconcile', {
      keys: [key], kind: 'not-committed', confirm: true,
    })).resolves.toEqual({ status: 200, body: { resolved: 1, kind: 'not-committed' } })
    await expect(request('GET', '/dsh-anywhere/v1/admin/remote-mutations/pending'))
      .resolves.toEqual({ status: 200, body: { items: [] } })
  })

  it('invalidates a cached unknown mutation response after reconciliation', async () => {
    const dataDir = mkdtempSync(join(tmpdir(), 'dsh-anywhere-bridge-reconcile-cache-'))
    const requestId = 'cached-unknown-command'
    const key = `${CONNECTOR_DEVICE_ID}\u0000/sessions/s1/command\u0000${requestId}`
    await writeFile(join(dataDir, 'session-metadata.json'), JSON.stringify({
      remoteMutations: { [key]: { pending: true, createdAt: 1 } },
    }))
    let invocations = 0
    const request = mount({
      dataDir,
      invoke: async () => {
        invocations += 1
        return { ok: true, value: { matched: true, result: { kind: 'text', text: 'replayed' } } }
      },
    })
    await expect(request('POST', '/dsh-anywhere/v1/sessions/s1/command', { line: 'status' }, requestId))
      .resolves.toMatchObject({ status: 503 })
    await expect(request('POST', '/dsh-anywhere/v1/admin/remote-mutations/reconcile', {
      keys: [key], kind: 'not-committed', confirm: true,
    })).resolves.toMatchObject({ status: 200 })
    await expect(request('POST', '/dsh-anywhere/v1/sessions/s1/command', { line: 'status' }, requestId))
      .resolves.toMatchObject({ status: 202 })
    expect(invocations).toBe(1)
  })

  it('accepts remote mutation admin keys containing a maximum encoded session id', async () => {
    const dataDir = mkdtempSync(join(tmpdir(), 'dsh-anywhere-bridge-long-mutation-key-'))
    const sessionId = '界'.repeat(256)
    const path = `/sessions/${encodeURIComponent(sessionId)}/command`
    const key = `${CONNECTOR_DEVICE_ID}\u0000${path}\u0000long-key`
    expect(key.length).toBeGreaterThan(1_024)
    await writeFile(join(dataDir, 'session-metadata.json'), JSON.stringify({
      remoteMutations: { [key]: { pending: true, createdAt: 1 } },
    }))
    const request = mount({ dataDir })
    await expect(request('GET', '/dsh-anywhere/v1/admin/remote-mutations/pending'))
      .resolves.toMatchObject({ status: 200, body: { items: [{ key }] } })
    await expect(request('POST', '/dsh-anywhere/v1/admin/remote-mutations/reconcile', {
      keys: [key], kind: 'not-committed', confirm: true,
    })).resolves.toMatchObject({ status: 200, body: { resolved: 1 } })
  })

  it('does not partially compact a mixed session-create batch', async () => {
    const dataDir = mkdtempSync(join(tmpdir(), 'dsh-anywhere-bridge-compact-atomic-'))
    const completedKey = `${CONNECTOR_DEVICE_ID}\u0000completed-create`
    const pendingKey = `${CONNECTOR_DEVICE_ID}\u0000pending-create`
    await writeFile(join(dataDir, 'session-metadata.json'), JSON.stringify({
      sessionCreations: {
        [completedKey]: {
          schemaVersion: 1,
          sessionId: 'session-kept',
          response: { sessionId: 'session-kept' },
          setup: {}, setupComplete: true, completedAt: 1,
        },
        [pendingKey]: { schemaVersion: 1, pending: true, setup: {}, setupComplete: false },
      },
    }))
    const request = mount({ dataDir })
    await expect(request('POST', '/dsh-anywhere/v1/admin/session-creations/compact', {
      keys: [completedKey, pendingKey],
    })).resolves.toMatchObject({ status: 409 })
    await expect(request('POST', '/dsh-anywhere/v1/sessions', { cwd: '/Users/me/Code' }, 'completed-create'))
      .resolves.toMatchObject({ status: 200, body: { sessionId: 'session-kept' } })
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

  it('ages unknown pending uploads into permanent tombstones without exhausting active capacity', async () => {
    const dataDir = mkdtempSync(join(tmpdir(), 'dsh-anywhere-attachment-expired-'))
    const requestId = 'attachment-expired'
    const key = `${CONNECTOR_DEVICE_ID}\u0000s1\u0000${requestId}`
    const nativeOperationId = createHash('sha256')
      .update(`attachment\0${key}`).digest('hex')
    await writeFile(join(dataDir, 'session-metadata.json'), JSON.stringify({
      attachmentUploads: {
        [key]: {
          pending: true,
          nativeOperationId,
          createdAt: Date.now() - (31 * 24 * 60 * 60_000),
        },
      },
    }))
    let uploads = 0
    const request = mount({
      dataDir,
      invoke: async () => {
        uploads += 1
        return { ok: true, value: { receiptId: `receipt-${uploads}`, file: { size: 3 } } }
      },
    })
    await expect(request(
      'POST', '/dsh-anywhere/v1/sessions/s1/attachments',
      { name: 'a.txt', data: 'YWJj' }, requestId,
    )).resolves.toMatchObject({ status: 409 })
    expect(uploads).toBe(0)

    await expect(request(
      'POST', '/dsh-anywhere/v1/sessions/s1/attachments',
      { name: 'b.txt', data: 'YWJj' }, 'attachment-after-expired',
    )).resolves.toMatchObject({ status: 201 })
    expect(uploads).toBe(1)
  })

  it('reconciles expired attachment tombstones through the Connector admin route', async () => {
    const dataDir = mkdtempSync(join(tmpdir(), 'dsh-anywhere-attachment-admin-reconcile-'))
    const requestId = 'attachment-admin-reconcile'
    const key = `${CONNECTOR_DEVICE_ID}\u0000s1\u0000${requestId}`
    const nativeOperationId = createHash('sha256')
      .update(`attachment\0${key}`).digest('hex')
    await writeFile(join(dataDir, 'session-metadata.json'), JSON.stringify({
      attachmentUploads: {
        [key]: {
          fingerprint: 'a'.repeat(64), name: 'a.txt', nativeOperationId,
          expired: true, expiredAt: Date.now(),
        },
      },
    }))
    const request = mount({
      dataDir,
      findAttachmentByRequestId: async (operationId) => {
        expect(operationId).toBe(nativeOperationId)
        return { receiptId: 'receipt-admin', file: { size: 3 } }
      },
    })
    await expect(request('POST', '/dsh-anywhere/v1/admin/attachments/reconcile', { limit: 1 }))
      .resolves.toEqual({ status: 200, body: { scanned: 1, found: 1, notCommitted: 0, unknown: 0 } })
    await expect(request(
      'POST', '/dsh-anywhere/v1/sessions/s1/attachments',
      { name: 'a.txt', data: 'YWJj' }, requestId,
    )).resolves.toMatchObject({ status: 201, body: { receiptId: 'receipt-admin' } })
  })

  it('does not count reconciled expired receipts against active capacity after restart', async () => {
    const dataDir = mkdtempSync(join(tmpdir(), 'dsh-anywhere-attachment-reconciled-cap-'))
    const uploads: Record<string, Record<string, unknown>> = {}
    for (let index = 0; index < 8192; index += 1) {
      const key = `${CONNECTOR_DEVICE_ID}\u0000s1\u0000active-${index}`
      uploads[key] = { response: { receiptId: `receipt-${index}` } }
    }
    const requestId = 'attachment-reconciled-cap'
    const key = `${CONNECTOR_DEVICE_ID}\u0000s1\u0000${requestId}`
    uploads[key] = {
      expired: true,
      reconciled: true,
      response: { receiptId: 'receipt-reconciled' },
    }
    await writeFile(join(dataDir, 'session-metadata.json'), JSON.stringify({ attachmentUploads: uploads }))
    let uploadsInvoked = 0
    const request = mount({
      dataDir,
      invoke: async () => {
        uploadsInvoked += 1
        return { ok: true, value: { receiptId: 'duplicate' } }
      },
    })
    await expect(request(
      'POST', '/dsh-anywhere/v1/sessions/s1/attachments',
      { name: 'a.txt', data: 'YWJj' }, requestId,
    )).resolves.toMatchObject({ status: 201, body: { receiptId: 'receipt-reconciled' } })
    expect(uploadsInvoked).toBe(0)
  })

  it('round-robins bounded attachment reconciliation so unknown tombstones do not starve later records', async () => {
    const dataDir = mkdtempSync(join(tmpdir(), 'dsh-anywhere-attachment-admin-cursor-'))
    const uploads: Record<string, Record<string, unknown>> = {}
    const operationIndexes = new Map<string, number>()
    for (let index = 0; index < 129; index += 1) {
      const key = `${CONNECTOR_DEVICE_ID}\u0000s1\u0000attachment-cursor-${index}`
      const nativeOperationId = createHash('sha256')
        .update(`attachment\0${key}`).digest('hex')
      operationIndexes.set(nativeOperationId, index)
      uploads[key] = {
        name: `file-${index}.txt`, nativeOperationId,
        expired: true, expiredAt: Date.now(),
      }
    }
    await writeFile(join(dataDir, 'session-metadata.json'), JSON.stringify({ attachmentUploads: uploads }))
    const request = mount({
      dataDir,
      findAttachmentByRequestId: async (operationId) => {
        // The first 128 entries remain unknown. The final entry is
        // recoverable and must be reached on the next bounded pass.
        return operationIndexes.get(operationId) === 128
          ? { receiptId: 'receipt-after-cursor', file: { size: 3 } }
          : { state: 'unknown' }
      },
    })
    const first = await request('POST', '/dsh-anywhere/v1/admin/attachments/reconcile', { limit: 128 })
    expect(first).toMatchObject({
      status: 200,
      body: { scanned: 128, found: 0, notCommitted: 0, unknown: 128 },
    })
    expect((first.body as { nextCursor?: string }).nextCursor).toBeTruthy()

    await expect(request('POST', '/dsh-anywhere/v1/admin/attachments/reconcile', { limit: 128 }))
      .resolves.toMatchObject({
        status: 200,
        body: { scanned: 128, found: 1, notCommitted: 0 },
      })
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
