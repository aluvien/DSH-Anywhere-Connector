import { randomBytes } from 'node:crypto';
export class PendingApprovals {
    pending = new Map();
    create(timeoutMs, signal) {
        const id = `approval_${randomBytes(12).toString('base64url')}`;
        let settle;
        let fail;
        const result = new Promise((resolve, reject) => {
            settle = resolve;
            fail = () => { reject(new Error('approval unavailable')); };
        });
        const timer = setTimeout(() => this.reject(id), timeoutMs);
        const onAbort = signal === undefined ? undefined : () => this.reject(id);
        signal?.addEventListener('abort', onAbort, { once: true });
        this.pending.set(id, {
            resolve: settle,
            reject: fail,
            timer,
            ...(signal === undefined ? {} : { signal }),
            ...(onAbort === undefined ? {} : { onAbort }),
        });
        return { id, result };
    }
    decide(id, decision) {
        const item = this.take(id);
        if (item === undefined)
            return false;
        item.resolve(decision);
        return true;
    }
    reject(id) {
        const item = this.take(id);
        if (item === undefined)
            return false;
        item.reject();
        return true;
    }
    rejectAll() {
        for (const id of [...this.pending.keys()])
            this.reject(id);
    }
    /** Removes a phone-side request after another approval surface wins. */
    discard(id) {
        this.take(id);
    }
    take(id) {
        const item = this.pending.get(id);
        if (item === undefined)
            return undefined;
        this.pending.delete(id);
        clearTimeout(item.timer);
        if (item.signal !== undefined && item.onAbort !== undefined) {
            item.signal.removeEventListener('abort', item.onAbort);
        }
        return item;
    }
}
