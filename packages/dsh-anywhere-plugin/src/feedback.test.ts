import { describe, expect, it } from 'vitest'
import { feedbackChanged, feedbackState } from './feedback.js'

const item = { messageId: 'answer', rating: 'negative', note: 'Keep my note', category: 'other', version: 'v1', createdAt: 1, updatedAt: 2 }
describe('native message feedback', () => {
  it('keeps owning-session identity and folds current revisions and deletions by native sequence', () => {
    const put = { seq: 2, type: 'feedback/message-put', data: { sessionId: 's', item } }
    const edit = { seq: 4, type: 'feedback/message-put', data: { sessionId: 's', item: { ...item, version: 'v2' } } }
    const inherited = { seq: 5, type: 'feedback/message-put', data: { sessionId: 'parent', item } }
    expect(feedbackState('s', [edit, put, inherited])).toEqual({ sessionId: 's', nativeSequence: 5, items: [{ ...item, version: 'v2' }] })
    expect(feedbackState('s', [put, { seq: 9, type: 'feedback/message-delete', data: { sessionId: 's', messageId: 'answer' } }]))
      .toEqual({ sessionId: 's', nativeSequence: 9, items: [] })
    expect(feedbackChanged('s', inherited)).toBeUndefined()
    expect(feedbackChanged('s', put)).toEqual({ sessionId: 's', nativeSequence: 2, messageId: 'answer', item })
  })
  it('rejects malformed events and preserves a valid empty-session watermark', () => {
    expect(feedbackChanged('s', { seq: -1, type: 'feedback/message-put', data: { sessionId: 's', item } })).toBeUndefined()
    expect(feedbackChanged('s', { seq: 1, type: 'feedback/message-put', data: { sessionId: 's', item: { ...item, rating: 'invented' } } })).toBeUndefined()
    expect(feedbackState('s', [])).toEqual({ sessionId: 's', nativeSequence: -1, items: [] })
  })
})
