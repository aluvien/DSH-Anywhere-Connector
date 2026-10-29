import { describe, expect, it, vi } from 'vitest'
import { mkdtemp, readFile, writeFile, rm, stat } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { loopbackOrigin, publishBridgeEndpoint, registeredBridgeToken } from './desktop.js'

describe('desktop Bridge discovery', () => {
  it('publishes the actual port atomically and leaves a replacement descriptor intact on shutdown', async () => {
    const dir = await mkdtemp(join(tmpdir(), 'dsh-endpoint-'))
    const host = { origin: 'http://127.0.0.1:59656' }
    const stop = publishBridgeEndpoint(host, join(dir, 'connector.json'), '/custom/v1', vi.fn())
    try {
      const file = join(dir, 'bridge-endpoint.json')
      await vi.waitFor(async () => expect(JSON.parse(await readFile(file, 'utf8')))
        .toMatchObject({ version: 1, port: 59656, origin: host.origin, routePrefix: '/custom/v1' }))
      expect((await stat(file)).mode & 0o777).toBe(0o600)
      host.origin = 'http://127.0.0.1:59657'
      await vi.waitFor(async () => expect(JSON.parse(await readFile(file, 'utf8')).port).toBe(59657), { timeout: 2500 })
      await writeFile(file, 'replacement')
      await stop()
      expect(await readFile(file, 'utf8')).toBe('replacement')
    } finally { await stop(); await rm(dir, { recursive: true, force: true }) }
  })

  it('ignores unbound Hosts and never publishes remote or credential-bearing URLs', () => {
    expect(loopbackOrigin({ get origin(): string { throw new Error('unbound') } })).toBeUndefined()
    for (const origin of ['http://example.com:1234', 'http://secret@127.0.0.1:1234', 'http://127.0.0.1:1234/path']) {
      expect(loopbackOrigin({ origin })).toBeUndefined()
    }
    expect(loopbackOrigin({ origin: 'http://[::1]:1234' })).toBe('http://[::1]:1234')
    expect(loopbackOrigin({ host: '127.0.0.1', port: 3080 })).toBe('http://127.0.0.1:3080')
    expect(loopbackOrigin({ host: '::1', port: 3080 })).toBe('http://[::1]:3080')
    expect(loopbackOrigin({ host: '0.0.0.0', port: 3080 })).toBeUndefined()
    expect(loopbackOrigin({ host: '127.0.0.1', port: 0 })).toBeUndefined()
  })

  it('reads the existing private registration without changing the token', async () => {
    const dir = await mkdtemp(join(tmpdir(), 'dsh-token-'))
    const file = join(dir, 'connector.json')
    try {
      expect(registeredBridgeToken(file)).toBeUndefined()
      await writeFile(file, JSON.stringify({ bridgeToken: 'existing-paired-token' }))
      expect(registeredBridgeToken(file)).toBe('existing-paired-token')
    } finally { await rm(dir, { recursive: true, force: true }) }
  })
})
