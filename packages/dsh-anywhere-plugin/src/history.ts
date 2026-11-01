import { HistoryFocusSchema, HistoryPageSchema, HistoryRowSchema, HistoryWindowSchema } from '@dsh-anywhere/protocol'
import { executionRecord, executionPrefix } from './execution.js'
import { workflowHistory } from './workflows.js'

const object = (value: unknown): Record<string, unknown> => value !== null && typeof value === 'object' && !Array.isArray(value) ? value as Record<string, unknown> : {}
type Projection = { type: string; payload: unknown }
type Row = ReturnType<typeof HistoryRowSchema.parse>
const transcriptTypes = new Set(['user.message.accepted', 'assistant.message.completed', 'assistant.reasoning', 'tool.started', 'tool.completed', 'command.result', 'session.model.changed'])
const processTypes = new Set(['turn/start', 'turn/end', 'step/start', 'step/end', 'llm/retry', 'llm/retry-started', 'compaction/start', 'compaction/summary', 'compaction/end', 'compaction/prune', 'compaction/checkpoint'])

export function historyWindow(sessionId: string, events: readonly unknown[], start: number) {
  const throughSeq = object(events.at(-1)).seq ?? -1, fromSeq = object(events[start]).seq ?? 0
  const parsed = HistoryWindowSchema.safeParse({ sessionId, throughSeq, fromSeq, toSeq: throughSeq, hasMore: Number(fromSeq) > 0 })
  return parsed.success ? parsed.data : undefined
}

/** Native page cuts stay intact. No result block or reasoning string is
 * sliced to fit transport; callers can ask the Host for a smaller message page. */
export function projectHistoryPage(sessionId: string, inspected: readonly unknown[], nativePage: unknown,
  throughSeq: number, beforeSeq: number | undefined,
  normalize: (event: unknown, names: Map<string, string>) => readonly Projection[], atSeq?: number) {
  const page = object(nativePage)
  if (!Array.isArray(page.records) || typeof page.hasMore !== 'boolean') throw new Error('Harness returned an invalid history page')
  const events = page.records.map((entry) => {
    const record = object(entry)
    if (record.type !== 'event') throw new Error('Harness returned a non-event history record')
    return object(record.event)
  })
  const end = Math.min(throughSeq + 1, beforeSeq ?? throughSeq + 1)
  let previous: number | undefined
  for (const event of events) {
    const seq = event.seq
    if (typeof seq !== 'number' || !Number.isSafeInteger(seq) || seq < 0 || seq >= end ||
        (previous !== undefined && seq !== previous + 1)) throw new Error('Harness history page is not a contiguous native range')
    previous = seq
  }
  if (events.length > 0 && events.at(-1)!.seq !== end - 1) throw new Error('Harness history page does not reach its requested cut')
  if (events.length === 0 && (end !== 0 || page.hasMore)) throw new Error('Harness returned an incomplete empty history page')
  const first = events[0]?.seq as number | undefined
  if (page.hasMore !== (first !== undefined && first > 0)) throw new Error('Harness history continuation disagrees with its range')
  const fromSeq = first ?? 0, toSeq = (events.at(-1)?.seq ?? -1) as number
  const rows: Row[] = [], names = new Map<string, string>()
  const calls = new Map<string, { arguments: string; startedAt?: number }>()
  const append = (type: Row['type'], payload: unknown, seq: number, time?: unknown) => {
    rows.push(HistoryRowSchema.parse({ type, payload, nativeSequence: seq, ...(time === undefined ? {} : { time }) }))
  }
  // Only call identities and route context are needed before the page. Do
  // not decode/read every old attachment merely to recover a tool's title.
  for (const value of inspected) {
    const event = object(value), seq = Number(event.seq)
    if (seq >= fromSeq) break
    const data = object(event.data)
    if (event.type === 'tool/call' && typeof data.callId === 'string') {
      names.set(data.callId, typeof data.name === 'string' ? data.name : 'tool')
      calls.set(data.callId, { arguments: typeof data.arguments === 'string' ? data.arguments : '', ...(typeof event.time === 'number' ? { startedAt: event.time } : {}) })
    } else if (event.type === 'tool/result') {
      const content = object(data.message).content
      const result = object(Array.isArray(content) ? content[0] : undefined)
      if (typeof result.toolCallId === 'string') { names.delete(result.toolCallId); calls.delete(result.toolCallId) }
    } else if (['command/run', 'request/header', 'request/context', 'epoch/start'].includes(String(event.type))) {
      normalize(value, names)
    }
  }
  const prefix = inspected.filter((value) => Number(object(value).seq) <= toSeq)
  const indexes = new Map(prefix.map((value, index) => [object(value).seq, index]))
  const start = indexes.get(fromSeq) ?? prefix.length
  const workflow = workflowHistory(prefix, start)
  for (const entry of workflow.before) append('workflow.changed', { ...entry, sessionId }, fromSeq)
  for (const record of executionPrefix(prefix, start)) {
    if (processTypes.has(record.type)) append('execution.recorded', { sessionId, record, inTranscript: false }, record.nativeSequence, record.time)
  }
  for (const event of events) {
    const seq = Number(event.seq), data = object(event.data)
    if (event.type === 'tool/call' && typeof data.callId === 'string') calls.set(data.callId, {
      arguments: typeof data.arguments === 'string' ? data.arguments : '', ...(typeof event.time === 'number' ? { startedAt: event.time } : {}) })
    for (const projected of normalize(event, names)) {
      if (!transcriptTypes.has(projected.type)) continue
      const payload = object(projected.payload)
      const call = projected.type === 'tool.completed' && typeof payload.id === 'string' ? calls.get(payload.id) : undefined
      append(projected.type as Row['type'], call === undefined ? payload : { ...payload, arguments: call.arguments,
        ...(call.startedAt === undefined ? {} : { startedAt: call.startedAt }) }, seq, event.time)
      if (projected.type === 'tool.completed' && typeof payload.id === 'string') calls.delete(payload.id)
    }
    const index = indexes.get(seq) ?? -1
    for (const entry of workflow.byIndex.get(index) ?? []) append('workflow.changed', { ...entry, sessionId }, seq, event.time)
    const record = executionRecord(event)
    if (record !== undefined && processTypes.has(record.type)) append('execution.recorded', { sessionId, record }, seq, event.time)
  }
  let focus
  if (atSeq !== undefined) {
    const event = events.find((event) => event.seq === atSeq)
    if (event === undefined) throw new Error('Harness history page did not contain its requested target')
    const record = executionRecord(event)
    // Headers pass through the existing credential-free execution projector.
    const data = record?.data ?? (event.type === 'user/message' ? Object.fromEntries(['id', 'source', 'content', 'turn', 'step'].filter((key) => object(event.data)[key] !== undefined).map((key) => [key, object(event.data)[key]])) : {})
    focus = HistoryFocusSchema.parse({ nativeSequence: atSeq, type: record?.type ?? event.type, data, ...(event.time === undefined ? {} : { time: event.time }) })
  }
  return HistoryPageSchema.parse({ sessionId, throughSeq, fromSeq, toSeq, hasMore: page.hasMore, rows, ...(focus === undefined ? {} : { focus }) })
}
