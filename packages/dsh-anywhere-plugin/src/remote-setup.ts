import { existsSync } from 'node:fs'
import { hostname } from 'node:os'
import { dirname, join } from 'node:path'
import {
  DSHAnywhereConnector, enrollConnector, loadConfig, requestPairingCode,
  type ConnectorConfig, type ConnectorDependencies,
} from '@dsh-anywhere/connector'
import { pairingLink, relayHTTPSURL } from '@dsh-anywhere/protocol'
import { loopbackOrigin, type EndpointHost } from './desktop.js'

const defaultRelay = 'https://dsh.biaozhu.me'
const installerToken = /^enrollment_token='([A-Za-z0-9_-]{43})'\r?$/gm

export function resolvePluginRegistration(legacyConfigPath: string): { configPath: string; external: boolean } {
  if (existsSync(legacyConfigPath)) return { configPath: legacyConfigPath, external: true }
  return { configPath: join(dirname(legacyConfigPath), 'harness-plugin', 'connector.json'), external: false }
}

export async function readInstallerGrant(relayURL: string, request: typeof fetch): Promise<string> {
  const base = new URL(relayHTTPSURL(relayURL))
  if (base.protocol !== 'https:') throw new Error('Remote registration requires HTTPS.')
  const installer = new URL('/install', base)
  const response = await request(installer, { redirect: 'error', cache: 'no-store' })
  if (!response.ok) throw new Error('Relay registration is currently unavailable.')
  const script = await response.text()
  // Use the configured Relay as the source for a single transient grant only.
  // Installer paths, commands, and other response content stay inert.
  const tokens = Array.from(script.matchAll(installerToken))
  if (tokens.length !== 1) throw new Error('Relay did not provide a registration grant.')
  return tokens[0]![1]!
}

interface RemoteSetupOptions {
  configPath: string
  external: boolean
  host: EndpointHost
  prefix: string
  relay?: string
  trustBridge: (token: string) => void
  warn: (message: string) => void
  request?: typeof fetch
  webSocketFactory?: ConnectorDependencies['webSocketFactory']
}

export class PluginRemoteSetup {
  private connector: DSHAnywhereConnector | undefined
  private changing: Promise<void> | undefined
  private readonly lifetime = new AbortController()
  private readonly request: typeof fetch

  constructor(private readonly options: RemoteSetupOptions) {
    const request = options.request ?? fetch
    this.request = (input, init) => request(input, {
      ...init,
      signal: AbortSignal.any([this.lifetime.signal, AbortSignal.timeout(10_000),
        ...(init?.signal ? [init.signal] : [])]),
    })
  }

  get state(): 'disabled' | 'external' | 'connecting' | 'connected' | 'registered' {
    if (this.options.external) return 'external'
    if (this.connector?.status !== undefined && this.connector.status !== 'stopped') {
      return this.connector.bridgeConnected ? 'connected' : 'connecting'
    }
    return existsSync(this.options.configPath) ? 'registered' : 'disabled'
  }

  resume(): void {
    if (this.options.external || !existsSync(this.options.configPath)) return
    void this.enable().catch(() => this.options.warn('DSH Anywhere could not start its managed connection.'))
  }

  enable(): Promise<void> {
    if (this.options.external || (this.connector && this.connector.status !== 'stopped')) return Promise.resolve()
    return this.changing ??= this.start().finally(() => { this.changing = undefined })
  }

  async stop(): Promise<void> {
    this.lifetime.abort()
    await this.changing?.catch(() => undefined)
    await this.connector?.stop()
    this.connector = undefined
  }

  async pairingCode(): Promise<{ link: string; expiresAt: number }> {
    const config = await loadConfig(this.options.configPath, {})
    const code = await requestPairingCode(config, this.request)
    return {
      link: pairingLink({ relay: config.relayURL, machineId: config.machineId, pairingCode: code.code }),
      expiresAt: code.expiresAt,
    }
  }

  private async start(): Promise<void> {
    this.lifetime.signal.throwIfAborted()
    let config: ConnectorConfig
    if (existsSync(this.options.configPath)) {
      config = await loadConfig(this.options.configPath, {})
    } else {
      const bridgeBaseURL = this.bridgeBaseURL()
      const relay = this.options.relay ?? defaultRelay
      const enrollmentToken = await readInstallerGrant(relay, this.request)
      const enrolled = await enrollConnector({
        relay, enrollmentToken, machineName: hostname(), configPath: this.options.configPath, bridgeBaseURL,
      }, { fetch: this.request })
      config = enrolled.config
    }
    this.lifetime.signal.throwIfAborted()
    this.options.trustBridge(config.bridgeToken)
    this.connector = new DSHAnywhereConnector(config, {
      ...(this.options.request === undefined ? {} : { fetch: this.options.request }),
      ...(this.options.webSocketFactory === undefined ? {} : { webSocketFactory: this.options.webSocketFactory }),
      resolveBridgeBaseURL: async () => this.bridgeBaseURL(),
      logger: {
        info: () => undefined,
        warn: () => this.options.warn('DSH Anywhere is retrying its remote connection.'),
      },
    })
    this.connector.start()
  }

  private bridgeBaseURL(): string {
    const origin = loopbackOrigin(this.options.host)
    if (!origin) throw new Error('The local Harness endpoint is not available.')
    return origin + this.options.prefix
  }
}
