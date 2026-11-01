import { describe, expect, it } from 'vitest'
import { WorkflowRecords, workflowHistory } from './workflows.js'

const event = (seq: number, type: string, data: unknown) => ({ seq, time: seq * 1_000, type, data })
const start = (seq: number, runId = 'r') => event(seq, 'tool-workflow/run-start', { runId, name: 'Review' })
const member = (seq: number, childSeq = 1, phase?: string) => event(seq, 'tool-workflow/agent-start', {
  runId: 'r', seq: childSeq, label: `Member ${childSeq}`, childId: `child-${childSeq}`,
  ...(phase === undefined ? {} : { phase }),
})

describe('durable workflow records', () => {
  it('preserves member identities, absent/empty phases and explicit outcomes', () => {
    const records = new WorkflowRecords()
    records.apply('s', start(1))
    records.apply('s', member(2))
    records.apply('s', member(3, 2, ''))
    const before = records.snapshot('s')[0]!
    records.apply('s', event(4, 'tool-workflow/agent-end', { runId: 'r', seq: 1, outcome: 'completed' }))
    records.apply('s', event(5, 'tool-workflow/agent-end', { runId: 'r', seq: 2, outcome: 'failed' }))
    records.apply('s', event(6, 'tool-workflow/run-end', { runId: 'r', stopReason: 'completed' }))
    const run = records.snapshot('s')[0]!.run
    expect(run).toMatchObject({ id: 'r', name: 'Review', status: 'completed', nativeSequence: 1, updatedNativeSequence: 6, startedAt: 1_000, finishedAt: 6_000 })
    expect(run.members).toEqual([
      { seq: 1, label: 'Member 1', childId: 'child-1', status: 'completed' },
      { seq: 2, label: 'Member 2', childId: 'child-2', phase: '', status: 'failed' },
    ])
    expect(before.run.members.map((item) => item.status)).toEqual(['running', 'running'])
    expect(records.snapshot('other')).toEqual([])
  })
  it('marks only unclosed runs interrupted at their own step or turn boundary', () => {
    const records = new WorkflowRecords()
    records.apply('s', event(0, 'turn/start', { turn: 1 }))
    records.apply('s', event(1, 'step/start', { turn: 1, step: 1 }))
    records.apply('s', start(2))
    records.apply('s', member(3))
    records.apply('s', event(4, 'step/end', { turn: 1, step: 1 }))
    expect(records.snapshot('s')[0]!.run).toMatchObject({ status: 'interrupted', members: [{ status: 'interrupted' }] })
    records.apply('s', start(5, 'after-step'))
    records.apply('s', event(6, 'step/start', { turn: 1, step: 2 }))
    records.apply('s', event(7, 'step/end', { turn: 1, step: 2 }))
    expect(records.snapshot('s')[1]!.run.status).toBe('running')
    records.apply('s', event(8, 'turn/end', { turn: 1 }))
    expect(records.snapshot('s')[1]!.run.status).toBe('interrupted')
    expect(records.snapshot('s')[0]!.run.finishedAt).toBe(4_000)
    records.apply('s', event(9, 'tool-workflow/run-end', { runId: 'r', stopReason: 'cancelled' }))
    expect(records.snapshot('s')[0]!.run.status).toBe('cancelled')
  })
  it('does not invent a member settlement from a run terminal record', () => {
    const records = new WorkflowRecords()
    records.apply('s', start(1)); records.apply('s', member(2))
    records.apply('s', event(3, 'tool-workflow/run-end', { runId: 'r', stopReason: 'error' }))
    expect(records.snapshot('s')[0]!.run).toMatchObject({ status: 'failed', members: [{ status: 'running' }] })
  })
  it('merges updates and a closed scope that arrived while an older inspection loaded', () => {
    const records = new WorkflowRecords()
    records.apply('s', event(4, 'tool-workflow/agent-end', { runId: 'r', seq: 1, outcome: 'completed' }))
    records.apply('s', event(5, 'step/end', { turn: 1, step: 1 }))
    records.seed('s', [event(0, 'turn/start', { turn: 1 }), event(1, 'step/start', { turn: 1, step: 1 }), start(2), member(3)])
    expect(records.snapshot('s')[0]!.run).toMatchObject({ status: 'interrupted', updatedNativeSequence: 5, members: [{ status: 'completed' }] })
    records.apply('s', start(6, 'after-hydration'))
    records.apply('s', event(7, 'step/start', { turn: 1, step: 2 }))
    records.apply('s', event(8, 'step/end', { turn: 1, step: 2 }))
    expect(records.snapshot('s')[1]!.run.status).toBe('running')
  })
  it('never regresses a newer live outcome to an old inspection', () => {
    const records = new WorkflowRecords()
    records.apply('s', start(1)); records.apply('s', member(2))
    records.apply('s', event(4, 'tool-workflow/agent-end', { runId: 'r', seq: 1, outcome: 'failed' }))
    records.seed('s', [start(1), member(2)])
    expect(records.snapshot('s')[0]!.run.members[0]!.status).toBe('failed')
    expect(records.apply('s', member(2))).toEqual([])
    expect(records.apply('s', event(3, 'tool-workflow/agent-end', { runId: 'r', seq: 1, outcome: 'completed' }))).toEqual([])
  })
  it('keeps a workflow crossing the visible history cut without loading unrelated old runs', () => {
    const events = [start(0, 'old'), event(1, 'tool-workflow/run-end', { runId: 'old', stopReason: 'completed' }),
      start(2), member(3), event(4, 'other', {}),
      event(5, 'tool-workflow/agent-end', { runId: 'r', seq: 1, outcome: 'completed' }),
      event(6, 'tool-workflow/run-end', { runId: 'r', stopReason: 'completed' })]
    const history = workflowHistory(events, 4)
    expect([...history.ids]).toEqual(['r'])
    expect(history.before).toMatchObject([{ run: { id: 'r', members: [{ childId: 'child-1' }] } }])
    expect(history.byIndex.get(6)).toMatchObject([{ run: { id: 'r', status: 'completed' } }])
  })
  it('ignores malformed members and duplicate starts without losing the valid record', () => {
    const records = new WorkflowRecords()
    records.apply('s', start(1)); records.apply('s', member(2))
    expect(records.apply('s', start(1))).toEqual([])
    expect(records.apply('s', event(3, 'tool-workflow/agent-start', { runId: 'r', seq: 0, label: 'Bad', childId: 'c' }))).toEqual([])
    expect(records.apply('s', event(4, 'tool-workflow/run-end', { runId: 'r', stopReason: 'invented' }))).toEqual([])
    expect(records.snapshot('s')[0]!.run.members).toHaveLength(1)
  })
})
