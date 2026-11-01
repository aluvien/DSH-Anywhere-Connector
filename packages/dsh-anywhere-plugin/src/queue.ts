import { QueueChangedPayloadSchema } from '@dsh-anywhere/protocol'
type QueueState = ReturnType<typeof QueueChangedPayloadSchema.parse>
type Attachment = NonNullable<QueueState['items'][number]['attachments']>[number]
const record = (value: unknown): Record<string, unknown> =>
  value !== null && typeof value === 'object' && !Array.isArray(value) ? value as Record<string, unknown> : {}

export class QueueControlMirror {
  private readonly sessions = new Map<string, QueueState>()
  constructor(private readonly publish: (state: QueueState) => void,
              private readonly attachments?: (content: readonly unknown[]) => Attachment[]) {}
  snapshot(): readonly QueueState[] { return [...this.sessions.values()] }
  apply(value: unknown): void {
    const frame = record(value)
    if (frame.type === 'queue' && typeof frame.sessionId === 'string') this.replace(frame.sessionId, frame.items)
    if (frame.type !== 'baseline') return
    const baseline = record(frame.value)
    if (baseline.queues === null || typeof baseline.queues !== 'object' || Array.isArray(baseline.queues)) return
    const queues = record(baseline.queues)
    for (const id of this.sessions.keys()) if (!Object.hasOwn(queues, id)) this.replace(id, [])
    for (const [id, rows] of Object.entries(queues)) this.replace(id, rows)
  }
  disconnect(): void {
    for (const [id, state] of this.sessions) {
      const stale = { ...state, available: false }
      this.sessions.set(id, stale)
      this.publish(stale)
    }
  }
  private replace(sessionId: string, items: unknown): void {
    const parsed = QueueChangedPayloadSchema.safeParse({ sessionId, items, available: true })
    if (!parsed.success) return
    const projected = this.attachments === undefined ? parsed.data : { ...parsed.data, items: parsed.data.items.map((item) => {
      const attachments = this.attachments!(item.message.content)
      return attachments.length === 0 ? item : { ...item, attachments }
    }) }
    this.sessions.set(sessionId, projected)
    this.publish(projected)
  }
}
