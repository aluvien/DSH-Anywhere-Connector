import { describe, expect, it } from 'vitest'
import { QueueControlMirror } from './queue.js'
const item = { id: 'item', placement: 'queued', rpcId: 'rpc', message: { id: 'item', content: [
  { type: 'text', text: 'Task' }, { type: 'file', receiptId: 'receipt', name: 'spec.txt' },
] } }
describe('authoritative queue control mirror', () => {
  it('keeps native content unchanged while enriching all live and baseline snapshots with original attachment previews', () => {
    const attachment = { id: 'image', name: 'photo.png', mediaType: 'image/png', hostPath: '/host/owned/image' }
    const inputs: unknown[] = []
    const mirror = new QueueControlMirror(() => undefined, (content) => { inputs.push(content); return [attachment] })
    mirror.apply({ type: 'baseline', value: { queues: { s: [item] } } })
    expect(inputs).toEqual([item.message.content])
    expect(mirror.snapshot()).toMatchObject([{ items: [{ ...item, attachments: [attachment] }] }])
    mirror.disconnect()
    expect(mirror.snapshot()).toMatchObject([{ available: false, items: [{ attachments: [attachment] }] }])
    mirror.apply({ type: 'queue', sessionId: 's', items: [] })
    expect(mirror.snapshot()).toEqual([{ sessionId: 's', available: true, items: [] }])
  })
  it('preserves occurrence identity, request correlation, placement and attachments', () => {
    const mirror = new QueueControlMirror(() => undefined)
    mirror.apply({ type: 'baseline', value: { queues: { s: [item] } } })
    expect(mirror.snapshot()).toEqual([{ sessionId: 's', available: true, items: [item] }])
    mirror.apply({ type: 'queue', sessionId: 's', items: [{ ...item, placement: 'steering' }] })
    expect(mirror.snapshot()).toMatchObject([{ items: [{ placement: 'steering' }] }])
  })
  it('marks stale state and clears queues absent from a new baseline', () => {
    const mirror = new QueueControlMirror(() => undefined)
    mirror.apply({ type: 'queue', sessionId: 's', items: [item] })
    mirror.disconnect()
    expect(mirror.snapshot()).toMatchObject([{ available: false }])
    mirror.apply({ type: 'baseline', value: { queues: {} } })
    expect(mirror.snapshot()).toEqual([{ sessionId: 's', available: true, items: [] }])
  })
})
