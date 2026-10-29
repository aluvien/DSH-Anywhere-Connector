import { randomUUID } from 'node:crypto'
import { ApprovalRequestedPayloadSchema, ApprovalResolvedPayloadSchema,
  QuestionAskedPayloadSchema, QuestionResolvedPayloadSchema,
  type DecisionsSnapshotPayloadSchema } from '@dsh-anywhere/protocol'

/** The pending set is ephemeral Host state. A new Bridge epoch explicitly
 * replaces old phone cards; monotonic revisions order HTTP snapshots and live
 * decisions even when their responses travel on different transports. */
export class DecisionStateMirror {
  private readonly epoch = randomUUID()
  private revision = 0
  private readonly approvals = new Map<string, ReturnType<typeof ApprovalRequestedPayloadSchema.parse>>()
  private readonly questions = new Map<string, ReturnType<typeof QuestionAskedPayloadSchema.parse>>()

  stamp(type: string, payload: unknown): unknown {
    if (!['approval.requested', 'approval.resolved', 'question.asked', 'question.resolved'].includes(type)) return payload
    const source = typeof payload === 'object' && payload !== null ? payload : {}
    const stamped = { ...source, stateVersion: { epoch: this.epoch, revision: this.revision + 1 } }
    switch (type) {
      case 'approval.requested': {
        const value = ApprovalRequestedPayloadSchema.parse(stamped)
        this.approvals.set(value.id, value)
        break
      }
      case 'approval.resolved': this.approvals.delete(ApprovalResolvedPayloadSchema.parse(stamped).id); break
      case 'question.asked': {
        const value = QuestionAskedPayloadSchema.parse(stamped)
        this.questions.set(value.id, value)
        break
      }
      case 'question.resolved': this.questions.delete(QuestionResolvedPayloadSchema.parse(stamped).id); break
    }
    this.revision += 1
    return stamped
  }

  snapshot(now = Date.now()): ReturnType<typeof DecisionsSnapshotPayloadSchema.parse> {
    return { stateVersion: { epoch: this.epoch, revision: this.revision },
      approvals: [...this.approvals.values()].filter((item) => item.expiresAt === undefined || item.expiresAt > now),
      questions: [...this.questions.values()].filter((item) => item.expiresAt === undefined || item.expiresAt > now) }
  }
}
