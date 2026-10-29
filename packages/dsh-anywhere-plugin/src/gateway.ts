/** The Bridge authenticates its own paired clients before dispatching any
 * native call. Give those calls a real Host-owned Peer on newer Harnesses;
 * older Harnesses have no Peer API and keep their original request shape. */
interface HostPeer {
  readonly signal: AbortSignal
  dispose(): Promise<void>
}

interface GatewayContext {
  readonly connection?: {
    createPeer?(options: { principal: { kind: 'owner' }; interactions: 'none' }): HostPeer
  }
  readonly typertGateway?: { invoke(request: NativeRequest & { peer?: HostPeer }): Promise<unknown> }
  effect(callback: () => () => void | Promise<void>): unknown
}

interface NativeRequest {
  namespace: string
  method: string
  args: Record<string, unknown>
  signal?: AbortSignal
}

const peers = new WeakMap<GatewayContext, HostPeer>()

export function invokeNative(ctx: GatewayContext, request: NativeRequest): Promise<unknown> {
  if (ctx.typertGateway === undefined) throw new Error('Harness gateway is unavailable')
  let peer = peers.get(ctx)
  if (peer === undefined && ctx.connection?.createPeer !== undefined) {
    peer = ctx.connection.createPeer({ principal: { kind: 'owner' }, interactions: 'none' })
    peers.set(ctx, peer)
    const owned = peer
    ctx.effect(() => async () => {
      peers.delete(ctx)
      await owned.dispose()
    })
  }
  return ctx.typertGateway.invoke({ ...request, ...(peer === undefined ? {} : { peer }) })
}
