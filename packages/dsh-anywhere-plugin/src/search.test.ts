import { describe, expect, it, vi } from 'vitest'
import { searchHistory } from './search.js'

const summaries = [{ id: 's', title: 'A', updatedAt: 1000 }]
const hit = (seq: number, sessionId = 's') => ({ sessionId, seq, type: 'assistant/message', time: 1000, surface: 'current', snippet: '匹配内容' })
describe('native history search', () => {
  it('reports a disabled Native index as an unavailable capability without retrying', async () => {
    const disabled = vi.fn().mockRejectedValue({ code: 'SESSION_QUERY_SEARCH_DISABLED' })
    const service = { searchSessions: disabled, searchEvents: disabled }
    await expect(searchHistory(service, 'x', undefined, summaries)).rejects.toMatchObject({ status: 501, message: expect.stringContaining('尚未启用') })
    await expect(searchHistory(service, 'x', undefined, summaries, 's')).rejects.toMatchObject({ status: 501 })
    expect(disabled).toHaveBeenCalledTimes(2)
  })
  it('uses native filters, positions and cursors and does not expose hidden child sessions', async () => {
    const searchSessions = vi.fn().mockResolvedValueOnce({ items: [{ bestMatch: hit(4) }, { bestMatch: hit(1, 'hidden-child') }], nextCursor: 'native-cursor' }).mockResolvedValueOnce({ items: [{ bestMatch: hit(9) }] })
    const service = { searchSessions, searchEvents: vi.fn() }
    const first = await searchHistory(service, '匹配', undefined, summaries)
    expect(first.items).toHaveLength(1); expect(first.items[0]).toMatchObject({ nativeSequence: 4, session: { title: 'A' } })
    expect(searchSessions.mock.calls[0]![0]).toMatchObject({ query: '匹配', sessionFilters: [{ kind: 'id', values: ['s'] }], eventFilters: [{ kind: 'type', values: ['user/message', 'assistant/message'] }, { kind: 'surface', values: ['current'] }] })
    expect((await searchHistory(service, '匹配', first.nextCursor, summaries)).items[0]?.nativeSequence).toBe(9)
    expect(searchSessions.mock.calls[1]![0].cursor).toBe('native-cursor')
    await expect(searchHistory(service, '变更条件', first.nextCursor, summaries)).rejects.toMatchObject({ status: 409 })
  })
  it('remembers the accepted native page limit across continuation without silently restarting a stale cursor', async () => {
    const searchEvents = vi.fn().mockRejectedValueOnce({ code: 'SESSION_QUERY_INVALID_LIMIT' }).mockResolvedValueOnce({ items: [hit(0)], nextCursor: 'generation-1' }).mockRejectedValueOnce({ code: 'SESSION_QUERY_STALE_CURSOR' })
    const service = { searchSessions: vi.fn(), searchEvents }
    const first = await searchHistory(service, 'x', undefined, summaries, 's')
    expect(searchEvents.mock.calls[0]![0].limit).toBe(20); expect(searchEvents.mock.calls[1]![0].limit).toBe(10)
    expect(first.items[0]?.nativeSequence).toBe(0)
    await expect(searchHistory(service, 'x', first.nextCursor, summaries, 's')).rejects.toMatchObject({ status: 409 })
    expect(searchEvents.mock.calls[2]![0]).toMatchObject({ sessionId: 's', limit: 10, cursor: 'generation-1' })
    expect(searchEvents).toHaveBeenCalledTimes(3)
  })
  it('rejects untrusted cursors and malformed native hit positions', async () => {
    const service = { searchSessions: vi.fn().mockResolvedValue({ items: [{ bestMatch: hit(-1) }] }), searchEvents: vi.fn() }
    await expect(searchHistory(service, 'x', 'not-a-cursor', summaries)).rejects.toMatchObject({ status: 409 })
    expect(service.searchSessions).not.toHaveBeenCalled()
    await expect(searchHistory(service, 'x', undefined, summaries)).rejects.toMatchObject({ status: 502 })
  })
})
