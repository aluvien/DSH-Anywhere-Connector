import { WorkflowChangedPayloadSchema } from '@dsh-anywhere/protocol'

type Update = ReturnType<typeof WorkflowChangedPayloadSchema.parse>
type Run = Update['run']
type Member = Run['members'][number]
type Location = { turn?: number; step?: number }
interface RecordRun {
  value: Run
  location: Location
  settled: boolean
  outcomes: Map<number, Member['status']>
}
interface Session {
  location: Location
  scopeSeq?: number | undefined
  runs: Map<string, RecordRun>
  pending: Map<string, unknown[]>
  closed: Map<string, { location: Location; seq?: number; time?: number }>
}
function record(value: unknown): Record<string, unknown> {
  return value !== null && typeof value === 'object' && !Array.isArray(value) ? value as Record<string, unknown> : {}
}
function integer(value: unknown): number | undefined {
  return typeof value === 'number' && Number.isSafeInteger(value) && value >= 0 ? value : undefined
}
function sameScope(run: Location, close: Location): boolean {
  return close.turn !== undefined && run.turn === close.turn && (close.step === undefined || run.step === close.step)
}

/** The browser's durable workflow fold: explicit member outcomes win; an
 * unclosed run becomes interrupted only when its containing step/turn closes.
 * Absent and empty phase identities are intentionally preserved. */
