import { describe, expect, it } from 'vitest'
import { JobControlMirror } from './jobs.js'

const job = { id: 'j', kind: 'shell', label: 'Build', status: 'running', startedAt: 100 }

describe('native background job control mirror', () => {
  it('hydrates new subscribers and replaces per-session lists', () => {
    const events: unknown[] = []
    const mirror = new JobControlMirror((value) => events.push(value))
    mirror.apply({ type: 'baseline', value: { jobs: { s: [job] } } })
    expect(mirror.snapshot()).toEqual([{ sessionId: 's', available: true, jobs: [job] }])
    mirror.apply({ type: 'jobs', sessionId: 's', jobs: [{ ...job, status: 'completed', finishedAt: 200 }] })
    expect(events.at(-1)).toMatchObject({ sessionId: 's', jobs: [{ status: 'completed' }] })
    mirror.apply({ type: 'jobs', sessionId: 's', jobs: [] })
    expect(mirror.snapshot()).toEqual([{ sessionId: 's', available: true, jobs: [] }])
  })

  it('marks disconnected state and clears jobs absent from a reconnect baseline', () => {
    const mirror = new JobControlMirror(() => undefined)
    mirror.apply({ type: 'baseline', value: { jobs: { s: [job] } } })
    mirror.disconnect()
    expect(mirror.snapshot()).toMatchObject([{ sessionId: 's', available: false, jobs: [job] }])
    mirror.apply({ type: 'baseline', value: { jobs: {} } })
    expect(mirror.snapshot()).toEqual([{ sessionId: 's', available: true, jobs: [] }])
  })

  it('does not replace a known list with malformed or unrelated control frames', () => {
    const mirror = new JobControlMirror(() => undefined)
    mirror.apply({ type: 'jobs', sessionId: 's', jobs: [job] })
    mirror.apply({ type: 'jobs', sessionId: 's', jobs: [{ ...job, status: 'invented' }] })
    mirror.apply({ type: 'baseline', value: {} })
    mirror.apply({ type: 'queue', sessionId: 's', items: [] })
    expect(mirror.snapshot()).toEqual([{ sessionId: 's', available: true, jobs: [job] }])
  })
})
