const peers = new WeakMap();
export function invokeNative(ctx, request) {
    if (ctx.typertGateway === undefined)
        throw new Error('Harness gateway is unavailable');
    let peer = peers.get(ctx);
    if (peer === undefined && ctx.connection?.createPeer !== undefined) {
        peer = ctx.connection.createPeer({ principal: { kind: 'owner' }, interactions: 'none' });
        peers.set(ctx, peer);
        const owned = peer;
        ctx.effect(() => async () => {
            peers.delete(ctx);
            await owned.dispose();
        });
    }
    return ctx.typertGateway.invoke({ ...request, ...(peer === undefined ? {} : { peer }) });
}
