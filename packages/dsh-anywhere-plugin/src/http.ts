import type { IncomingMessage, ServerResponse } from 'node:http'

export function json(res: ServerResponse, status: number, value: unknown,
                     extraHeaders: Record<string, string> = {}): void {
  const body = JSON.stringify(value)
  res.writeHead(status, {
    'content-type': 'application/json; charset=utf-8',
    'content-length': Buffer.byteLength(body),
    'cache-control': 'no-store',
    'x-content-type-options': 'nosniff',
    ...extraHeaders,
  })
  res.end(body)
}

export async function readJson(req: IncomingMessage, limit = 1_048_576): Promise<unknown> {
  const chunks: Buffer[] = []
  let size = 0
  for await (const chunk of req) {
    const bytes = Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk)
    size += bytes.length
    if (size > limit) throw new HttpError(413, 'request body too large')
    chunks.push(bytes)
  }
  if (chunks.length === 0) return {}
  try {
    return JSON.parse(Buffer.concat(chunks).toString('utf8')) as unknown
  } catch {
    throw new HttpError(400, 'invalid JSON')
  }
}

export class HttpError extends Error {
  constructor(
    readonly status: number,
    message: string,
    readonly idempotencyOutcome: 'final' | 'retryable' | 'retryable-committed' | 'unknown' = status >= 500 ? 'unknown' : 'final',
  ) {
    super(message)
  }
}

/** The handler is certain that no side effect was accepted.  The idempotency
 * layer may let the same request id try again after this response. */
export class RetryableHttpError extends HttpError {
  constructor(status: number, message: string) {
    super(status, message, 'retryable')
  }
}
