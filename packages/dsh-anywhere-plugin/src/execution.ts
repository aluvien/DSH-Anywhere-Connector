import { ExecutionLifecycleSchema, ExecutionRecordSchema, ExecutionPagePayloadSchema } from '@dsh-anywhere/protocol'

type RecordValue = ReturnType<typeof ExecutionRecordSchema.parse>
function object(value: unknown): Record<string, unknown> {
  return value !== null && typeof value === 'object' && !Array.isArray(value) ? value as Record<string, unknown> : {}
}
function pick(data: Record<string, unknown>, keys: readonly string[]): Record<string, unknown> {
  return Object.fromEntries(keys.filter((key) => data[key] !== undefined).map((key) => [key, data[key]]))
}
const configKeys = ['provider', 'model', 'reasoningEffort', 'maxTokens', 'temperature', 'topP', 'topK',
  'frequencyPenalty', 'presencePenalty', 'seed', 'stop', 'purpose'] as const

/** Durable execution evidence. Headers expose call settings, never provider
 * credentials or arbitrary adapter extension fields. Exact attempt streams
 * remain distinct from committed assistant messages. */
export function executionRecord(value: unknown): RecordValue | undefined {
  const event = object(value), data = object(event.data)
  let type = event.type, selected: Record<string, unknown>
  switch (type) {
    case 'turn/start': case 'step/start': case 'step/end': selected = pick(data, ['turn', 'step']); break
    case 'turn/end': selected = pick(data, ['turn', 'reason']); break
    case 'request/header': {
      const header = object(data.header)
      selected = { ...pick(data, ['reason', 'startsSeries']), header: {
        config: pick(object(header.config), configKeys),
        ...(header.adapterDefaults === undefined ? {} : { adapterDefaults: pick(object(header.adapterDefaults), configKeys) }),
        ...(Array.isArray(header.tools) ? { tools: header.tools } : {}),
      } }
      break
    }
    case 'request/context': selected = pick(data, ['provider', 'model', 'contextWindow', 'systemPromptUpdate']); break
    case 'assistant/message': selected = pick(data, ['turn', 'step', 'message', 'stream', 'usage', 'interrupted']); break
    case 'assistant/attempt': selected = pick(data, ['turn', 'step', 'stream']); break
    case 'tool/call': selected = pick(data, ['turn', 'step', 'callId', 'name', 'arguments']); break
    case 'tool/result': selected = pick(data, ['turn', 'step', 'message', 'error', 'meta']); break
    case 'tool/ptc-dispatch-start': case 'tool/ptc-dispatch':
      selected = pick(data, ['rootCallId', 'parentCallId', 'subCallId', 'name', 'arguments', 'isError', 'content']); break
    case 'llm/retry': selected = pick(data, ['retryId', 'turn', 'step', 'provider', 'mode', 'policyKey', 'retry', 'maxRetries', 'delayMs', 'failure']); break
    case 'llm/retry-started': selected = pick(data, ['retryId', 'turn', 'step', 'retry']); break
    case 'compaction/start': selected = pick(data, ['compactionId', 'sourceCommandId', 'turn']); break
    case 'compaction/summary': selected = pick(data, ['compactionId', 'sourceCommandId', 'summary', 'rawOutput', 'llmStreamCall', 'shadowedRange', 'shadowedSeqs', 'shadowedTokenCount', 'provider', 'model', 'maxTokens', 'usage']); break
    case 'compaction/end': selected = pick(data, ['compactionId', 'sourceCommandId', 'turn', 'error']); break
    case 'compaction/prune': selected = pick(data, ['shadowedRange', 'shadowedSeqs', 'shadowedTokenCount']); break
    case 'user/message': {
      const source = object(data.source)
      if (source.kind !== 'plugin' || source.plugin !== 'compact' || typeof source.compactionId !== 'string') return undefined
      type = 'compaction/checkpoint'
      selected = { ...pick(data, ['turn', 'step', 'content', 'id']), ...pick(source, ['compactionId', 'sourceCommandId']),
        ...(event.surfaceOp === undefined ? {} : { surfaceOp: event.surfaceOp }) }
      break
    }
    default: return undefined
  }
  const parsed = ExecutionRecordSchema.safeParse({ type, nativeSequence: event.seq,
    ...(event.time === undefined ? {} : { time: event.time }), data: selected })
  return parsed.success ? parsed.data : undefined
}

