import { randomUUID } from 'node:crypto';
import { ApprovalRequestedPayloadSchema, ApprovalResolvedPayloadSchema, QuestionAskedPayloadSchema, QuestionResolvedPayloadSchema } from '../protocol/index.js';
/** The pending set is ephemeral Host state. A new Bridge epoch explicitly
 * replaces old phone cards; monotonic revisions order HTTP snapshots and live
 * decisions even when their responses travel on different transports. */
export class DecisionStateMirror {
    epoch = randomUUID();
    revision = 0;
    approvals = new Map();
    questions = new Map();
    stamp(type, payload) {
        if (!['approval.requested', 'approval.resolved', 'question.asked', 'question.resolved'].includes(type))
            return payload;
        const source = typeof payload === 'object' && payload !== null ? payload : {};
        const stamped = { ...source, stateVersion: { epoch: this.epoch, revision: this.revision + 1 } };
        switch (type) {
            case 'approval.requested': {
                const value = ApprovalRequestedPayloadSchema.parse(stamped);
                this.approvals.set(value.id, value);
                break;
            }
            case 'approval.resolved':
                this.approvals.delete(ApprovalResolvedPayloadSchema.parse(stamped).id);
                break;
            case 'question.asked': {
                const value = QuestionAskedPayloadSchema.parse(stamped);
                this.questions.set(value.id, value);
                break;
            }
            case 'question.resolved':
                this.questions.delete(QuestionResolvedPayloadSchema.parse(stamped).id);
                break;
        }
        this.revision += 1;
        return stamped;
    }
    snapshot(now = Date.now()) {
        return { stateVersion: { epoch: this.epoch, revision: this.revision },
            approvals: [...this.approvals.values()].filter((item) => item.expiresAt === undefined || item.expiresAt > now),
            questions: [...this.questions.values()].filter((item) => item.expiresAt === undefined || item.expiresAt > now) };
    }
}
