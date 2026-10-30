import { randomUUID } from 'node:crypto'
import { ScheduleProjectionSchema } from '@dsh-anywhere/protocol'

type Schedule = ReturnType<typeof ScheduleProjectionSchema.parse>
const object = (value: unknown): Record<string, unknown> => value !== null && typeof value === 'object' && !Array.isArray(value) ? value as Record<string, unknown> : {}

/** Schedule rules and next occurrences are already folded by the Host.
 * Forward the registered projection; never run a second scheduler here. */
export class ScheduleControlMirror {
  private epoch: string = randomUUID()
  private readonly rows = new Map<string, Schedule>()
  constructor(private readonly publish: (value: Schedule) => void) {}
  get generation(): string { return this.epoch }
  snapshot(sessionId?: string): readonly Schedule[] { return [...this.rows.values()].filter((row) => sessionId === undefined || row.sessionId === sessionId) }
  apply(value: unknown): void {
    const frame = object(value)
    if (frame.type === 'baseline') {
      const raw = object(frame.value).projections
      if (raw === null || typeof raw !== 'object' || Array.isArray(raw)) return
      this.epoch = randomUUID()
      const projections = object(raw)
      for (const row of this.rows.values()) if (!Object.hasOwn(projections, row.sessionId)) this.emit({ ...row, epoch: this.epoch, available: false })
      for (const [sessionId, value] of Object.entries(projections)) {
        const block = object(value)
        this.replace(sessionId, object(block.values).schedule, block.asOfSeq, true)
      }
    } else if (frame.type === 'projection' && frame.key === 'schedule' && typeof frame.sessionId === 'string') {
      this.replace(frame.sessionId, frame.value, frame.seq, false)
    }
  }
  /** Synchronous Native cold restore and watermark form one immutable read. */
  seed(sessionId: string, snapshot: unknown, generation = this.epoch): Schedule {
    if (generation !== this.epoch) throw new Error('提醒状态已重新同步，请重试读取')
    const block = object(snapshot)
    this.replace(sessionId, object(block.values).schedule, block.asOfSeq, false)
    const row = this.rows.get(sessionId)
    if (row === undefined) throw new Error('当前提醒格式暂不支持，请更新 Bridge 与 App')
    return row
  }
  disconnect(): void { for (const row of this.rows.values()) this.emit({ ...row, available: false }) }
  private replace(sessionId: string, value: unknown, seq: unknown, baseline: boolean): void {
    const current = this.rows.get(sessionId)
    if (typeof seq !== 'number' || !Number.isSafeInteger(seq) || seq < -1) return
    if (!baseline && current?.epoch === this.epoch && seq < current.seq) return
    const supported = value !== undefined
    const parsed = ScheduleProjectionSchema.safeParse({ sessionId, epoch: this.epoch, seq, available: true, supported, items: supported ? value : [] })
    if (parsed.success) this.emit(parsed.data)
    else if (current !== undefined) this.emit({ ...current, epoch: this.epoch, available: false })
    // An optional future projection must not tear down the shared control
    // feed used by jobs, queues and plan state. A cold read reports failure.
  }
  private emit(value: Schedule): void { this.rows.set(value.sessionId, value); this.publish(value) }
}
