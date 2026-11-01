import { describe, expect, it } from 'vitest'
import { executionRecord, executionPage, executionLifecycle, executionPrefix } from './execution.js'

const event = (seq: number, type: string, data: Record<string, unknown>) => ({ seq, time: seq * 1_000, type, data })
describe('durable execution records', () => {
  it('counts only child-owned complete turns and excludes inherited work and idle gaps', () => {
    const events = [event(0, 'turn/start', { turn: 0 }), event(1, 'turn/end', { turn: 0, reason: { kind: 'completed' } }),
      { ...event(2, 'turn/start', { turn: 1 }), time: 10000 }, { ...event(3, 'assistant/message', {}), time: 11000 },
      { ...event(4, 'tool/call', {}), time: 12000 }, { ...event(5, 'turn/end', { turn: 1, reason: { kind: 'error', error: 'private' } }), time: 13000 },
      { ...event(6, 'turn/start', { turn: 2 }), time: 100000 }, { ...event(7, 'turn/end', { turn: 2, reason: { kind: 'completed' } }), time: 102000 },
      { ...event(8, 'turn/start', { turn: 3 }), time: 200000 }]
    expect(executionLifecycle({ meta: { createdAt: 9000 }, inheritedEventCount: 2, events })).toEqual({
      createdAt: 9000, inheritedEventCount: 2, throughSeq: 8, ownEventCount: 7, turnsStarted: 3, turnsEnded: 2,
      measuredTurns: 2, endedTurnMilliseconds: 5000, timingIncomplete: false, assistantMessages: 1, toolCalls: 1,
      lastActivityAt: 200000, lastEndKind: 'completed', openTurn: { turn: 3, startedAt: 200000 },
    })
  })
  it('does not adopt a parent open turn or invent timing for missing starts, invalid clocks or lost ends', () => {
    const events = [event(0, 'turn/start', { turn: 0 }), event(1, 'turn/end', { turn: 0, reason: { kind: 'completed' } }),
      event(2, 'turn/start', { turn: 1 }), { ...event(3, 'turn/end', { turn: 1, reason: { kind: 'aborted' } }), time: 1000 },
      event(4, 'turn/start', { turn: 2 }), event(5, 'turn/start', { turn: 3 }), { ...event(6, 'turn/end', { turn: 3, reason: { kind: 'custom-private-reason' } }), time: undefined }]
    expect(executionLifecycle({ meta: { createdAt: 1000 }, inheritedEventCount: 1, events })).toMatchObject({
      turnsStarted: 3, turnsEnded: 2, measuredTurns: 0, endedTurnMilliseconds: 0, timingIncomplete: true, lastEndKind: 'unknown',
    })
  })
  it('requires real header metadata and exact inherited boundaries from a complete Native inspection', () => {
    const events = [event(0, 'turn/start', { turn: 0 })]
    for (const inspection of [{ events }, { meta: { createdAt: 0 }, events }, { meta: { createdAt: 0 }, inheritedEventCount: 2, events },
      { meta: { createdAt: 0 }, inheritedEventCount: 0, events: [event(1, 'turn/start', { turn: 0 })] }]) expect(executionLifecycle(inspection)).toBeUndefined()
    expect(executionLifecycle({ meta: { createdAt: 0 }, inheritedEventCount: 1, events })).toMatchObject({ ownEventCount: 0, turnsStarted: 0, turnsEnded: 0, endedTurnMilliseconds: 0 })
    expect(executionLifecycle({ meta: { createdAt: 0 }, inheritedEventCount: 0, events: [] })).toMatchObject({ throughSeq: -1, ownEventCount: 0 })
  })
  it('preserves nested PTC subcall evidence without fabricating turn or step ownership', () => {
    const data = { rootCallId: 'r', parentCallId: 'p', subCallId: 'c', name: 'read', arguments: { path: 'x' },
      isError: true, content: [{ type: 'text', text: 'aborted' }] }
    expect(executionRecord(event(7, 'tool/ptc-dispatch', data)))
      .toEqual({ nativeSequence: 7, time: 7_000, type: 'tool/ptc-dispatch', data })
  })
  it('keeps noncommitted attempts distinct and preserves exact packed stream timing', () => {
    const stream = [{ type: 'reasoning-chunks', index: 0, time0: 1020, dt: [40], texts: ['One', 'Two'] },
      { type: 'chunk', time: 1090, chunk: { type: 'finish', reason: { kind: 'error', failure: { message: 'Retry', code: 'THROTTLED' } } } }]
    expect(executionRecord(event(2, 'assistant/attempt', { turn: 1, step: 2, stream }))).toEqual({
      nativeSequence: 2, time: 2_000, type: 'assistant/attempt', data: { turn: 1, step: 2, stream } })
    expect(executionRecord(event(3, 'assistant/message', { turn: 1, step: 2, message: { id: 'a', content: [] }, stream, interrupted: true })))
      .toMatchObject({ type: 'assistant/message', data: { interrupted: true, message: { id: 'a' } } })
  })
  it('separates compaction output, its explicit end, and applied replacement evidence', () => {
    const summary = executionRecord(event(3, 'compaction/summary', { compactionId: 'c', summary: [{ type: 'text', text: 'Summary' }],
      shadowedSeqs: [12, 4], shadowedRange: { start: 12, end: 4 }, shadowedTokenCount: 100, rawOutput: [], provider: 'p', model: 'm' }))
    expect(summary?.data).toMatchObject({ shadowedRange: { start: 12, end: 4 }, shadowedSeqs: [12, 4] })
    expect(executionRecord(event(4, 'user/message', { source: { kind: 'plugin', plugin: 'compact', compactionId: 'c', sourceCommandId: 'manual' }, content: [] })))
      .toMatchObject({ type: 'compaction/checkpoint', data: { compactionId: 'c', sourceCommandId: 'manual' } })
    expect(executionRecord(event(5, 'compaction/end', { compactionId: 'c', turn: null, error: 'Failed' })))
      .toMatchObject({ data: { turn: null, error: 'Failed' } })
    expect(executionRecord(event(6, 'user/message', { source: { kind: 'user' }, content: [] }))).toBeUndefined()
  })
  it('allows only known call configuration fields in request headers', () => {
    expect(executionRecord(event(1, 'request/header', { header: { config: { provider: 'p', model: 'm', reasoningEffort: 'high',
      apiKey: 'secret', headers: { authorization: 'secret' }, extraBody: { password: 'secret' } }, tools: [{ name: 'read', parameters: {} }] }, reason: 'change' }))?.data)
      .toEqual({ header: { config: { provider: 'p', model: 'm', reasoningEffort: 'high' }, tools: [{ name: 'read', parameters: {} }] }, reason: 'change' })
    expect(executionRecord({ type: 'turn/start', seq: -1, data: { turn: 1 } })).toBeUndefined()
  })
  it('uses exclusive native cursors, including seq zero, without losing appended records', () => {
    const events = [event(0, 'turn/start', { turn: 1 }), event(1, 'step/start', { turn: 1, step: 1 }),
      event(2, 'tool/call', { turn: 1, step: 1, callId: 'call', name: 'read', arguments: '{}' }), event(4, 'step/end', { turn: 1, step: 1 }), event(5, 'turn/end', { turn: 1, reason: { kind: 'completed' } })]
    const latest = executionPage('s', events, undefined, 2)
    expect(latest.records.map((record) => record.nativeSequence)).toEqual([4, 5])
    expect(latest.hasMore).toBe(true)
    const previous = executionPage('s', [...events, event(6, 'turn/start', { turn: 2 })], latest.beforeSeq, 3)
    expect(previous.records.map((record) => record.nativeSequence)).toEqual([0, 1, 2])
    expect(previous.hasMore).toBe(false)
    expect(executionPage('s', events, 0).records).toEqual([])
  })
  it('restores a cut retry owner and compaction chain without unrelated old steps', () => {
    const events = [event(0, 'turn/start', { turn: 1 }), event(1, 'step/start', { turn: 1, step: 1 }), event(2, 'step/end', { turn: 1, step: 1 }),
      event(3, 'turn/end', { turn: 1, reason: { kind: 'completed' } }), event(4, 'request/header', { header: { config: { model: 'm' } } }),
      event(5, 'turn/start', { turn: 2 }), event(6, 'step/start', { turn: 2, step: 1 }),
      event(7, 'llm/retry', { retryId: 'r', turn: 2, step: 1, retry: 1 }), event(8, 'compaction/start', { compactionId: 'c', turn: null }),
      event(9, 'llm/retry-started', { retryId: 'r', turn: 2, step: 1, retry: 1 }), event(10, 'compaction/end', { compactionId: 'c', turn: null })]
    expect(executionPrefix(events, 9).map((record) => record.nativeSequence)).toEqual([4, 5, 6, 7, 8])
  })
  it('keeps an open owner when only a context record follows the cut and bounds pages without truncating a record', () => {
    const events = [event(0, 'turn/start', { turn: 1 }), event(1, 'step/start', { turn: 1, step: 2 }),
      event(2, 'compaction/start', { compactionId: 'c', turn: null }), event(3, 'request/context', { model: 'm' })]
    expect(executionPrefix(events, 3).map((record) => record.nativeSequence)).toEqual([0, 1, 2])
    const large = 'a'.repeat(700_000)
    const page = executionPage('s', [event(0, 'assistant/attempt', { stream: [], text: 'ignored' }),
      event(1, 'compaction/summary', { compactionId: 'a', summary: [{ type: 'text', text: large }] }),
      event(2, 'compaction/summary', { compactionId: 'b', summary: [{ type: 'text', text: large }] })], undefined, 100)
    expect(page.records.map((record) => record.nativeSequence)).toEqual([2])
    expect(page.records[0]?.data.summary).toEqual([{ type: 'text', text: large }])
    expect(page.hasMore).toBe(true)
  })
})