/** Native sequence is the immutable pagination cursor, independent of Relay
 * event order or any later append. No content is cut in the middle of a record. */
export function executionPage(sessionId: string, events: readonly unknown[], beforeSeq?: number, limit = 100) {
  const records = events.flatMap((event) => { const record = executionRecord(event); return record === undefined ? [] : [record] })
    .filter((record) => beforeSeq === undefined || record.nativeSequence < beforeSeq)
    .sort((a, b) => a.nativeSequence - b.nativeSequence)
  // Bound a page by bytes as well as count, keeping a large individual record
  // whole. The next cursor still advances to the first included native seq.
  const selected: RecordValue[] = []
  let bytes = 0
  for (let index = records.length - 1; index >= 0 && selected.length < limit; index--) {
    const record = records[index]!, size = Buffer.byteLength(JSON.stringify(record), 'utf8')
    if (selected.length > 0 && bytes + size > 1_048_576) break
    selected.push(record); bytes += size
  }
  selected.reverse()
  return ExecutionPagePayloadSchema.parse({ sessionId, records: selected, hasMore: records.length > selected.length,
    ...(selected[0] === undefined ? {} : { beforeSeq: selected[0].nativeSequence }) })
}

/** Inspect is a full Native log. A fork's inherited prefix belongs to the
 * parent, even when it contains an open turn. Never substitute creation-to-now
 * wall time for work or count an orphan end as the child's completed turn. */
export function executionLifecycle(inspection: { events: unknown[]; meta?: unknown; inheritedEventCount?: number }) {
  const createdAt = object(inspection.meta).createdAt, inherited = inspection.inheritedEventCount
  const timestamp = (value: unknown): value is number => typeof value === 'number' && Number.isFinite(value) && value >= 0 && value <= Number.MAX_SAFE_INTEGER
  if (!timestamp(createdAt) || inherited === undefined || !Number.isSafeInteger(inherited) || inherited < 0 || inherited > inspection.events.length ||
      !inspection.events.every((event, index) => object(event).seq === index)) return undefined
  const own = inspection.events.slice(inherited)
  let turnsStarted = 0, turnsEnded = 0, measuredTurns = 0, endedTurnMilliseconds = 0, timingIncomplete = false, assistantMessages = 0, toolCalls = 0
  let lastActivityAt: number | undefined, lastEndKind: string | undefined
  let openTurn: { turn: number; startedAt?: number } | undefined
  const seen = new Set<number>()
  for (const raw of own) {
    const event = object(raw), data = object(event.data)
    const time = timestamp(event.time) ? event.time : undefined
    if (time !== undefined) lastActivityAt = time
    if (event.type === 'assistant/message') assistantMessages += 1
    if (event.type === 'tool/call') toolCalls += 1
    if (event.type !== 'turn/start' && event.type !== 'turn/end') continue
    const turn = data.turn
    if (typeof turn !== 'number' || !Number.isSafeInteger(turn) || turn < 0) { timingIncomplete = true; continue }
    if (event.type === 'turn/start') {
      if (seen.has(turn)) { timingIncomplete = true; continue }
      seen.add(turn)
      if (openTurn !== undefined) timingIncomplete = true
      turnsStarted += 1; openTurn = { turn, ...(time === undefined ? {} : { startedAt: time }) }
    } else {
      if (openTurn?.turn !== turn) { timingIncomplete = true; continue }
      turnsEnded += 1
      const kind = object(data.reason).kind
      lastEndKind = typeof kind === 'string' && ['completed', 'aborted', 'error', 'max-tokens', 'interrupted'].includes(kind) ? kind : 'unknown'
      if (openTurn.startedAt !== undefined && time !== undefined && time >= openTurn.startedAt) {
        measuredTurns += 1; endedTurnMilliseconds += time - openTurn.startedAt
      } else { timingIncomplete = true }
      openTurn = undefined
    }
  }
  return ExecutionLifecycleSchema.parse({ createdAt, inheritedEventCount: inherited, throughSeq: inspection.events.length - 1, ownEventCount: own.length,
    turnsStarted, turnsEnded, measuredTurns, endedTurnMilliseconds, timingIncomplete, assistantMessages, toolCalls,
    ...(lastActivityAt === undefined ? {} : { lastActivityAt }), ...(lastEndKind === undefined ? {} : { lastEndKind }),
    ...(openTurn === undefined ? {} : { openTurn }) })
}

