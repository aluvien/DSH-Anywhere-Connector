import { randomBytes } from 'node:crypto'
import type { QuestionAnswerItem } from '@dsh-anywhere/protocol'

interface PendingQuestion {
  readonly resolve: (answers: readonly QuestionAnswerItem[]) => void
  readonly reject: (error: Error) => void
  readonly timer: NodeJS.Timeout
  readonly signal?: AbortSignal
  readonly onAbort?: () => void
}

/**
 * Mirrors PendingApprovals: the answerer publishes a question to the paired
 * device and parks the model's tool call until the phone answers, the request
 * is aborted, or the deadline passes. Every question must settle, because the
 * `ask_user_question` tool awaits this promise before it can continue.
 */
export class PendingQuestions {
  private readonly pending = new Map<string, PendingQuestion>()

  create(timeoutMs: number, signal?: AbortSignal): {
    id: string
    result: Promise<readonly QuestionAnswerItem[]>
  } {
    const id = `question_${randomBytes(12).toString('base64url')}`
    let settle!: (answers: readonly QuestionAnswerItem[]) => void
    let fail!: (error: Error) => void
    const result = new Promise<readonly QuestionAnswerItem[]>((resolve, reject) => {
      settle = resolve
      fail = reject
    })
    const timer = setTimeout(
      () => this.reject(id, new Error('the user did not answer before the question expired')),
      timeoutMs,
    )
    const onAbort = signal === undefined
      ? undefined
      : () => this.reject(id, new Error('the question was cancelled before the user answered'))
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

  answer(id: string, answers: readonly QuestionAnswerItem[]): boolean {
    const item = this.take(id)
    if (item === undefined) return false
    item.resolve(answers)
    return true
  }

  reject(id: string, error: Error): boolean {
    const item = this.take(id)
    if (item === undefined) return false
    item.reject(error)
    return true
  }

  rejectAll(error: Error): void {
    for (const id of [...this.pending.keys()]) this.reject(id, error)
  }

  private take(id: string): PendingQuestion | undefined {
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
