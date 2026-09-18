import { randomBytes } from 'node:crypto'

export type ApprovalDecision = 'allowed-once' | 'rejected'

interface PendingApproval {
  readonly resolve: (decision: ApprovalDecision) => void
  readonly reject: () => void
  readonly timer: NodeJS.Timeout
  readonly signal?: AbortSignal
  readonly onAbort?: () => void
}

export class PendingApprovals {
  private readonly pending = new Map<string, PendingApproval>()

  create(timeoutMs: number, signal?: AbortSignal): {
    id: string
    result: Promise<ApprovalDecision>
  } {
    const id = `approval_${randomBytes(12).toString('base64url')}`
    let settle!: (decision: ApprovalDecision) => void
    let fail!: () => void
    const result = new Promise<ApprovalDecision>((resolve, reject) => {
      settle = resolve
      fail = () => { reject(new Error('approval unavailable')) }
    })
    const timer = setTimeout(() => this.reject(id), timeoutMs)
    const onAbort = signal === undefined ? undefined : () => this.reject(id)
    signal?.addEventListener('abort', onAbort!, { once: true })
    this.pending.set(id, {
      resolve: settle,
      reject: fail,
      timer,
      ...(signal === undefined ? {} : { signal }),
      ...(onAbort === undefined ? {} : { onAbort }),
    })
    return { id, result }
  }

  decide(id: string, decision: ApprovalDecision): boolean {
    const item = this.take(id)
    if (item === undefined) return false
    item.resolve(decision)
    return true
  }

  reject(id: string): boolean {
    const item = this.take(id)
    if (item === undefined) return false
    item.reject()
    return true
  }

  rejectAll(): void {
    for (const id of [...this.pending.keys()]) this.reject(id)
  }

  /** Removes a phone-side request after another approval surface wins. */
  discard(id: string): void {
    this.take(id)
  }

  private take(id: string): PendingApproval | undefined {
    const item = this.pending.get(id)
    if (item === undefined) return undefined
    this.pending.delete(id)
    clearTimeout(item.timer)
    if (item.signal !== undefined && item.onAbort !== undefined) {
      item.signal.removeEventListener('abort', item.onAbort)
    }
    return item
  }
}
