import { readFileSync } from 'node:fs'
import { mkdir, rename, writeFile, unlink } from 'node:fs/promises'
import { dirname, join } from 'node:path'
import { randomUUID } from 'node:crypto'

/** Desktop does not inherit the CLI launcher's environment. Reuse the same
 * private registration file instead of storing credentials in profile YAML. */
export function registeredBridgeToken(configPath: string): string | undefined {
  try {
    const config: unknown = JSON.parse(readFileSync(configPath, 'utf8'))
    if (typeof config !== 'object' || config === null || !('bridgeToken' in config)) return undefined
    return typeof config.bridgeToken === 'string' ? config.bridgeToken : undefined
  } catch { return undefined }
}

export interface EndpointHost {
  readonly origin?: string
  readonly port?: number
  readonly host?: string
}

export function loopbackOrigin(host: EndpointHost): string | undefined {
  let origin: string | undefined
  try {
    origin = host.origin
    if (origin === undefined) {
      const hostname = host.host === '::1' ? '[::1]' : host.host
      const port = host.port
      if (!['127.0.0.1', 'localhost', '[::1]'].includes(hostname ?? '')
        || !Number.isInteger(port) || port === undefined || port < 1 || port > 65535) return undefined
      origin = `http://${hostname}:${port}`
    }
  } catch { return undefined }
  try {
    const url = new URL(origin)
    if (!['http:', 'https:'].includes(url.protocol)
      || !['127.0.0.1', 'localhost', '[::1]'].includes(url.hostname)
      || url.username || url.password || url.pathname !== '/' || url.search || url.hash) return undefined
    const port = url.port || (url.protocol === 'https:' ? '443' : '80')
    return `${url.protocol}//${url.hostname}:${port}`
  } catch { return undefined }
}

/** Atomic, serialized publication. Stop waits for the active write; it never
 * unlinks a descriptor that might already belong to a replacement Host. */
export function publishBridgeEndpoint(host: EndpointHost, configPath: string, routePrefix: string,
  warn: (message: string) => void): () => Promise<void> {
  const target = join(dirname(configPath), 'bridge-endpoint.json')
  let stopped = false
  let published: string | undefined
  let pending: Promise<void> | undefined
  let warned = false
  const tick = () => {
    if (stopped || pending !== undefined) return
    const origin = loopbackOrigin(host)
    if (origin === undefined || origin === published) return
    pending = (async () => {
      const temporary = `${target}.${randomUUID()}.tmp`
      try {
        await mkdir(dirname(target), { recursive: true, mode: 0o700 })
        await writeFile(temporary, JSON.stringify({ version: 1, origin,
          port: Number(new URL(origin).port || (origin.startsWith('https:') ? 443 : 80)),
          routePrefix, pid: process.pid, writtenAt: new Date().toISOString() }) + '\n',
        { flag: 'wx', mode: 0o600 })
        if (!stopped) { await rename(temporary, target); published = origin }
        warned = false
      } catch {
        if (!warned) warn('Unable to publish local Bridge endpoint; check the connector config directory')
        warned = true
      } finally { await unlink(temporary).catch(() => undefined) }
    })().finally(() => { pending = undefined })
  }
  const timer = setInterval(tick, 1000)
  timer.unref()
  tick()
  return async () => { stopped = true; clearInterval(timer); await pending }
}
