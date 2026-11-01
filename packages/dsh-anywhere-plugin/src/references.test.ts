import { describe, expect, it } from 'vitest'
import { fileMention, referenceCandidates } from './references.js'
describe('native reference discovery', () => {
  it('preserves native file and directory grammar without unrepresentable characters', () => {
    expect(fileMention('a.ts', false)).toBe('@a.ts')
    expect(fileMention('文件/a b.ts', false)).toBe('@"文件/a b.ts"')
    expect(fileMention('path with spaces', true)).toBe('@"path with spaces/"')
    expect(fileMention('dir/', true)).toBe('@dir/')
    for (const path of ['', 'a\nb', 'a"b', 'a\0b']) expect(fileMention(path, false)).toBeUndefined()
    expect(referenceCandidates('s', 'file', '', [{ path: 'a', kind: 'file' }, { path: 'a', kind: 'file' }, { path: 'invalid"', kind: 'file' }]).items)
      .toEqual([{ id: 'file:a', label: 'a', path: 'a', kind: 'file', insertion: '@a' }])
  })
  it('keeps Host canonical session mentions instead of rebuilding titles into fake references', () => {
    const mention = '@[原生\\]标题](dsh-session:ImEvYiI)'
    expect(referenceCandidates('s', 'session', '标题', [{ sessionId: 'a/b', label: '原生]标题', mention, cwd: '/project', sameWorkspace: true }]).items)
      .toEqual([{ id: 'session:a/b', label: '原生]标题', insertion: mention, kind: 'session', sourceSessionId: 'a/b', detail: '/project', sameWorkspace: true }])
    expect(() => referenceCandidates('s', 'file', '', {})).toThrow()
  })
})
