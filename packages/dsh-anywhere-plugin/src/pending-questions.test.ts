import { describe, expect, it } from 'vitest'
import { PendingQuestions, firstAnswered } from './pending-questions.js'

/** A promise with its settle functions exposed, for deterministic ordering. */
function deferred<T>(): { promise: Promise<T>; resolve: (value: T) => void; reject: (error: Error) => void } {
  let resolve!: (value: T) => void
  let reject!: (error: Error) => void
  const promise = new Promise<T>((res, rej) => { resolve = res; reject = rej })
  return { promise, resolve, reject }
}

const flush = () => new Promise((resolve) => setTimeout(resolve, 0))

describe('user question answering', () => {
  it('records and answers a question exactly once', () => {
    const questions = new PendingQuestions()
    const pending = questions.create(60_000)
    expect(questions.answer(pending.id, [{ id: 'q', selected: ['Fast'] }])).toBe(true)
    // A second answer (or a stale tap) must not resolve twice.
    expect(questions.answer(pending.id, [{ id: 'q', selected: ['Slow'] }])).toBe(false)
  })

  it('discards a question another surface already answered', () => {
    const questions = new PendingQuestions()
    const pending = questions.create(60_000)
    questions.discard(pending.id)
    expect(questions.answer(pending.id, [{ id: 'q', selected: ['Fast'] }])).toBe(false)
  })

  it('takes the phone answer when the phone is first', async () => {
    const phone = deferred<{ answers: string[] } | undefined>()
    const browser = deferred<{ answers: string[] }>()
    const settled = firstAnswered(phone.promise, browser.promise)

    phone.resolve({ answers: ['phone'] })
    await expect(settled).resolves.toEqual({ answers: ['phone'] })
  })

  it('takes the browser answer when the browser is first', async () => {
    const phone = deferred<{ answers: string[] } | undefined>()
    const browser = deferred<{ answers: string[] }>()
    const settled = firstAnswered(phone.promise, browser.promise)

    browser.resolve({ answers: ['browser'] })
    await expect(settled).resolves.toEqual({ answers: ['browser'] })
  })

  it('keeps waiting for the phone when no UI answerer is mounted', async () => {
    // This is the regression that made every question vanish while the phone
    // was attached: the browser's waterfall ends in a NO_PROVIDER rejection,
    // which must not be mistaken for "nobody can answer".
    const phone = deferred<{ answers: string[] } | undefined>()
    const browser = deferred<{ answers: string[] }>()
    const settled = firstAnswered(phone.promise, browser.promise)

    browser.reject(new Error('no user-questions answerer accepted the request'))
    await flush()

    phone.resolve({ answers: ['phone'] })
    await expect(settled).resolves.toEqual({ answers: ['phone'] })
  })

  it('keeps waiting for the browser when the phone gives up', async () => {
    const phone = deferred<{ answers: string[] } | undefined>()
    const browser = deferred<{ answers: string[] }>()
    const settled = firstAnswered(phone.promise, browser.promise)

    // The phone resolving undefined is the expiry/abort path.
    phone.resolve(undefined)
    await flush()

    browser.resolve({ answers: ['browser'] })
    await expect(settled).resolves.toEqual({ answers: ['browser'] })
  })

  it('reports an unanswerable question only when both surfaces are gone', async () => {
    const phone = deferred<{ answers: string[] } | undefined>()
    const browser = deferred<{ answers: string[] }>()
    const settled = firstAnswered(phone.promise, browser.promise)

    browser.reject(new Error('no provider'))
    phone.resolve(undefined)
    await expect(settled).resolves.toBeUndefined()
  })

  it('does not treat a non-decision approval result as the winner', async () => {
    const phone = deferred<'allowed-once' | 'rejected' | undefined>()
    const browser = deferred<'allowed-once' | 'rejected' | 'unavailable'>()
    const settled = firstAnswered(phone.promise, browser.promise,
      (value) => value === 'allowed-once' || value === 'rejected')

    browser.resolve('unavailable')
    await flush()
    phone.resolve('allowed-once')
    await expect(settled).resolves.toBe('allowed-once')
  })
})
