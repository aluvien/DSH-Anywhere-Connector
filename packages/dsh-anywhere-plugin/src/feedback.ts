import { FeedbackChangedSchema, FeedbackStateSchema } from '@dsh-anywhere/protocol'

function object(value: unknown): Record<string, unknown> {
  return value !== null && typeof value === 'object' && !Array.isArray(value) ? value as Record<string, unknown> : {}
}

/** These durable events belong to the owning persisted session, not to an
 * inherited answer shown in a fork. Never attach feedback by display order. */
export function feedbackChanged(sessionId: string, value: unknown) {
  const event = object(value), data = object(event.data)
  if (data.sessionId !== sessionId) return undefined
  const item = event.type === 'feedback/message-put' ? data.item : null
  if (event.type !== 'feedback/message-put' && event.type !== 'feedback/message-delete') return undefined
  const parsed = FeedbackChangedSchema.safeParse({ sessionId, nativeSequence: event.seq,
    messageId: item === null ? data.messageId : object(item).messageId, item })
  return parsed.success ? parsed.data : undefined
}

export function feedbackState(sessionId: string, events: readonly unknown[]) {
  const items = new Map<string, NonNullable<ReturnType<typeof feedbackChanged>>['item']>()
  let nativeSequence = -1
  for (const value of [...events].sort((a, b) => Number(object(a).seq) - Number(object(b).seq))) {
    const sequence = object(value).seq
    if (typeof sequence === 'number' && Number.isSafeInteger(sequence) && sequence >= 0) nativeSequence = Math.max(nativeSequence, sequence)
    const change = feedbackChanged(sessionId, value)
    if (change === undefined) continue
    if (change.item === null) items.delete(change.messageId)
    else items.set(change.messageId, change.item)
  }
  return FeedbackStateSchema.parse({ sessionId, nativeSequence, items: [...items.values()] })
}
