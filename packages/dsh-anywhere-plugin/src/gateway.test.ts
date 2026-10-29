import { describe, expect, it, vi } from 'vitest'
import { invokeNative } from './gateway.js'

describe('Harness gateway compatibility', () => {
  it('uses a real scoped Peer for catalogs, commands and uploads, and disposes it', async () => {
    const lifetime = new AbortController()
    const peer = { signal: lifetime.signal, dispose: vi.fn(async () => lifetime.abort()) }
    const createPeer = vi.fn(() => peer)
    const invoke = vi.fn(async (request) => {
      // The installed 0.2.1 gateway dereferences peer.signal at admission.
      expect(request.peer.signal.aborted).toBe(false)
      expect(request.peer).toBe(peer)
      return { presets: [] }
    })
    let dispose: (() => void | Promise<void>) | undefined
    const ctx = { connection: { createPeer }, typertGateway: { invoke },
      effect: (effect: () => () => void | Promise<void>) => { dispose = effect() } }
    for (const [namespace, method] of [['agentPresets', 'list'], ['commands', 'execute'], ['fileUploads', 'upload']]) {
      await invokeNative(ctx, { namespace: namespace!, method: method!, args: {}, signal: lifetime.signal })
    }
    expect(createPeer).toHaveBeenCalledExactlyOnceWith({ principal: { kind: 'owner' }, interactions: 'none' })
    await dispose!()
    expect(lifetime.signal.aborted).toBe(true)
    expect(peer.dispose).toHaveBeenCalledOnce()
  })

  it('retains the legacy request shape when the Host has no Peer API', async () => {
    const invoke = vi.fn(async () => ({}))
    const request = { namespace: 'agentPresets', method: 'list', args: {} }
    await invokeNative({ typertGateway: { invoke }, effect: () => undefined }, request)
    expect(invoke).toHaveBeenCalledExactlyOnceWith(request)
  })
})
