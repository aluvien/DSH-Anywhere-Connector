import { describe, expect, it } from 'vitest'
import { EventEnvelopeSchema } from '@dsh-anywhere/protocol'
import { normalizeSessionEvents } from './index.js'
import { historyWindow, projectHistoryPage } from './history.js'

const event = (seq: number, type: string, data: Record<string, unknown>) => ({ seq, type, time: seq * 1000, data })
const page = (events: unknown[], hasMore: boolean) => ({ records: events.map((event) => ({ type: 'event', event })), hasMore })
const normalize = (value: unknown, names: Map<string, string>) => normalizeSessionEvents('s', value, names)
describe('native transcript pages', () => {
  it('keeps full reasoning and message blocks, positions and interruption without replaying live state', () => {
    const text = '完整回答'.repeat(30_000), reasoning = '思考'.repeat(30_000)
    const events = [event(0, 'request/header', { header: { config: { model: 'm' } } }),
      event(1, 'plan/mode', { mode: 'plan' }), event(2, 'assistant/message', { interrupted: true,
        message: { id: 'answer', content: [{ type: 'reasoning', text: reasoning }, { type: 'text', text }] } })]
    const result = projectHistoryPage('s', events, page(events.slice(1), true), 2, undefined, normalize, 2)
    expect(result).toMatchObject({ fromSeq: 1, toSeq: 2, throughSeq: 2, hasMore: true })
    expect(result.rows.map((row) => row.type)).toEqual(['assistant.reasoning', 'assistant.message.completed'])
    expect(result.rows[0]!.payload.text).toBe(reasoning)
    expect(result.rows[1]!.payload).toMatchObject({ markdown: text, interrupted: true, nativeSequence: 2 })
    for (const row of result.rows) expect(EventEnvelopeSchema.safeParse({ version: 1, messageId: 'r', machineId: 'm', deviceId: 'd', sessionId: 's', sequence: 1, timestamp: row.time, type: row.type, payload: row.payload }).success).toBe(true)
    expect(result.focus?.data.interrupted).toBe(true)
  })
  it('restores a cut tool call from its prefix without rereading old attachments', () => {
    const events = [event(0, 'tool/call', { callId: 'c', name: 'read', arguments: '{"path":"x"}' }),
      event(1, 'tool/result', { message: { content: [{ type: 'tool-result', toolCallId: 'c', content: [{ type: 'text', text: 'full output' }], isError: false }] } })]
    const result = projectHistoryPage('s', events, page(events.slice(1), true), 1, undefined, normalize)
    expect(result.rows[0]).toMatchObject({ nativeSequence: 1, type: 'tool.completed', payload: { name: 'read', arguments: '{"path":"x"}', startedAt: 0, finishedAt: 1000 } })
    expect(EventEnvelopeSchema.safeParse({ version: 1, messageId: 'r', machineId: 'm', deviceId: 'd', sessionId: 's', sequence: 1, timestamp: 1000, type: result.rows[0]!.type, payload: result.rows[0]!.payload }).success).toBe(true)
  })
  it('rejects holes, false continuation, truncated targets and incomplete empty pages', () => {
    const events = [event(0, 'turn/start', { turn: 1 }), event(1, 'step/start', { turn: 1, step: 1 }), event(2, 'turn/end', { turn: 1 })]
    expect(() => projectHistoryPage('s', events, page([events[0], events[2]], false), 2, undefined, normalize)).toThrow('contiguous')
    expect(() => projectHistoryPage('s', events, page(events.slice(1), false), 2, undefined, normalize)).toThrow('continuation')
    expect(() => projectHistoryPage('s', events, page(events.slice(1), true), 2, undefined, normalize, 0)).toThrow('target')
    expect(() => projectHistoryPage('s', events, page([], false), 2, undefined, normalize)).toThrow('empty')
    expect(projectHistoryPage('s', [], page([], false), -1, undefined, normalize)).toMatchObject({ fromSeq: 0, toSeq: -1, rows: [], hasMore: false })
  })
  it('retains the native snapshot cut and sanitizes focused request headers', () => {
    const events = [event(0, 'request/header', { header: { config: { provider: 'p', model: 'm', apiKey: 'do-not-copy', extraBody: { secret: 'hidden' } } } }), event(1, 'turn/start', { turn: 1 })]
    const result = projectHistoryPage('s', events, page(events.slice(0, 1), false), 1, 1, normalize, 0)
    expect(JSON.stringify(result)).not.toContain('do-not-copy')
    expect(JSON.stringify(result)).not.toContain('hidden')
    expect(result).toMatchObject({ throughSeq: 1, fromSeq: 0, toSeq: 0, focus: { nativeSequence: 0 } })
    expect(historyWindow('s', events, 1)).toEqual({ sessionId: 's', throughSeq: 1, fromSeq: 1, toSeq: 1, hasMore: true })
    expect(historyWindow('s', [], 0)).toEqual({ sessionId: 's', throughSeq: -1, fromSeq: 0, toSeq: -1, hasMore: false })
  })
})
