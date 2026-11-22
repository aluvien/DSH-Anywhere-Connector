export function json(res, status, value, extraHeaders = {}) {
    const body = JSON.stringify(value);
    res.writeHead(status, {
        'content-type': 'application/json; charset=utf-8',
        'content-length': Buffer.byteLength(body),
        'cache-control': 'no-store',
        'x-content-type-options': 'nosniff',
        ...extraHeaders,
    });
    res.end(body);
}
export async function readJson(req, limit = 1_048_576) {
    const chunks = [];
    let size = 0;
    for await (const chunk of req) {
        const bytes = Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk);
        size += bytes.length;
        if (size > limit)
            throw new HttpError(413, 'request body too large');
        chunks.push(bytes);
    }
    if (chunks.length === 0)
        return {};
    try {
        return JSON.parse(Buffer.concat(chunks).toString('utf8'));
    }
    catch {
        throw new HttpError(400, 'invalid JSON');
    }
}
export class HttpError extends Error {
    status;
    idempotencyOutcome;
    constructor(status, message, idempotencyOutcome = status >= 500 ? 'unknown' : 'final') {
        super(message);
        this.status = status;
        this.idempotencyOutcome = idempotencyOutcome;
    }
}
/** The handler is certain that no side effect was accepted.  The idempotency
 * layer may let the same request id try again after this response. */
export class RetryableHttpError extends HttpError {
    constructor(status, message) {
        super(status, message, 'retryable');
    }
}
