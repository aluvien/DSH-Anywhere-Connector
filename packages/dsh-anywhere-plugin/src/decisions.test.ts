import { describe, expect, it } from 'vitest'
import { DecisionStateMirror } from './decisions.js'

describe('pending decision recovery', () => {
  it('orders live decisions and snapshots in one epoch and removes cross-surface resolutions', () => {
    const mirror = new DecisionStateMirror()
    const request = { id: 'q', sessionId: 's', questions: [{ id: 'item', question: 'Continue?' }] }
    expect(mirror.stamp('question.asked', request)).toMatchObject({ stateVersion: { revision: 1 } })
    const before = mirror.snapshot()
    expect(before.questions).toHaveLength(1)
    mirror.stamp('approval.requested', { id: 'a', sessionId: 's', toolName: 'shell', reason: 'Run?' })
    mirror.stamp('question.resolved', { id: 'q', sessionId: 's' })
    mirror.stamp('approval.resolved', { id: 'a', allowed: false })
    const after = mirror.snapshot()
    expect(after).toMatchObject({ approvals: [], questions: [], stateVersion: { epoch: before.stateVersion.epoch, revision: 4 } })
    expect(before.questions).toHaveLength(1)
    expect(new DecisionStateMirror().snapshot().stateVersion.epoch).not.toBe(before.stateVersion.epoch)
  })

  it('does not restore expired requests or corrupt state on malformed events', () => {
    const mirror = new DecisionStateMirror()
    mirror.stamp('question.asked', { id: 'q', sessionId: 's', questions: [{ id: 'item', question: 'Continue?' }], expiresAt: 100 })
    expect(mirror.snapshot(99).questions).toHaveLength(1)
    expect(mirror.snapshot(100).questions).toEqual([])
    expect(() => mirror.stamp('question.asked', {})).toThrow()
    mirror.stamp('usage.updated', { ignored: true })
    expect(mirror.snapshot().stateVersion.revision).toBe(1)
  })
})
