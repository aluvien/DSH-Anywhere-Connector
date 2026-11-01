import { randomUUID } from 'node:crypto'
import { PlanProjectionPayloadSchema } from '@dsh-anywhere/protocol'

type Plan = ReturnType<typeof PlanProjectionPayloadSchema.parse>
function record(value: unknown): Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value) ? value as Record<string, unknown> : {}
}

/** Forward the Host's plan fold, including its pending command lifecycle.
 * Each replacement control baseline starts a new projection generation. */
export class PlanControlMirror {
  private epoch = randomUUID()
  private readonly rows = new Map<string, Plan>()
  constructor(private readonly publish: (value: Plan) => void) {}
  snapshot(sessionId?: string): readonly Plan[] {
    return sessionId === undefined ? [...this.rows.values()] : this.rows.has(sessionId) ? [this.rows.get(sessionId)!] : []
  }
  apply(value: unknown): void {
    const frame = record(value)
    if (frame.type === 'baseline') {
      const source = record(frame.value)
      if (typeof source.projections !== 'object' || source.projections === null || Array.isArray(source.projections)) return
      const projections = record(source.projections)
      this.epoch = randomUUID()
      for (const [id, current] of this.rows) {
        if (!Object.hasOwn(projections, id)) this.emit({ ...current, epoch: this.epoch, available: false })
      }
      for (const [id, value] of Object.entries(projections)) {
        const block = record(value)
        if (typeof block.values !== 'object' || block.values === null || Array.isArray(block.values)) continue
        const values = record(block.values)
        if (typeof block.asOfSeq !== 'number' || !Number.isSafeInteger(block.asOfSeq) || block.asOfSeq < 0) continue
        this.replace(id, values.plan, block.asOfSeq, true)
      }
    } else if (frame.type === 'projection' && frame.key === 'plan' && typeof frame.sessionId === 'string' &&
      typeof frame.seq === 'number' && Number.isSafeInteger(frame.seq) && frame.seq >= 0) {
      this.replace(frame.sessionId, frame.value, frame.seq, false)
    }
  }
  disconnect(): void {
    for (const row of this.rows.values()) this.emit({ ...row, available: false })
  }
  private replace(sessionId: string, value: unknown, seq: number, baseline: boolean): void {
    const current = this.rows.get(sessionId)
    if (!baseline && current?.epoch === this.epoch && seq <= current.seq) return
    const plan = record(value)
    const supported = value !== undefined
    const parsed = PlanProjectionPayloadSchema.safeParse({ sessionId, epoch: this.epoch, seq,
      available: true, supported, active: supported ? plan.active : false, pending: supported ? plan.pending : false })
    if (parsed.success) this.emit(parsed.data)
    else if (current !== undefined) this.emit({ ...current, epoch: this.epoch, available: false })
  }
  private emit(value: Plan): void { this.rows.set(value.sessionId, value); this.publish(value) }
}
