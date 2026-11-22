import { mkdtemp, readFile, rm, writeFile } from 'node:fs/promises'
import { createServer } from 'node:http'
import { tmpdir } from 'node:os'
import { dirname, join } from 'node:path'
import { afterEach, describe, expect, it, vi } from 'vitest'
import { WebSocket, WebSocketServer } from 'ws'
import type { ConnectorDependencies } from '@dsh-anywhere/connector'
import { createRelayServer } from '../../relay-server/src/server.js'
import { PluginRemoteSetup, readInstallerGrant, resolvePluginRegistration } from './remote-setup.js'

const cleanup: Array<() => void | Promise<void>> = []
afterEach(async () => {
  for (const dispose of cleanup.splice(0).reverse()) await dispose()
})
async function directory() {
  const path = await mkdtemp(join(tmpdir(), 'dsh-plugin-setup-'))
  cleanup.push(() => rm(path, { recursive: true, force: true }))
  return path
}

describe('Harness plugin remote connection', () => {
  it('recognizes existing standalone registrations without touching them', async () => {
    const path = join(await directory(), 'connector.json')
    expect(resolvePluginRegistration(path)).toEqual({
      configPath: join(dirname(path), 'harness-plugin', 'connector.json'), external: false,
    })
    await writeFile(path, 'preserve existing file')
    const registration = resolvePluginRegistration(path)
    const setup = new PluginRemoteSetup({
      ...registration, host: {}, prefix: '/dsh-anywhere/v1',
      trustBridge: vi.fn(), warn: vi.fn(),
      request: vi.fn(async () => { throw new Error('must not register') }) as typeof fetch,
    })
    await setup.enable()
    expect(setup.state).toBe('external')
    expect(await readFile(path, 'utf8')).toBe('preserve existing file')
  })

  it('consumes only a unique installer grant', async () => {
    const token = 'a'.repeat(43)
    let body = `enrollment_token='${token}'\nother_installer_content\n`
    const fetchInstaller = vi.fn(async () => new Response(body))
    expect(await readInstallerGrant('https://relay.example.test', fetchInstaller)).toBe(token)
    expect(fetchInstaller).toHaveBeenCalledWith(new URL('https://relay.example.test/install'),
      { redirect: 'error', cache: 'no-store' })
    body += `enrollment_token='${token}'\n`
    await expect(readInstallerGrant('https://relay.example.test', fetchInstaller)).rejects.toThrow('grant')
  })

  it('enrolls once, brings a managed Connector online, and reuses the identity after restart', async () => {
    const root = await directory()
    const relay = await createRelayServer({
      bootstrapToken: 'isolated-relay-bootstrap',
      registryPath: join(root, 'registry.json'),
      host: '127.0.0.1', port: 0,
      publicBaseURL: 'https://relay.example.test',
      publicInstallSourceURL: 'https://example.test/source.tar.gz',
      publicInstallScript: "relay='__DSH_RELAY_URL__'\nenrollment_token='__DSH_ENROLLMENT_TOKEN__'\nsource='__DSH_SOURCE_ARCHIVE_URL__'\n",
    })
    cleanup.push(() => relay.close())
    let bridgeToken = ''
    const http = createServer((request, response) => {
      if (request.url?.startsWith('/dsh-anywhere/v1/sessions')) {
        response.writeHead(200, { 'content-type': 'application/json' })
        response.end(JSON.stringify({ sessions: [{ id: 'fixture-session', title: 'Fixture session' }] }))
      } else {
        response.end()
      }
    })
    await new Promise<void>(resolve => http.listen(0, '127.0.0.1', resolve))
    const address = http.address()
    if (!address || typeof address === 'string') throw new Error('Expected a local bridge port')
    const wss = new WebSocketServer({
      server: http,
      verifyClient: ({ req }) => req.headers.authorization === `Bearer ${bridgeToken}`,
    })
    wss.on('connection', (socket, request) => {
      const url = new URL(request.url!, 'http://127.0.0.1')
      socket.send(JSON.stringify({
        version: 1, messageId: 'bridge-ready', deviceId: 'broadcast', machineId: 'bridge',
        sequence: 1, timestamp: Date.now(), type: 'connection.ready',
        payload: { machineId: 'bridge', deviceId: 'connector', serverTime: Date.now(),
          capabilities: [], bridgeConnectionId: url.searchParams.get('connectorId'), bridgeEpoch: 'bridge-test' },
      }))
    })
    cleanup.push(() => new Promise<void>(resolve => {
      for (const socket of wss.clients) socket.terminate()
      wss.close()
      http.close(() => resolve())
    }))
    const request: typeof fetch = (input, init) => {
      const url = input instanceof Request ? new URL(input.url) : new URL(input)
      return fetch(url.hostname === 'relay.example.test'
        ? new URL(url.pathname + url.search, relay.url) : input, init)
    }
    const webSocketFactory: NonNullable<ConnectorDependencies['webSocketFactory']> = (address, headers) => {
      const url = new URL(address)
      if (url.hostname === 'relay.example.test') {
        const fixture = new URL(url.pathname + url.search, relay.url)
        fixture.protocol = 'ws:'
        return new WebSocket(fixture, { headers })
      }
      return new WebSocket(url, { headers })
    }
    const configPath = join(root, 'harness-plugin', 'connector.json')
    // Registration is HTTPS-only in the public API. Keep HTTPS at the input
    // and forward the test registration calls to the isolated HTTP fixture.
    const options = {
      configPath, external: false, host: { origin: `http://127.0.0.1:${address.port}` },
      prefix: '/dsh-anywhere/v1', relay: 'https://relay.example.test',
      trustBridge: (token: string) => { bridgeToken = token },
      warn: vi.fn(), request, webSocketFactory,
    }
    const setup = new PluginRemoteSetup(options)
    cleanup.push(() => setup.stop())
    await Promise.all([setup.enable(), setup.enable()])
    const registered = JSON.parse(await readFile(configPath, 'utf8'))
    expect(registered.machineId).toMatch(/^machine_/)
    expect(bridgeToken).toBe(registered.bridgeToken)
    await vi.waitFor(() => expect(setup.state).toBe('connected'))
    const pairing = await setup.pairingCode()
    expect(pairing.expiresAt).toBeGreaterThan(Date.now())
    const link = new URL(pairing.link)
    expect(link.searchParams.get('machineId')).toBe(registered.machineId)
    const pair = await fetch(new URL('/v1/pair', relay.url), {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({
        machineId: registered.machineId, pairingCode: link.searchParams.get('code'),
        deviceName: 'isolated test phone',
      }),
    })
    expect(pair.status).toBe(201)
    const device: { deviceToken: string } = await pair.json()
    const peerURL = new URL('/v1/connect', relay.url)
    peerURL.protocol = 'ws:'
    const phone = new WebSocket(peerURL, { headers: { authorization: `Bearer ${device.deviceToken}` } })
    cleanup.push(() => phone.terminate())
    const phoneFrames: Array<{ type: string; online?: boolean; role: string }> = []
    phone.on('message', raw => phoneFrames.push(JSON.parse(String(raw))))
    await vi.waitFor(() => expect(phoneFrames).toContainEqual(expect.objectContaining({ type: 'relay.ready', role: 'device' })))
    await vi.waitFor(() => expect(phoneFrames).toContainEqual(expect.objectContaining({ type: 'relay.presence', role: 'machine', online: true })))
    phone.close()
    await setup.stop()

    const restarted = new PluginRemoteSetup(options)
    cleanup.push(() => restarted.stop())
    restarted.resume()
    await vi.waitFor(() => expect(restarted.state).toBe('connected'))
    expect(JSON.parse(await readFile(configPath, 'utf8')).machineId).toBe(registered.machineId)
    expect(Object.keys(JSON.parse(await readFile(join(root, 'registry.json'), 'utf8')).machines))
      .toEqual([registered.machineId])
  })
})
