import { ReferenceCandidatesSchema } from '@dsh-anywhere/protocol'
function object(value: unknown): Record<string, unknown> {
  return value !== null && typeof value === 'object' && !Array.isArray(value) ? value as Record<string, unknown> : {}
}
/** Same quoted-path grammar as dsh-file-reference/grammar. A completed
 * directory selection closes its quote; navigation is handled separately. */
export function fileMention(path: string, directory: boolean): string | undefined {
  if (path.length === 0) return undefined
  const value = directory ? path.replace(/\/$/, '') + '/' : path
  if (/[\u0000-\u001f\u007f-\u009f"]/u.test(value) || value.length === 0) return undefined
  return /\s/u.test(value) ? `@"${value}"` : `@${value}`
}
export function referenceCandidates(sessionId: string, kind: 'file' | 'session', query: string, values: unknown) {
  if (!Array.isArray(values)) throw new Error('Harness returned invalid reference candidates')
  type Candidate = ReturnType<typeof ReferenceCandidatesSchema.parse>['items'][number]
  const items = values.flatMap<Candidate>((value) => {
    const item = object(value)
    if (kind === 'file') {
      if (typeof item.path !== 'string' || (item.kind !== 'file' && item.kind !== 'directory')) return []
      const insertion = fileMention(item.path, item.kind === 'directory')
      return insertion === undefined ? [] : [{ id: `${item.kind}:${item.path}`, label: item.path, path: item.path, kind: item.kind, insertion }]
    }
    if (typeof item.sessionId !== 'string' || typeof item.label !== 'string' || typeof item.mention !== 'string') return []
    return [{ id: `session:${item.sessionId}`, label: item.label, kind: 'session' as const, sourceSessionId: item.sessionId,
      insertion: item.mention, ...(typeof item.cwd === 'string' ? { detail: item.cwd } : {}),
      ...(typeof item.sameWorkspace === 'boolean' ? { sameWorkspace: item.sameWorkspace } : {}) }]
  })
  const unique = [...new Map(items.map((item) => [item.id, item])).values()]
  return ReferenceCandidatesSchema.parse({ sessionId, kind, query, items: unique })
}
