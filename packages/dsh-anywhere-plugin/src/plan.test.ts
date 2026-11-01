import { describe, expect, it } from 'vitest'
import { PlanControlMirror } from './plan.js'

describe('native plan projection', () => {
  it('carries the native pending state and rejects stale updates', () => {
    const published: unknown[] = []
    const mirror = new PlanControlMirror((value) => published.push(value))
    mirror.apply({ type: 'baseline', value: { projections: { s: { asOfSeq: 10, values: { plan: { active: false, pending: true } } } } } })
    expect(mirror.snapshot('s')[0]).toMatchObject({ active: false, pending: true, seq: 10, available: true, supported: true })
    mirror.apply({ type: 'projection', sessionId: 's', key: 'plan', seq: 11, value: { active: true, pending: false } })
    mirror.apply({ type: 'projection', sessionId: 's', key: 'plan', seq: 10, value: { active: false, pending: true } })
    expect(mirror.snapshot('s')[0]).toMatchObject({ active: true, pending: false, seq: 11 })
    expect(published).toHaveLength(2)
  })
  it('starts a replacement generation and marks missing sessions unavailable', () => {
    const mirror = new PlanControlMirror(() => {})
    mirror.apply({ type: 'baseline', value: { projections: { s: { asOfSeq: 10, values: { plan: { active: true, pending: true } } } } } })
    const oldEpoch = mirror.snapshot('s')[0]!.epoch
    mirror.disconnect()
    expect(mirror.snapshot('s')[0]!.available).toBe(false)
    mirror.apply({ type: 'baseline', value: { projections: { s: { asOfSeq: 5, values: { plan: { active: false, pending: false } } } } } })
    expect(mirror.snapshot('s')[0]!.epoch).not.toBe(oldEpoch)
    expect(mirror.snapshot('s')[0]).toMatchObject({ active: false, pending: false, seq: 5, available: true })
    mirror.apply({ type: 'baseline', value: { projections: {} } })
    expect(mirror.snapshot('s')[0]!.available).toBe(false)
  })
  it('represents absent capability without manufacturing a pending transition', () => {
    const mirror = new PlanControlMirror(() => {})
    mirror.apply({ type: 'baseline', value: { projections: { s: { asOfSeq: 1, values: {} } } } })
    expect(mirror.snapshot('s')[0]).toMatchObject({ supported: false, active: false, pending: false })
    mirror.apply({ type: 'projection', key: 'other', sessionId: 's', seq: 2, value: {} })
    mirror.apply({ type: 'projection', key: 'plan', sessionId: 's', seq: 2, value: { active: true, pending: 'invalid' } })
    expect(mirror.snapshot('s')[0]).toMatchObject({ supported: false, available: false })
  })
})
