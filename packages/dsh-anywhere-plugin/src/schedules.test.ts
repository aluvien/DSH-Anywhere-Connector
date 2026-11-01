import { describe, expect, it } from 'vitest'
import { ScheduleControlMirror } from './schedules.js'
const reminder = { id: 'r', kind: 'every', prompt: '检查构建', everySeconds: 300, scheduledAt: '2026-10-30T00:00:00.000Z' }
describe('native Schedule projection', () => {
  it('forwards native occurrences, explicit removals and capability absence without running timers', () => {
    const published: unknown[] = [], mirror = new ScheduleControlMirror((row) => published.push(row))
    mirror.apply({ type: 'baseline', value: { projections: { s: { asOfSeq: 4, values: { schedule: [reminder] } } } } })
    expect(mirror.snapshot('s')[0]).toMatchObject({ supported: true, available: true, seq: 4, items: [reminder] })
    mirror.apply({ type: 'projection', key: 'schedule', sessionId: 's', seq: 5, value: [{ ...reminder, scheduledAt: '2026-10-30T01:00:00.000Z' }] })
    mirror.seed('s', { asOfSeq: 4, values: { schedule: [reminder] } })
    expect(mirror.snapshot('s')[0]!.items[0]!.scheduledAt).toBe('2026-10-30T01:00:00.000Z')
    mirror.apply({ type: 'projection', key: 'schedule', sessionId: 's', seq: 6, value: [] })
    expect(mirror.snapshot('s')[0]!.items).toEqual([])
    expect(published).toHaveLength(3)
    mirror.apply({ type: 'baseline', value: { projections: { s: { asOfSeq: -1, values: {} } } } })
    expect(mirror.snapshot('s')[0]).toMatchObject({ supported: false, seq: -1, items: [] })
  })
  it('fences cold restores across replacement baselines and keeps cached rules on malformed/offline updates', () => {
    const mirror = new ScheduleControlMirror(() => {})
    mirror.seed('s', { asOfSeq: 2, values: { schedule: [reminder] } })
    const epoch = mirror.generation
    mirror.disconnect(); expect(mirror.snapshot('s')[0]!.available).toBe(false)
    mirror.apply({ type: 'baseline', value: { projections: { s: { asOfSeq: 3, values: { schedule: [reminder] } } } } })
    expect(() => mirror.seed('s', { asOfSeq: 9, values: { schedule: [] } }, epoch)).toThrow('重新同步')
    mirror.apply({ type: 'projection', key: 'schedule', sessionId: 's', seq: 4, value: [{ ...reminder, everySeconds: 1 }] })
    expect(mirror.snapshot('s')[0]).toMatchObject({ available: false, seq: 3, items: [reminder] })
    mirror.apply({ type: 'baseline', value: { projections: {} } })
    expect(mirror.snapshot('s')[0]!.available).toBe(false)
  })
})