export class WorkflowRecords {
  private readonly sessions = new Map<string, Session>()
  private session(id: string): Session {
    let value = this.sessions.get(id)
    if (value === undefined) {
      value = { location: {}, runs: new Map(), pending: new Map(), closed: new Map() }
      this.sessions.set(id, value)
    }
    return value
  }
  snapshot(sessionId: string): Update[] {
    return [...this.session(sessionId).runs.values()].map((run) => ({ sessionId, run: this.project(run) }))
  }
  apply(sessionId: string, value: unknown): Update[] {
    const event = record(value), data = record(event.data)
    const seq = integer(event.seq), time = integer(event.time)
    const state = this.session(sessionId)
    if (event.type === 'turn/start' || event.type === 'step/start') {
      if (seq !== undefined && state.scopeSeq !== undefined && seq <= state.scopeSeq) return []
      const turn = integer(data.turn), step = event.type === 'step/start' ? integer(data.step) : undefined
      if (turn !== undefined) { state.location = { turn, ...(step === undefined ? {} : { step }) }; state.scopeSeq = seq }
      return []
    }
    if (event.type === 'turn/end' || event.type === 'step/end') {
      const turn = integer(data.turn), step = event.type === 'step/end' ? integer(data.step) : undefined
      if (turn === undefined || (event.type === 'step/end' && step === undefined)) return []
      const location = { turn, ...(step === undefined ? {} : { step }) }
      const key = JSON.stringify(location)
      const old = state.closed.get(key)
      if (old?.seq !== undefined && seq !== undefined && old.seq >= seq) return []
      state.closed.set(key, { location, ...(seq === undefined ? {} : { seq }), ...(time === undefined ? {} : { time }) })
      if (seq === undefined || state.scopeSeq === undefined || seq >= state.scopeSeq) {
        if (state.location.turn === turn && (step === undefined || state.location.step === step)) {
          state.location = step === undefined ? {} : { turn }
          state.scopeSeq = seq
        }
      }
      const changed: Update[] = []
      for (const run of state.runs.values()) {
        if (!run.settled && run.value.status !== 'interrupted' && sameScope(run.location, location)) {
          run.value.status = 'interrupted'
          if (seq !== undefined) run.value.updatedNativeSequence = Math.max(run.value.updatedNativeSequence ?? 0, seq)
          if (time !== undefined) run.value.finishedAt = time
          changed.push({ sessionId, run: this.project(run) })
        }
      }
      return changed
    }
    if (!['tool-workflow/run-start', 'tool-workflow/agent-start', 'tool-workflow/agent-end', 'tool-workflow/run-end'].includes(String(event.type))) return []
    if (typeof data.runId !== 'string' || data.runId.length === 0 || data.runId.length > 256) return []
    let run = state.runs.get(data.runId)
    if (event.type === 'tool-workflow/run-start') {
      if (run !== undefined || typeof data.name !== 'string') return []
      run = { value: { id: data.runId, name: data.name, status: 'running', members: [],
        ...(seq === undefined ? {} : { nativeSequence: seq, updatedNativeSequence: seq }),
        ...(time === undefined ? {} : { startedAt: time }) }, location: { ...state.location }, settled: false, outcomes: new Map() }
      state.runs.set(data.runId, run)
    } else if (run === undefined) {
      // A plugin can attach after a run started. Keep updates until a normal
      // history inspection supplies its required start record.
      const pending = state.pending.get(data.runId) ?? []
      if (!pending.some((item) => seq !== undefined && record(item).seq === seq)) pending.push(value)
      state.pending.set(data.runId, pending)
      return []
    } else {
      if (seq !== undefined && run.value.updatedNativeSequence !== undefined && seq <= run.value.updatedNativeSequence) return []
      if (event.type === 'tool-workflow/agent-start') {
        const memberSeq = integer(data.seq)
        const parsed = WorkflowChangedPayloadSchema.shape.run.shape.members.element.safeParse({
          seq: memberSeq, label: data.label, childId: data.childId, status: 'running',
          ...(data.phase === undefined ? {} : { phase: data.phase }) })
        if (!parsed.success || run.value.members.some((item) => item.seq === memberSeq)) return []
        run.value.members.push(parsed.data)
      } else if (event.type === 'tool-workflow/agent-end') {
        const memberSeq = integer(data.seq)
        if (memberSeq === undefined || !['completed', 'failed', 'cancelled'].includes(String(data.outcome)) ||
          !run.value.members.some((item) => item.seq === memberSeq)) return []
        run.outcomes.set(memberSeq, data.outcome as Member['status'])
      } else if (event.type === 'tool-workflow/run-end') {
        if (!['completed', 'error', 'cancelled'].includes(String(data.stopReason))) return []
        run.value.status = data.stopReason === 'error' ? 'failed' : data.stopReason as Run['status']
        run.settled = true
        if (time !== undefined) run.value.finishedAt = time
      } else return []
      if (seq !== undefined) run.value.updatedNativeSequence = seq
    }
    return [{ sessionId, run: this.project(run) }]
  }
  /** Merge an inspection cut with live updates that arrived while it loaded. */
  seed(sessionId: string, events: readonly unknown[]): Update[] {
    const restored = new WorkflowRecords()
    for (const event of events) restored.apply(sessionId, event)
    const state = this.session(sessionId)
    for (const updates of state.pending.values()) {
      for (const event of updates) restored.apply(sessionId, event)
    }
    const baseline = restored.session(sessionId)
    for (const [id, run] of baseline.runs) {
      const current = state.runs.get(id)
      if (current === undefined || (run.value.updatedNativeSequence !== undefined &&
        run.value.updatedNativeSequence > (current.value.updatedNativeSequence ?? -1))) state.runs.set(id, run)
      state.pending.delete(id)
    }
    if ((baseline.scopeSeq ?? -1) > (state.scopeSeq ?? -1)) { state.location = baseline.location; state.scopeSeq = baseline.scopeSeq }
    for (const close of [...baseline.closed.values(), ...state.closed.values()]) {
      const key = JSON.stringify(close.location)
      const existing = state.closed.get(key)
      if (existing?.seq === undefined || (close.seq ?? -1) > existing.seq) state.closed.set(key, close)
    }
    for (const close of [...state.closed.values()].sort((a, b) => (a.seq ?? 0) - (b.seq ?? 0))) {
      if ((close.seq ?? -1) >= (state.scopeSeq ?? -1) && sameScope(state.location, close.location)) {
        state.location = close.location.step === undefined ? {} : { turn: close.location.turn! }
        state.scopeSeq = close.seq
      }
      for (const run of state.runs.values()) {
        if (!run.settled && run.value.status !== 'interrupted' && sameScope(run.location, close.location)) {
          run.value.status = 'interrupted'
          if (close.seq !== undefined) run.value.updatedNativeSequence = Math.max(run.value.updatedNativeSequence ?? 0, close.seq)
          if (close.time !== undefined) run.value.finishedAt = close.time
        }
      }
    }
    return this.snapshot(sessionId)
  }
  private project(run: RecordRun): Run {
    return { ...run.value, members: run.value.members.map((member) => ({ ...member,
      status: run.outcomes.get(member.seq) ?? (!run.settled && run.value.status === 'interrupted' ? 'interrupted' : 'running') })) }
  }
}

/** Rebuild full records before cutting the visible log. Runs crossing the cut
 * keep their members; completed runs wholly before it stay outside the window. */
export function workflowHistory(events: readonly unknown[], recentStart: number): {
  before: Update[]; byIndex: Map<number, Update[]>; ids: Set<string>
} {
  const scan = new WorkflowRecords(), ids = new Set<string>()
  for (let index = 0; index < events.length; index += 1) {
    if (index === recentStart) for (const item of scan.snapshot('history')) if (item.run.status === 'running') ids.add(item.run.id)
    const changed = scan.apply('history', events[index])
    if (index >= recentStart) for (const item of changed) ids.add(item.run.id)
  }
  const replay = new WorkflowRecords(), byIndex = new Map<number, Update[]>()
  let before: Update[] = []
  for (let index = 0; index < events.length; index += 1) {
    if (index === recentStart) before = replay.snapshot('history').filter((item) => ids.has(item.run.id))
    const changed = replay.apply('history', events[index])
    if (index >= recentStart && changed.length > 0) byIndex.set(index, changed.filter((item) => ids.has(item.run.id)))
  }
  return { before, byIndex, ids }
}
