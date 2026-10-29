import { createHash } from 'node:crypto'
import { SearchResultsSchema, type SessionSummary } from '@dsh-anywhere/protocol'
import { HttpError } from './http.js'

export interface NativeSearch {
  searchSessions(request: Record<string, unknown>, exec?: { signal: AbortSignal }): Promise<unknown>
  searchEvents(request: Record<string, unknown>, exec?: { signal: AbortSignal }): Promise<unknown>
}
const object = (value: unknown): Record<string, unknown> => value !== null && typeof value === 'object' && !Array.isArray(value) ? value as Record<string, unknown> : {}
const messageFilters = [{ kind: 'type', values: ['user/message', 'assistant/message'] }, { kind: 'surface', values: ['current'] }]
const scopeTypes = ['user/message', 'assistant/message', 'tool/call', 'tool/result', 'tool/ptc-dispatch', 'command/run', 'command/result', 'llm/retry', 'compaction/summary', 'compaction/checkpoint', 'turn/end']

/** The bridge cursor only remembers the provider's accepted page size. The
 * native cursor is forwarded unchanged and still owns index-generation checks. */
export async function searchHistory(service: NativeSearch, query: string, cursor: string | undefined,
  summaries: readonly SessionSummary[], sessionId?: string) {
  const queryKey = createHash('sha256').update(JSON.stringify([query, sessionId ?? null, summaries.map((item) => item.id).sort()])).digest('hex')
  let limit = 20, nativeCursor: string | undefined
  if (cursor !== undefined) {
    try {
      const decoded = object(JSON.parse(Buffer.from(cursor, 'base64url').toString('utf8')))
      if (decoded.key !== queryKey || typeof decoded.cursor !== 'string' || !Number.isInteger(decoded.limit) || Number(decoded.limit) < 1 || Number(decoded.limit) > 20) throw new Error()
      limit = Number(decoded.limit); nativeCursor = decoded.cursor
    } catch { throw new HttpError(409, '搜索条件已变化，请重新搜索') }
  }
  let raw: Record<string, unknown>
  while (true) {
    try {
      raw = object(await (sessionId === undefined
        ? service.searchSessions({ query, limit, ...(nativeCursor === undefined ? {} : { cursor: nativeCursor }),
          sessionFilters: [{ kind: 'id', values: summaries.map((item) => item.id) }], eventFilters: messageFilters }, { signal: AbortSignal.timeout(30_000) })
        : service.searchEvents({ sessionId, query, limit, ...(nativeCursor === undefined ? {} : { cursor: nativeCursor }),
          filters: [{ kind: 'type', values: scopeTypes }] }, { signal: AbortSignal.timeout(30_000) })))
      break
    } catch (error) {
      const code = object(error).code
      if (code === 'SESSION_QUERY_STALE_CURSOR') throw new HttpError(409, '搜索索引已更新，请重新搜索')
      if (nativeCursor === undefined && code === 'SESSION_QUERY_INVALID_LIMIT' && limit > 1) { limit = Math.max(1, Math.floor(limit / 2)); continue }
      throw error
    }
  }
  if (!Array.isArray(raw.items) || (raw.nextCursor !== undefined && typeof raw.nextCursor !== 'string')) throw new HttpError(502, 'Harness returned invalid search results')
  const allowed = new Map(summaries.map((item) => [item.id, item]))
  const items = raw.items.flatMap((value) => {
    const item = object(value), hit = sessionId === undefined ? object(item.bestMatch) : item
    const id = typeof hit.sessionId === 'string' ? hit.sessionId : undefined
    if (id === undefined || (sessionId === undefined ? !allowed.has(id) : id !== sessionId)) return []
    if (typeof hit.seq !== 'number' || !Number.isSafeInteger(hit.seq) || hit.seq < 0 || typeof hit.snippet !== 'string') throw new HttpError(502, 'Harness returned invalid search hit positions')
    return [{ sessionId: id, nativeSequence: hit.seq, snippet: hit.snippet, time: hit.time, type: hit.type, surface: hit.surface,
      ...(allowed.get(id) === undefined ? {} : { session: allowed.get(id) }) }]
  })
  const nextCursor = raw.nextCursor === undefined ? undefined : Buffer.from(JSON.stringify({ key: queryKey, limit, cursor: raw.nextCursor })).toString('base64url')
  if ((nextCursor?.length ?? 0) > 16_384) throw new HttpError(502, 'Harness search cursor exceeds the supported size')
  return SearchResultsSchema.parse({ query, ...(sessionId === undefined ? {} : { scopeSessionId: sessionId }), items, hasMore: nextCursor !== undefined,
    ...(nextCursor === undefined ? {} : { nextCursor }) })
}