function identity(record: RecordValue, key: string): string | undefined {
  const value = record.data[key]
  return typeof value === 'string' ? value : undefined
}
function scope(record: RecordValue): string | undefined {
  const { turn, step } = record.data
  return typeof turn === 'number' && typeof step === 'number' ? `${turn}:${step}` : undefined
}

/** Supply exact context for records whose owner began before the visible
 * transcript cut. Unrelated old steps stay available through execution.list. */
export function executionPrefix(events: readonly unknown[], recentStart: number): RecordValue[] {
  const before: RecordValue[] = [], turns = new Set<number>(), steps = new Set<string>(), ids = new Set<string>()
  for (let index = 0; index < events.length; index++) {
    const record = executionRecord(events[index]); if (record === undefined) continue
    if (index < recentStart) { before.push(record); continue }
    if (typeof record.data.turn === 'number') turns.add(record.data.turn)
    const step = scope(record); if (step !== undefined) steps.add(step)
    for (const key of ['retryId', 'compactionId']) { const id = identity(record, key); if (id !== undefined) ids.add(`${key}:${id}`) }
  }
  let openTurn: number | undefined, openStep: string | undefined
  const compactions = new Set<string>()
  for (const record of before) {
    if (record.type === 'turn/start' && typeof record.data.turn === 'number') { openTurn = record.data.turn; openStep = undefined }
    if (record.type === 'step/start') openStep = scope(record)
    if (record.type === 'step/end' && openStep === scope(record)) openStep = undefined
    if (record.type === 'turn/end' && record.data.turn === openTurn) { openTurn = undefined; openStep = undefined }
    const id = identity(record, 'compactionId')
    if (record.type === 'compaction/start' && id !== undefined) compactions.add(id)
    if (record.type === 'compaction/end' && id !== undefined) compactions.delete(id)
  }
  if (openTurn !== undefined) turns.add(openTurn)
  if (openStep !== undefined) steps.add(openStep)
  for (const id of compactions) ids.add(`compactionId:${id}`)
  // A retry-started event can be the first visible update. Discover its owner
  // from the earlier retry schedule before selecting the required step context.
  for (const record of before) {
    if (['retryId', 'compactionId'].some((key) => ids.has(`${key}:${identity(record, key)}`))) {
      if (typeof record.data.turn === 'number') turns.add(record.data.turn)
      const step = scope(record); if (step !== undefined) steps.add(step)
    }
  }
  const lastHeader = before.findLast((record) => record.type === 'request/header')?.nativeSequence
  const lastContext = before.findLast((record) => record.type === 'request/context')?.nativeSequence
  return before.filter((record) => record.nativeSequence === lastHeader || record.nativeSequence === lastContext ||
    (record.type === 'turn/start' && typeof record.data.turn === 'number' && turns.has(record.data.turn)) ||
    (scope(record) !== undefined && steps.has(scope(record)!)) ||
    ['retryId', 'compactionId'].some((key) => ids.has(`${key}:${identity(record, key)}`)))
}
