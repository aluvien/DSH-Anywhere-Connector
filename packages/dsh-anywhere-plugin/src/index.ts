import { hostname } from 'node:os'
import { randomUUID } from 'node:crypto'
import { createRequire } from 'node:module'
import { basename, dirname, join } from 'node:path'
import { homedir } from 'node:os'
import { mkdir, readFile, writeFile } from 'node:fs/promises'
import type { IncomingMessage, ServerResponse } from 'node:http'
import type { Duplex } from 'node:stream'
import type { Context } from '@deepseek-ai/cordis'
import type { ApprovalOutcome, ApprovalRequestEvent } from '@deepseek-ai/dsh-user-approval/types'
import { WebSocket, WebSocketServer } from 'ws'
import {
  AttachmentUploadPayloadSchema,
  CommandExecutePayloadSchema,
  EventEnvelopeSchema,
  ModelCatalogPayloadSchema,
  PromptSendPayloadSchema,
  PROTOCOL_VERSION,
  QuestionAnswerPayloadSchema,
  pairingLink,
  relayHTTPSURL,
  type EventEnvelope,
  type QuestionAnswerItem,
} from '@dsh-anywhere/protocol'
import { PairingAuthority } from './auth.js'
import { HttpError, json, readJson } from './http.js'
import { PendingApprovals, type ApprovalDecision } from './pending-approvals.js'
import { PendingQuestions, firstAnswered } from './pending-questions.js'
import { ReplayBuffer } from './replay.js'

export const name = 'dsh-anywhere-native-bridge'
// workspaceRegistry is the source of truth for sessions archived from the
// Harness web UI. It must be injected explicitly or Cordis exposes it as a
// throwing optional getter and the mobile list cannot distinguish archived
// sessions from active ones.
export const inject = ['webServer', 'sessionController', 'workspaceRegistry']

export interface Config {
  readonly routePrefix?: string
  readonly pairingCodeTtlMs?: number
  readonly connectorToken?: string
  readonly pairingRateLimitMaxAttempts?: number
  readonly pairingRateLimitWindowMs?: number
  readonly approvalTimeoutMs?: number
  /** A question blocks a tool call, so it defaults to a much longer deadline. */
  readonly questionTimeoutMs?: number
  readonly eventBufferSize?: number
  /**
   * Where the connector keeps connector.json. The local pairing page reads it
   * to build a scannable QR, so it must be the operator's own file rather than
   * a copy served over the network.
   */
  readonly connectorConfigPath?: string
}

export const CONNECTOR_DEVICE_ID = 'dsh-anywhere-connector'
export const CONNECTOR_DEVICE_NAME = 'DSH Anywhere Connector'

export class PairingRateLimiter {
  private readonly failuresByAddress = new Map<string, { count: number; resetAt: number }>()

  constructor(
    private readonly maxAttempts = 5,
    private readonly windowMs = 60_000,
  ) {
    if (!Number.isSafeInteger(maxAttempts) || maxAttempts < 1) {
      throw new Error('pairingRateLimitMaxAttempts must be a positive integer')
    }
    if (!Number.isSafeInteger(windowMs) || windowMs < 1) {
      throw new Error('pairingRateLimitWindowMs must be a positive integer')
    }
  }

  tryConsume(address: string, now = Date.now()): boolean {
    const current = this.failuresByAddress.get(address)
    if (current === undefined || now >= current.resetAt) {
      this.failuresByAddress.set(address, { count: 1, resetAt: now + this.windowMs })
      return true
    }
    if (current.count >= this.maxAttempts) return false
    current.count += 1
    return true
  }

  clear(address: string): void {
    this.failuresByAddress.delete(address)
  }
}

type NativeEventInput = Pick<EventEnvelope, 'type' | 'payload'> & {
  readonly sessionId?: string
  readonly deviceId?: string
}

interface NativeContext extends Context {
  readonly webServer: {
    register(route: {
      kind: 'exact' | 'prefix'
      path: string
      handler: (req: IncomingMessage, res: ServerResponse) => void | Promise<void>
    }): () => void
    registerUpgrade(route: {
      path: string
      handler: (req: IncomingMessage, socket: Duplex, head: Buffer) => void | Promise<void>
    }): () => void
  }
  readonly sessionController: {
    list(request: Record<string, never>, signal: AbortSignal): Promise<{ items: unknown[] }>
    create(request: { cwd?: string; workspaceId?: string; agentPreset?: string; model?: { provider: string; model: string; reasoningEffort?: string }}): Promise<{ sessionId: string; agentPreset?: string }>
    selectModel(request: { sessionId: string; provider: string; model: string; reasoningEffort?: string }): Promise<unknown>
    modelCatalog(): Promise<unknown>
    resolveAgent(sessionId: string): Promise<{ agent: unknown } | { error: unknown }>
    prompt(request: {
      requestId: string
      sessionId: string
      mode: 'queue' | 'steer'
      content: readonly ({ type: 'text'; text: string } | { type: 'image'; mediaType: string; data: string; name?: string | undefined } | { type: 'file'; receiptId: string })[]
      clientTimeZone?: string
    }, signal: AbortSignal): Promise<{ accepted: true }>
    cancel(request: { sessionId: string }): { accepted: true }
    inspect(sessionId: string, signal?: AbortSignal): Promise<{ events: unknown[] }>
  }
  readonly workspaceRegistry?: {
    list(): readonly { id: string; path: string; title: string; sessionIds: readonly string[] }[]
    readonly archivedSessionIds: readonly string[]
    archiveSession(sessionId: string): Promise<void>
    unarchiveSession?(sessionId: string): Promise<void>
  }
  readonly approval?: {
    setPolicy(agent: unknown, policy: 'ask' | 'never'): void
  }
  readonly typertGateway?: {
    invoke(request: { namespace: string; method: string; args: Record<string, unknown>; signal?: AbortSignal }): Promise<unknown>
  }
}

interface JsonObject {
  readonly [key: string]: unknown
}

type PermissionMode = 'ask' | 'never' | 'read-only' | 'workspace-write' | 'danger-full-access'

/**
 * UI-only metadata that is intentionally kept outside the Harness session log.
 * The workspace package owns the canonical archive set; this store keeps the
 * connector's per-device presentation choices (and supports unarchive on older
 * Harness builds that only expose archiveSession()).
 */
class SessionMetadataStore {
  private archived = new Set<string>()
  private unarchived = new Set<string>()
  private permissions = new Map<string, PermissionMode>()
  readonly ready: Promise<void>

  constructor(private readonly path: string) {
    this.ready = this.load()
  }

  isArchived(sessionId: string, registry?: NativeContext['workspaceRegistry']): boolean {
    if (this.unarchived.has(sessionId)) return false
    return this.archived.has(sessionId) || registry?.archivedSessionIds.includes(sessionId) === true
  }

  permission(sessionId: string): PermissionMode | undefined {
    return this.permissions.get(sessionId)
  }

  async setArchived(sessionId: string, archived: boolean): Promise<void> {
    if (archived) {
      this.archived.add(sessionId)
      this.unarchived.delete(sessionId)
    } else {
      this.archived.delete(sessionId)
      // Current Harness releases expose durable archive but not a public
      // unarchive call. Keep an explicit per-device override so the mobile
      // client can restore the session immediately and older connectors can
      // still present the expected list.
      this.unarchived.add(sessionId)
    }
    await this.persist()
  }

  async setPermission(sessionId: string, mode: PermissionMode): Promise<void> {
    this.permissions.set(sessionId, mode)
    await this.persist()
  }

  private async load(): Promise<void> {
    try {
      const parsed = JSON.parse(await readFile(this.path, 'utf8')) as JsonObject
      const archived = parsed.archived
      if (Array.isArray(archived)) for (const id of archived) if (typeof id === 'string') this.archived.add(id)
      const unarchived = parsed.unarchived
      if (Array.isArray(unarchived)) for (const id of unarchived) if (typeof id === 'string') this.unarchived.add(id)
      const permissions = parsed.permissions
      if (typeof permissions === 'object' && permissions !== null && !Array.isArray(permissions)) {
        for (const [id, mode] of Object.entries(permissions)) {
          if (isPermissionMode(mode)) this.permissions.set(id, mode)
        }
      }
    } catch {
      // A missing or corrupt presentation file must never prevent Harness from
      // starting; the durable Harness session store remains authoritative.
    }
  }

  private async persist(): Promise<void> {
    await mkdir(dirname(this.path), { recursive: true })
    await writeFile(this.path, JSON.stringify({
      archived: [...this.archived],
      unarchived: [...this.unarchived],
      permissions: Object.fromEntries(this.permissions),
    }, null, 2), { mode: 0o600 })
  }
}

function isPermissionMode(value: unknown): value is PermissionMode {
  return value === 'ask' || value === 'never' || value === 'read-only' || value === 'workspace-write' || value === 'danger-full-access'
}

function isPermissionPreset(value: PermissionMode): value is 'workspace-write' | 'danger-full-access' {
  return value === 'workspace-write' || value === 'danger-full-access'
}

function metadataPath(): string {
  return join(process.env.DSH_ANYWHERE_DATA_DIR ?? join(homedir(), 'Library', 'Application Support', 'DSH Anywhere'), 'session-metadata.json')
}

/** Mirrors the connector's own defaultConfigPath so both resolve one file. */
function defaultConnectorConfigPath(): string {
  const override = process.env.DSH_ANYWHERE_CONFIG
  if (override !== undefined && override.length > 0) return override
  if (process.platform === 'darwin') {
    return join(homedir(), 'Library', 'Application Support', 'DSH Anywhere', 'connector.json')
  }
  return join(process.env.XDG_CONFIG_HOME ?? join(homedir(), '.config'), 'dsh-anywhere', 'connector.json')
}

/**
 * The pairing page carries a live pairing secret, so it must never be
 * reachable from the public internet. A loopback peer address alone is not
 * enough: a reverse proxy running on this same Mac also appears to come from
 * 127.0.0.1. Checking the Host header closes that hole, because a proxied
 * request carries the public hostname instead of localhost.
 */
function isLoopbackRequest(req: IncomingMessage): boolean {
  const address = req.socket?.remoteAddress ?? ''
  if (address !== '127.0.0.1' && address !== '::1' && address !== '::ffff:127.0.0.1') return false
  const host = (header(req, 'host') ?? '').toLowerCase()
  const hostname = host.startsWith('[') ? host.slice(0, host.indexOf(']') + 1) : (host.split(':')[0] ?? '')
  return hostname === 'localhost' || hostname === '127.0.0.1' || hostname === '[::1]' || hostname === '::1'
}

interface PairingMaterial {
  readonly link: string
  readonly relay: string
  readonly machineId: string
}

async function readPairingMaterial(configPath: string): Promise<PairingMaterial | undefined> {
  let parsed: unknown
  try {
    parsed = JSON.parse(await readFile(configPath, 'utf8'))
  } catch {
    return undefined
  }
  const record = recordOf(parsed)
  const relay = typeof record.relayURL === 'string' ? record.relayURL : undefined
  const machineId = typeof record.machineId === 'string' ? record.machineId : undefined
  const pairingSecret = typeof record.pairingSecret === 'string' ? record.pairingSecret : undefined
  if (relay === undefined || machineId === undefined || pairingSecret === undefined) return undefined
  try {
    return {
      link: pairingLink({ relay, machineId, pairingSecret }),
      relay: relayHTTPSURL(relay),
      machineId,
    }
  } catch {
    return undefined
  }
}

/**
 * qrcode-generator declares its export with `export =`, which this workspace's
 * verbatimModuleSyntax ESM configuration cannot default-import. Loading it via
 * createRequire keeps one dependency without loosening tsconfig for every
 * package. Resolution is lazy so a missing install degrades to a message on
 * this page instead of preventing the bridge from starting.
 */
interface QRCodeFactory {
  (typeNumber: number, errorCorrectionLevel: 'L' | 'M' | 'Q' | 'H'): {
    addData(data: string): void
    make(): void
    createSvgTag(options?: { cellSize?: number; margin?: number; scalable?: boolean }): string
  }
}

let qrCodeFactory: QRCodeFactory | undefined

function qrCodeFactoryOf(): QRCodeFactory {
  qrCodeFactory ??= createRequire(import.meta.url)('qrcode-generator') as QRCodeFactory
  return qrCodeFactory
}

async function pairingPageHTML(configPath: string): Promise<string> {
  const material = await readPairingMaterial(configPath)
  if (material === undefined) {
    return pairingPageShell(`
      <h1>No pairing details yet</h1>
      <p class="sub">This Mac has no stored pairing secret.</p>
      <p class="hint">Re-run the connector setup, or add <code>pairingSecret</code> to
      <code>connector.json</code>, then reload this page.</p>
    `)
  }
  let qr: string
  try {
    const code = qrCodeFactoryOf()(0, 'M')
    code.addData(material.link)
    code.make()
    qr = `<div class="qr">${code.createSvgTag({ cellSize: 4, margin: 1, scalable: true })}</div>`
  } catch (error) {
    return pairingPageShell(`
      <h1>QR code unavailable</h1>
      <p class="sub">${escapeHTML(error instanceof Error ? error.message : String(error))}</p>
      <p class="hint">Install the plugin dependencies with <code>pnpm install</code>, then reload.</p>
    `)
  }
  return pairingPageShell(`
    <h1>Pair this Mac</h1>
    <p class="sub">Open DSH Anywhere on your iPhone, tap Scan, and point it here.</p>
    ${qr}
    <dl>
      <dt>Relay</dt><dd>${escapeHTML(material.relay)}</dd>
      <dt>Machine</dt><dd>${escapeHTML(material.machineId)}</dd>
    </dl>
    <button id="copy" type="button">Copy pairing link</button>
    <p class="hint">Served on loopback only &mdash; the secret never leaves this Mac.</p>
  `, material.link)
}

function pairingPageShell(body: string, link?: string): string {
  const script = link === undefined ? '' : `
  <script>
    const link = ${JSON.stringify(link).replaceAll('<', '\\u003c')};
    const button = document.getElementById('copy');
    button.addEventListener('click', async () => {
      try { await navigator.clipboard.writeText(link); button.textContent = 'Copied'; }
      catch { button.textContent = 'Copy failed'; }
      setTimeout(() => { button.textContent = 'Copy pairing link'; }, 1500);
    });
  </script>`
  return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="robots" content="noindex, nofollow">
<title>DSH Anywhere &mdash; pair this Mac</title>
<style>
  :root { color-scheme: light dark; }
  body { margin: 0; min-height: 100vh; display: flex; align-items: center; justify-content: center;
         background: #0b0d10; color: #e8eaed;
         font: 15px/1.5 -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; }
  main { padding: 32px; max-width: 420px; text-align: center; }
  h1 { margin: 0 0 6px; font-size: 19px; }
  p.sub { margin: 0 0 20px; color: #9aa0a6; font-size: 13px; }
  p.hint { margin: 16px 0 0; color: #6b7280; font-size: 11px; }
  code { font-family: ui-monospace, SFMono-Regular, Menlo, monospace; color: #c9cdd2; }
  .qr { display: inline-block; padding: 14px; border-radius: 14px; background: #fff; line-height: 0; }
  .qr svg { display: block; width: 236px; height: 236px; }
  dl { display: grid; grid-template-columns: auto 1fr; gap: 4px 12px; margin: 22px 0 0;
       font-size: 12px; text-align: left; }
  dt { color: #6b7280; }
  dd { margin: 0; color: #c9cdd2; word-break: break-all;
       font-family: ui-monospace, SFMono-Regular, Menlo, monospace; }
  button { margin-top: 20px; padding: 9px 16px; border: 1px solid #2f3338; border-radius: 9px;
           background: #17191d; color: #e8eaed; font-size: 13px; cursor: pointer; }
</style>
</head>
<body>
<main>${body}</main>${script}
</body>
</html>`
}

function escapeHTML(value: string): string {
  return value
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&#39;')
}

export function apply(baseCtx: Context, config: Config = {}): void {
  const ctx = baseCtx as NativeContext
  const prefix = config.routePrefix ?? '/dsh-anywhere/v1'
  const machineId = `machine_${hostname()}`
  const connectorToken = config.connectorToken ?? process.env.DSH_ANYWHERE_CONNECTOR_TOKEN
  if (connectorToken !== undefined && connectorToken.length > 0 && connectorToken.length < 32) {
    throw new Error('connectorToken must be at least 32 characters when provided')
  }
  const announcePairingCode = (snapshot: { code: string; expiresAt: number }): void => {
    const message = `DSH Anywhere pairing code: ${snapshot.code} (expires ${new Date(snapshot.expiresAt).toISOString()})`
    ctx.logger.info(message)
    console.log(`[dsh-anywhere] ${message}`)
  }
  const pairing = new PairingAuthority(config.pairingCodeTtlMs ?? 10 * 60_000, announcePairingCode)
  if (connectorToken !== undefined && connectorToken.length > 0) {
    pairing.registerTrustedDevice({
      id: CONNECTOR_DEVICE_ID,
      name: CONNECTOR_DEVICE_NAME,
      token: connectorToken,
    })
  }
  const pairingRateLimiter = new PairingRateLimiter(
    config.pairingRateLimitMaxAttempts ?? 5,
    config.pairingRateLimitWindowMs ?? 60_000,
  )
  const replay = new ReplayBuffer<EventEnvelope>(config.eventBufferSize ?? 2_000)
  const approvals = new PendingApprovals()
  const questions = new PendingQuestions()
  const metadata = new SessionMetadataStore(metadataPath())
  const clients = new Set<WebSocket>()
  const wss = new WebSocketServer({ noServer: true })

  const publish = (event: NativeEventInput, recipients: Iterable<WebSocket> = clients): void => {
    const sequence = replay.latestSequence + 1
    const next = EventEnvelopeSchema.parse({
      version: PROTOCOL_VERSION,
      messageId: randomUUID(),
      timestamp: Date.now(),
      machineId,
      deviceId: event.deviceId ?? 'broadcast',
      sequence,
      ...event,
    })
    const entry = replay.append(next)
    const wire = JSON.stringify({ ...next, sequence: entry.sequence })
    for (const client of recipients) {
      if (client.readyState === WebSocket.OPEN) client.send(wire)
    }
  }

  const route = ctx.webServer.register({
    kind: 'prefix',
    path: prefix,
    handler: async (req, res) => {
      try {
        await handleHttp(
          ctx, req, res, prefix, pairing, pairingRateLimiter, approvals, machineId, metadata, publish,
          config.connectorConfigPath ?? defaultConnectorConfigPath(),
          questions,
        )
      } catch (error) {
        const status = error instanceof HttpError ? error.status : 500
        json(res, status, { error: error instanceof Error ? error.message : String(error) })
      }
    },
  })

  const upgrade = ctx.webServer.registerUpgrade({
    path: `${prefix}/events`,
    handler: (req, socket, head) => {
      const device = pairing.authenticate(header(req, 'authorization'))
      if (device === undefined) {
        socket.write('HTTP/1.1 401 Unauthorized\r\nConnection: close\r\n\r\n')
        socket.destroy()
        return
      }
      wss.handleUpgrade(req, socket, head, (client) => {
        clients.add(client)
        const after = parseAfter(req.url)
        for (const entry of replay.after(after)) {
          client.send(JSON.stringify({ ...entry.event, sequence: entry.sequence }))
        }
        publish({
          deviceId: device.id,
          type: 'connection.ready',
          payload: {
            machineId,
            deviceId: device.id,
            serverTime: Date.now(),
          capabilities: [
            'sessions', 'workspaces', 'archive', 'prompt', 'attachments',
            'cancel', 'approval', 'permissions', 'models', 'commands', 'usage', 'replay', 'questions',
          ],
            ...(after > 0 ? { resumedFrom: after } : {}),
          },
        }, [client])
        void (async () => {
          const items = await listSummaries(ctx, metadata, false)
          publish({ deviceId: device.id, type: 'session.snapshot', payload: items }, [client])
          await publishModelCatalog(ctx, publish, device.id)
          if (after !== 0) return
          let remaining = 1_000
          for (const item of items.slice(0, 25)) {
            if (remaining <= 0 || client.readyState !== WebSocket.OPEN) break
            const summary = normalizeSessionSummary(item, ctx, metadata)
            const inspection = await ctx.sessionController.inspect(summary.id, AbortSignal.timeout(15_000))
            const recent = inspection.events.slice(-Math.min(200, remaining))
            const historyToolNames = new Map<string, string>()
            const historyUsageCounters = new Map<string, { rounds: number; steps: number; contextWindow?: number }>()
            for (const event of recent) {
              const normalized = normalizeSessionEvents(summary.id, event, historyToolNames, historyUsageCounters)
              for (const next of normalized) publish({ ...next, deviceId: device.id }, [client])
            }
            remaining -= recent.length
          }
        })().catch((error: unknown) => {
          publish({
            deviceId: device.id,
            type: 'protocol.error',
            payload: { code: 'session-list-failed', message: String(error), retryable: true },
          }, [client])
        })
        client.once('close', () => {
          clients.delete(client)
          if (clients.size === 0) approvals.rejectAll()
        })
      })
    },
  })

  const toolNames = new Map<string, string>()
  const usageCounters = new Map<string, { rounds: number; steps: number }>()
  ctx.on('session/event' as never, ((session: { id: string }, event: unknown) => {
    const normalized = normalizeSessionEvents(session.id, event, toolNames, usageCounters)
    for (const next of normalized) publish(next)
  }) as never, { global: true })

  ctx.on('session/created' as never, ((session: unknown) => {
    publish({ type: 'session.created', payload: normalizeLiveSession(session, ctx, metadata) })
  }) as never, { global: true })

  ctx.on('agent/status' as never, ((value: { agent: { id: string }; status: string }) => {
    publish({
      type: 'turn.state.changed',
      sessionId: value.agent.id,
      payload: { sessionId: value.agent.id, state: value.status },
    })
  }) as never, { global: true })

  ctx.on('approval/request' as never, (async function (
    request: ApprovalRequestEvent,
    next: () => Promise<ApprovalOutcome>,
  ): Promise<ApprovalOutcome> {
    if (clients.size === 0) return next()
    const pending = approvals.create(config.approvalTimeoutMs ?? 120_000, request.signal)
    publish({
      type: 'approval.requested',
      sessionId: request.agent.id,
      payload: {
        id: pending.id,
        sessionId: request.agent.id,
        toolName: request.toolName,
        reason: request.reason ?? `Allow ${request.toolName}?`,
        expiresAt: Date.now() + (config.approvalTimeoutMs ?? 120_000),
      },
    })
    try {
      const decision = await pending.result
      publish({
        type: 'approval.resolved',
        sessionId: request.agent.id,
        payload: { id: pending.id, allowed: decision === 'allowed-once' },
      })
      return decision
    } catch {
      publish({ type: 'approval.resolved', sessionId: request.agent.id, payload: { id: pending.id, allowed: false } })
      return 'unavailable'
    }
  }) as never, { global: true, prepend: true })

  // Registered on the same Agent-scoped waterfall as the web UI's answerer.
  // Claiming the request only when a device is attached keeps the Harness TUI
  // and browser clients working when no phone is connected.
  ctx.on('user-questions/request' as never, (async function (
    request: {
      questions: readonly {
        id: string
        question: string
        header?: string
        detail?: string
        options?: readonly { label: string; description?: string }[]
        multiSelect?: boolean
      }[]
      agent?: { id: string }
      signal?: AbortSignal
    },
    next: () => Promise<{ answers: readonly QuestionAnswerItem[] }>,
  ): Promise<{ answers: readonly QuestionAnswerItem[] }> {
    if (clients.size === 0) return next()
    const sessionId = request.agent?.id ?? 'unknown'
    const pending = questions.create(config.questionTimeoutMs ?? 600_000, request.signal)
    publish({
      type: 'question.asked',
      sessionId,
      payload: {
        id: pending.id,
        sessionId,
        questions: request.questions.map((question) => ({
          id: question.id,
          question: question.question,
          ...(question.header === undefined ? {} : { header: question.header }),
          ...(question.detail === undefined ? {} : { detail: question.detail }),
          ...(question.options === undefined ? {} : {
            options: question.options.map((option) => ({
              label: option.label,
              ...(option.description === undefined ? {} : { description: option.description }),
            })),
          }),
          ...(question.multiSelect === undefined ? {} : { multiSelect: question.multiSelect }),
        })),
        expiresAt: Date.now() + (config.questionTimeoutMs ?? 600_000),
      },
    })
    try {
      // Offer the question to the Harness UI as well, so an attached phone
      // never takes the question away from an open browser. Whichever human
      // answers first wins; the loser's surface is dismissed below.
      const winner = await firstAnswered(
        pending.result.then(
          (answers) => ({ answers }),
          () => undefined,
        ),
        next(),
      )
      publish({ type: 'question.resolved', sessionId, payload: { id: pending.id, sessionId } })
      if (winner === undefined) {
        // Both surfaces went quiet: no UI answerer is mounted and the phone
        // never answered. The tool awaits this promise, so it must settle as a
        // tool error rather than hang.
        throw new Error('no user-questions answerer accepted the request')
      }
      // Releases the phone-side entry when the browser answered first, so a
      // late tap on the dismissed card cannot resolve a dead promise.
      questions.discard(pending.id)
      return winner
    } catch (error) {
      publish({ type: 'question.resolved', sessionId, payload: { id: pending.id, sessionId } })
      throw error instanceof Error ? error : new Error(String(error))
    }
  }) as never, { global: true, prepend: true })

  ctx.effect(() => () => {
    route()
    upgrade()
    approvals.rejectAll()
    questions.rejectAll(new Error('the connector shut down before the question was answered'))
    for (const client of clients) client.close(1001, 'plugin disposed')
    wss.close()
  }, 'dsh-anywhere: routes and sockets')

}

async function handleHttp(
  ctx: NativeContext,
  req: IncomingMessage,
  res: ServerResponse,
  prefix: string,
  pairing: PairingAuthority,
  pairingRateLimiter: PairingRateLimiter,
  approvals: PendingApprovals,
  machineId: string,
  metadata: SessionMetadataStore,
  publish: (event: NativeEventInput, recipients?: Iterable<WebSocket>) => void,
  connectorConfigPath: string,
  questions: PendingQuestions,
): Promise<void> {
  await metadata.ready
  const url = new URL(req.url ?? '/', 'http://localhost')
  const path = url.pathname.slice(prefix.length) || '/'

  if (req.method === 'GET' && path === '/health') {
    json(res, 200, { ok: true, version: PROTOCOL_VERSION, machineId })
    return
  }
  // The pairing page renders a live pairing secret, so it is deliberately
  // unauthenticated (a browser cannot send a bearer token) but restricted to
  // loopback. See isLoopbackRequest for why the Host header is checked too.
  if (req.method === 'GET' && path === '/pairing') {
    if (!isLoopbackRequest(req)) throw new HttpError(404, 'not found')
    const html = await pairingPageHTML(connectorConfigPath)
    res.writeHead(200, {
      'content-type': 'text/html; charset=utf-8',
      'cache-control': 'no-store',
      'referrer-policy': 'no-referrer',
      'x-content-type-options': 'nosniff',
    })
    res.end(html)
    return
  }
  if (req.method === 'POST' && path === '/pair') {
    const remoteAddress = req.socket?.remoteAddress ?? 'unknown'
    if (!pairingRateLimiter.tryConsume(remoteAddress)) {
      throw new HttpError(429, 'too many pairing attempts')
    }
    const body = objectOf(await readJson(req))
    const device = pairing.claim(stringOf(body.code), stringOf(body.deviceName))
    if (device === undefined) throw new HttpError(401, 'invalid or expired pairing code')
    pairingRateLimiter.clear(remoteAddress)
    json(res, 201, { deviceId: device.id, token: device.token, machineId })
    return
  }

  const device = pairing.authenticate(header(req, 'authorization'))
  if (device === undefined) throw new HttpError(401, 'unauthorized')

  if (req.method === 'GET' && path === '/sessions') {
    const includeArchived = url.searchParams.get('includeArchived') === 'true'
    json(res, 200, { items: await listSummaries(ctx, metadata, includeArchived) })
    return
  }
  if (req.method === 'GET' && path === '/models') {
    json(res, 200, await ctx.sessionController.modelCatalog())
    return
  }
  if (req.method === 'POST' && path === '/sessions') {
    const body = objectOf(await readJson(req))
    const cwd = optionalStringOf(body.cwd)
    const workspaceId = optionalStringOf(body.workspaceId)
    const agentPreset = optionalStringOf(body.agentPreset)
    const result = await ctx.sessionController.create({
      ...(cwd === undefined ? {} : { cwd }),
      ...(workspaceId === undefined ? {} : { workspaceId }),
      ...(agentPreset === undefined ? {} : { agentPreset }),
    })
    const summary = (await listSummaries(ctx, metadata, true)).find((item) => item.id === result.sessionId)
    if (body.model !== undefined) {
      const model = modelSelectionOf(body.model)
      await ctx.sessionController.selectModel({ sessionId: result.sessionId, ...model })
    }
    json(res, 201, { ...result, ...(summary === undefined ? {} : { summary }) })
    return
  }

  const promptMatch = /^\/sessions\/([^/]+)\/prompt$/.exec(path)
  if (req.method === 'POST' && promptMatch !== null) {
    const body = objectOf(await readJson(req))
    const parsed = PromptSendPayloadSchema.safeParse({
      ...(body.text === undefined ? {} : { text: body.text }),
      ...(body.content === undefined ? {} : { content: body.content }),
      ...(body.mode === undefined ? {} : { mode: body.mode }),
      ...(body.clientTimeZone === undefined ? {} : { clientTimeZone: body.clientTimeZone }),
    })
    if (!parsed.success) throw new HttpError(400, 'prompt requires text or an attachment')
    const text = typeof parsed.data.text === 'string' ? parsed.data.text.trim() : ''
    const mode = parsed.data.mode === 'steer' ? 'steer' : 'queue'
    const requestId = optionalStringOf(body.requestId) ?? randomUUID()
    const clientTimeZone = parsed.data.clientTimeZone
    const content = parsed.data.content ?? (text.length === 0 ? [] : [{ type: 'text' as const, text }])
    const result = await ctx.sessionController.prompt({
      requestId,
      sessionId: decodeURIComponent(promptMatch[1]!),
      mode,
      content,
      ...(clientTimeZone === undefined ? {} : { clientTimeZone }),
    }, AbortSignal.timeout(15_000))
    json(res, 202, { ...result, requestId })
    return
  }

  const cancelMatch = /^\/sessions\/([^/]+)\/cancel$/.exec(path)
  if (req.method === 'POST' && cancelMatch !== null) {
    json(res, 202, ctx.sessionController.cancel({ sessionId: decodeURIComponent(cancelMatch[1]!) }))
    return
  }

  const archiveMatch = /^\/sessions\/([^/]+)\/archive$/.exec(path)
  if (req.method === 'POST' && archiveMatch !== null) {
    const body = objectOf(await readJson(req))
    const sessionId = decodeURIComponent(archiveMatch[1]!)
    const archived = body.archived === true
    const workspaceRegistry = workspaceRegistryOf(ctx)
    if (archived) await workspaceRegistry?.archiveSession(sessionId)
    const registryUnarchive = workspaceRegistry?.unarchiveSession
    if (!archived && registryUnarchive !== undefined) await registryUnarchive(sessionId)
    await metadata.setArchived(sessionId, archived)
    const summary = (await listSummaries(ctx, metadata, true)).find((item) => item.id === sessionId)
    json(res, 202, { accepted: true, ...(summary === undefined ? {} : { summary }) })
    return
  }

  const modelMatch = /^\/sessions\/([^/]+)\/model$/.exec(path)
  if (req.method === 'POST' && modelMatch !== null) {
    const model = modelSelectionOf(await readJson(req))
    const sessionId = decodeURIComponent(modelMatch[1]!)
    const result = await ctx.sessionController.selectModel({ sessionId, ...model })
    json(res, 202, result)
    return
  }

  const permissionMatch = /^\/sessions\/([^/]+)\/permission$/.exec(path)
  if (req.method === 'POST' && permissionMatch !== null) {
    const body = objectOf(await readJson(req))
    const mode = permissionModeOf(body.mode)
    const sessionId = decodeURIComponent(permissionMatch[1]!)
    if (!isPermissionPreset(mode)) {
      throw new HttpError(400, 'Harness permission presets are workspace-write and danger-full-access')
    }
    // Harness persists a preset as sandbox mode plus approval policy. Calling
    // its native command keeps the actual sandbox aligned with the mobile UI.
    const result = await executeCommand(ctx, sessionId, `/permission ${mode}`, [])
    const failure = remoteFailureOf(result)
    if (failure !== undefined) throw new HttpError(502, failure)
    await metadata.setPermission(sessionId, mode)
    publishPermission(sessionId, mode, publish)
    json(res, 202, { accepted: true, mode })
    return
  }

  const commandMatch = /^\/sessions\/([^/]+)\/command$/.exec(path)
  if (req.method === 'POST' && commandMatch !== null) {
    const body = objectOf(await readJson(req))
    const parsed = CommandExecutePayloadSchema.safeParse(body)
    if (!parsed.success) throw new HttpError(400, 'command line is required')
    const sessionId = decodeURIComponent(commandMatch[1]!)
    const result = await executeCommand(ctx, sessionId, parsed.data.line, parsed.data.attachments ?? [])
    json(res, 202, result)
    return
  }

  const uploadMatch = /^\/sessions\/([^/]+)\/attachments$/.exec(path)
  if (req.method === 'POST' && uploadMatch !== null) {
    const body = AttachmentUploadPayloadSchema.parse(await readJson(req))
    const sessionId = decodeURIComponent(uploadMatch[1]!)
    const result = await uploadAttachment(ctx, sessionId, body.data, body.name)
    json(res, 201, result)
    return
  }

  const approvalMatch = /^\/approvals\/([^/]+)\/decision$/.exec(path)
  if (req.method === 'POST' && approvalMatch !== null) {
    const body = objectOf(await readJson(req))
    const decision = approvalDecisionOf(body.decision)
    if (!approvals.decide(decodeURIComponent(approvalMatch[1]!), decision)) {
      throw new HttpError(409, 'approval is no longer pending')
    }
    json(res, 202, { accepted: true })
    return
  }

  const answerMatch = /^\/questions\/([^/]+)\/answer$/.exec(path)
  if (req.method === 'POST' && answerMatch !== null) {
    // The path id is authoritative: a stale client cannot answer a different
    // question than the one it was handed.
    const parsed = QuestionAnswerPayloadSchema.safeParse({
      ...objectOf(await readJson(req)),
      questionId: decodeURIComponent(answerMatch[1]!),
    })
    if (!parsed.success) throw new HttpError(400, 'every question needs an id and its selections')
    if (!questions.answer(parsed.data.questionId, parsed.data.answers)) {
      throw new HttpError(409, 'question is no longer pending')
    }
    json(res, 202, { accepted: true })
    return
  }

  throw new HttpError(404, 'not found')
}

async function listSummaries(
  ctx: NativeContext,
  metadata: SessionMetadataStore,
  includeArchived: boolean,
): Promise<ReturnType<typeof normalizeSessionSummary>[]> {
  const result = await ctx.sessionController.list({}, AbortSignal.timeout(15_000))
  const summaries = result.items.map((item) => normalizeSessionSummary(item, ctx, metadata))
  return includeArchived ? summaries : summaries.filter((item) => item.archived !== true)
}

async function publishModelCatalog(
  ctx: NativeContext,
  publish: (event: NativeEventInput, recipients?: Iterable<WebSocket>) => void,
  deviceId: string,
): Promise<void> {
  try {
    const payload = ModelCatalogPayloadSchema.parse(await ctx.sessionController.modelCatalog())
    publish({ deviceId, type: 'model.catalog', payload })
  } catch (error) {
    publish({
      deviceId,
      type: 'protocol.error',
      payload: { code: 'model-catalog-failed', message: String(error), retryable: true },
    })
  }
}

function publishPermission(
  sessionId: string,
  mode: PermissionMode,
  publish: (event: NativeEventInput, recipients?: Iterable<WebSocket>) => void,
): void {
  publish({
    sessionId,
    type: 'permission.updated',
    payload: { sessionId, mode, approvalPolicy: mode === 'never' ? 'never' : 'ask' },
  })
}

async function executeCommand(
  ctx: NativeContext,
  sessionId: string,
  line: string,
  attachments: readonly unknown[],
): Promise<unknown> {
  if (ctx.typertGateway !== undefined) {
    return ctx.typertGateway.invoke({
      namespace: 'commands',
      method: 'execute',
      args: { agentId: sessionId, line, submittedAttachments: attachments },
      signal: AbortSignal.timeout(120_000),
    })
  }
  const resolved = await ctx.sessionController.resolveAgent(sessionId)
  if (!('agent' in resolved)) throw new HttpError(409, 'session is not available for commands')
  const agent = resolved.agent as unknown as { ctx?: { remote?: { commands?: { execute?: (...args: unknown[]) => Promise<unknown> } } } }
  const execute = agent.ctx?.remote?.commands?.execute
  if (execute === undefined) throw new HttpError(501, 'Harness command service is unavailable')
  return execute(sessionId, line, attachments, AbortSignal.timeout(120_000))
}

async function uploadAttachment(
  ctx: NativeContext,
  sessionId: string,
  data: string,
  name: string,
): Promise<Record<string, unknown>> {
  if (ctx.typertGateway === undefined) throw new HttpError(501, 'Harness file upload service is unavailable')
  const result = await ctx.typertGateway.invoke({
    namespace: 'fileUploads',
    method: 'upload',
    args: { agentId: sessionId, request: { data, name } },
    signal: AbortSignal.timeout(120_000),
  })
  const value = recordOf(result)
  const nested = recordOf(value.value)
  const receiptId = typeof value.receiptId === 'string' ? value.receiptId : stringOr(nested.receiptId, '')
  if (receiptId.length === 0) throw new HttpError(502, 'Harness file upload returned no receipt')
  const file = recordOf(value.file ?? nested.file)
  return {
    receiptId,
    name,
    ...(typeof file.mediaType === 'string' ? { mediaType: file.mediaType } : {}),
    ...(typeof file.size === 'number' ? { size: file.size } : {}),
  }
}

function objectOf(value: unknown): JsonObject {
  if (typeof value !== 'object' || value === null || Array.isArray(value)) throw new HttpError(400, 'JSON object required')
  return value as JsonObject
}

function stringOf(value: unknown): string {
  if (typeof value !== 'string') throw new HttpError(400, 'string field required')
  return value
}

function optionalStringOf(value: unknown): string | undefined {
  if (value === undefined) return undefined
  return stringOf(value)
}

function modelSelectionOf(value: unknown): { provider: string; model: string; reasoningEffort?: string } {
  const body = objectOf(value)
  const provider = stringOf(body.provider)
  const model = stringOf(body.model)
  const reasoningEffort = optionalStringOf(body.reasoningEffort)
  return { provider, model, ...(reasoningEffort === undefined ? {} : { reasoningEffort }) }
}

function permissionModeOf(value: unknown): PermissionMode {
  if (isPermissionMode(value)) return value
  throw new HttpError(400, 'invalid permission mode')
}

function remoteFailureOf(value: unknown): string | undefined {
  const remote = recordOf(value)
  if (remote.ok !== false) return undefined
  const error = recordOf(remote.error)
  return typeof error.message === 'string' && error.message.length > 0
    ? error.message
    : 'Harness permission command failed'
}

function approvalDecisionOf(value: unknown): ApprovalDecision {
  if (value === 'allowed-once' || value === 'rejected') return value
  throw new HttpError(400, 'decision must be allowed-once or rejected')
}

function header(req: IncomingMessage, name: string): string | undefined {
  const value = req.headers[name]
  return Array.isArray(value) ? value[0] : value
}

function parseAfter(rawUrl: string | undefined): number {
  const value = new URL(rawUrl ?? '/', 'http://localhost').searchParams.get('after')
  if (value === null) return 0
  const parsed = Number(value)
  return Number.isSafeInteger(parsed) && parsed >= 0 ? parsed : 0
}

export function normalizeSessionSummary(
  value: unknown,
  ctx?: NativeContext,
  metadata?: SessionMetadataStore,
): {
  id: string
  title: string
  updatedAt: number
  cwd?: string
  workspaceId?: string
  workspaceName?: string
  archived?: boolean
  running?: boolean
  blank?: boolean
  parentSessionId?: string
  provider?: string
  model?: string
  reasoningEffort?: string
  permissionMode?: PermissionMode
} {
  const item = recordOf(value)
  const id = typeof item.sessionId === 'string'
    ? item.sessionId
    : typeof item.id === 'string' ? item.id : 'unknown'
  const cwd = typeof item.cwd === 'string' ? item.cwd : undefined
  const explicitTitle = sessionTitleOf(item)
  const workspace = workspaceFor(ctx, id, cwd)
  const selection = selectionFor(item)
  const permissionMode = metadata?.permission(id)
  const archived = item.archived === true || metadata?.isArchived(id, workspaceRegistryOf(ctx))
  return {
    id,
    title: explicitTitle ?? (cwd === undefined ? `Session ${id.slice(0, 8)}` : basename(cwd)),
    updatedAt: typeof item.updatedAt === 'number' ? item.updatedAt : Date.now(),
    ...(cwd === undefined ? {} : { cwd }),
    ...(workspace === undefined ? {} : workspace),
    ...(archived ? { archived: true } : {}),
    ...(typeof item.running === 'boolean' ? { running: item.running } : {}),
    ...(typeof item.blank === 'boolean' ? { blank: item.blank } : {}),
    ...(typeof item.parentSessionId === 'string' ? { parentSessionId: item.parentSessionId } : {}),
    ...(selection === undefined ? {} : selection),
    ...(permissionMode === undefined ? {} : { permissionMode }),
  }
}

function normalizeLiveSession(value: unknown, ctx?: NativeContext, metadata?: SessionMetadataStore): ReturnType<typeof normalizeSessionSummary> {
  const session = recordOf(value)
  const header = recordOf(session.header)
  return normalizeSessionSummary({
    sessionId: typeof session.id === 'string' ? session.id : 'unknown',
    cwd: header.cwd,
    updatedAt: Date.now(),
  }, ctx, metadata)
}

/**
 * A session's display title lives in the `title` projection, not on the list
 * entry: `SessionSummary` carries only sessionId/updatedAt/cwd/projections, and
 * the Harness documents that projection as "the shape the client list rows
 * consume". Reading `item.title` yielded undefined for every session, so each
 * row fell back to the folder name and an entire workspace looked like a stack
 * of identically named duplicates.
 */
function sessionTitleOf(item: Record<string, unknown>): string | undefined {
  const values = recordOf(recordOf(item.projections).values)
  const projected = typeof values.title === 'string' ? values.title.trim() : ''
  if (projected.length > 0) return projected
  // Tolerated for older Harness builds that may have exposed a plain field.
  const flat = typeof item.title === 'string' ? item.title.trim() : ''
  return flat.length > 0 ? flat : undefined
}

function selectionFor(item: Record<string, unknown>): { provider?: string; model?: string; reasoningEffort?: string } | undefined {
  const projections = recordOf(item.projections)
  const values = recordOf(projections.values)
  const modelSelection = recordOf(values.modelSelection)
  const selected = recordOf(modelSelection.next ?? modelSelection.lastUsed)
  const provider = typeof selected.provider === 'string' ? selected.provider : undefined
  const model = typeof selected.model === 'string' ? selected.model : undefined
  const reasoningEffort = typeof selected.reasoningEffort === 'string' ? selected.reasoningEffort : undefined
  if (provider === undefined && model === undefined && reasoningEffort === undefined) return undefined
  return { ...(provider === undefined ? {} : { provider }), ...(model === undefined ? {} : { model }), ...(reasoningEffort === undefined ? {} : { reasoningEffort }) }
}

function workspaceFor(ctx: NativeContext | undefined, sessionId: string, cwd: string | undefined): { workspaceId?: string; workspaceName?: string } | undefined {
  const workspace = workspaceRegistryOf(ctx)?.list().find((entry) => entry.sessionIds.includes(sessionId))
  if (workspace !== undefined) return { workspaceId: workspace.id, workspaceName: workspace.title }
  if (cwd === undefined) return undefined
  // Protocol identifiers are capped at 256 chars while a filesystem path is
  // not. Retain the distinctive tail rather than rejecting a full snapshot.
  const workspaceId = `cwd:${cwd}`
  return { workspaceId: workspaceId.length > 256 ? `cwd:${cwd.slice(-252)}` : workspaceId, workspaceName: basename(cwd) }
}

/**
 * Cordis optional injections are exposed as throwing getters. Optional
 * chaining cannot catch that getter failure, so a profile without the
 * workspace service previously turned a valid GET /sessions into HTTP 500.
 */
function workspaceRegistryOf(ctx: NativeContext | undefined): NonNullable<NativeContext['workspaceRegistry']> | undefined {
  if (ctx === undefined) return undefined
  try {
    return ctx.workspaceRegistry
  } catch {
    return undefined
  }
}

export function normalizeSessionEvent(
  sessionId: string,
  value: unknown,
  toolNames: Map<string, string>,
): NativeEventInput | undefined {
  return normalizeSessionEvents(sessionId, value, toolNames)[0]
}

export function normalizeSessionEvents(
  sessionId: string,
  value: unknown,
  toolNames: Map<string, string>,
  usageCounters = new Map<string, { rounds: number; steps: number; contextWindow?: number }>(),
): NativeEventInput[] {
  const event = recordOf(value)
  const type = typeof event.type === 'string' ? event.type : ''
  const data = recordOf(event.data)

  if (type === 'user/message') {
    const source = recordOf(data.source)
    if (source.kind !== 'user') return []
    return [{
      type: 'user.message.accepted',
      sessionId,
      payload: {
        id: stringOr(data.id, randomUUID()),
        role: 'user',
        markdown: contentText(data.content),
      },
    }]
  }
  if (type === 'assistant/message') {
    const message = recordOf(data.message)
    const counters = usageCounters.get(sessionId) ?? { rounds: 0, steps: 0 }
    const usage = normalizeUsage(data.usage, counters.contextWindow)
    const tokensPerSecond = outputRate(data.stream, usage?.outputTokens)
    if (usage !== undefined && tokensPerSecond !== undefined) usage.tokensPerSecond = tokensPerSecond
    const source = recordOf(message.source)
    const messageId = stringOr(message.id, randomUUID())
    const streamedText = streamText(data.stream)
    const normalized: NativeEventInput[] = [{
      type: 'assistant.message.completed',
      sessionId,
      payload: {
        id: messageId,
        role: 'assistant',
        markdown: contentText(message.content),
        ...(usage === undefined ? {} : { usage }),
        ...(typeof source.provider === 'string' ? { provider: source.provider } : {}),
        ...(typeof source.model === 'string' ? { model: source.model } : {}),
      },
    }]
    if (streamedText.length > 0) {
      normalized.unshift({
        type: 'assistant.message.delta',
        sessionId,
        payload: { messageId, text: streamedText },
      })
    }
    const reasoning = reasoningText(message.content)
    if (reasoning.length > 0) {
      // Sent as its own event so the answer stays clean and the phone can fold
      // the reasoning away instead of showing it as part of the reply.
      normalized.unshift({
        type: 'assistant.reasoning',
        sessionId,
        payload: { messageId, text: reasoning },
      })
    }
    if (usage !== undefined) {
      normalized.push({
        type: 'usage.updated',
        sessionId,
        payload: { sessionId, usage: { ...usage, rounds: counters.rounds, steps: counters.steps } },
      })
    }
    return normalized
  }
  if (type === 'tool/call') {
    const callId = stringOr(data.callId, randomUUID())
    const name = stringOr(data.name, 'tool')
    toolNames.set(callId, name)
    return [{
      type: 'tool.started',
      sessionId,
      payload: { id: callId, name, status: 'running', detail: stringOr(data.arguments, '') },
    }]
  }
  if (type === 'tool/result') {
    const message = recordOf(data.message)
    const blocks = Array.isArray(message.content) ? message.content : []
    const first = recordOf(blocks[0])
    const callId = stringOr(first.toolCallId, stringOr(first.id, randomUUID()))
    const failed = first.isError === true || data.error !== undefined
    const name = toolNames.get(callId) ?? 'tool'
    toolNames.delete(callId)
    return [{
      type: 'tool.completed',
      sessionId,
      payload: {
        id: callId,
        name,
        status: failed ? 'failed' : 'succeeded',
        detail: contentText(first.content),
      },
    }]
  }
  if (type === 'command/run') {
    const commandId = stringOr(data.commandId, randomUUID())
    const name = stringOr(data.name, 'command')
    toolNames.set(commandId, name)
    return [{
      type: 'tool.started',
      sessionId,
      payload: { id: commandId, name, status: 'running', detail: stringOr(data.args, '') },
    }]
  }
  if (type === 'command/done') {
    const commandId = stringOr(data.commandId, randomUUID())
    const kind = data.kind === 'error' ? 'error' : 'success'
    const name = toolNames.get(commandId) ?? 'command'
    toolNames.delete(commandId)
    return [
      {
        type: 'tool.completed',
        sessionId,
        payload: { id: commandId, name, status: kind === 'success' ? 'succeeded' : 'failed', detail: stringOr(data.text, '') },
      },
      {
        type: 'command.result',
        sessionId,
        payload: {
          sessionId,
          requestId: commandId,
          matched: true,
          commandId,
          kind,
          ...(typeof data.text === 'string' ? { text: data.text } : {}),
        },
      },
    ]
  }
  if (type === 'turn/start') {
    const counters = usageCounters.get(sessionId) ?? { rounds: 0, steps: 0 }
    usageCounters.set(sessionId, { ...counters, rounds: counters.rounds + 1 })
    return [{ type: 'turn.state.changed', sessionId, payload: { sessionId, state: 'running' } }]
  }
  if (type === 'turn/end') {
    const reason = stringOr(data.reason, 'completed')
    return [{ type: 'turn.state.changed', sessionId, payload: { sessionId, state: reason } }]
  }
  if (type === 'step/start') {
    const counters = usageCounters.get(sessionId) ?? { rounds: 0, steps: 0 }
    usageCounters.set(sessionId, { ...counters, steps: counters.steps + 1 })
    return []
  }
  if (type === 'request/context') {
    const contextWindow = typeof data.contextWindow === 'number' ? data.contextWindow : undefined
    if (contextWindow !== undefined) {
      const counters = usageCounters.get(sessionId) ?? { rounds: 0, steps: 0 }
      usageCounters.set(sessionId, { ...counters, contextWindow })
    }
    return [{
      type: 'session.metadata.updated',
      sessionId,
      payload: {
        sessionId,
        ...(typeof data.provider === 'string' ? { provider: data.provider } : {}),
        ...(typeof data.model === 'string' ? { model: data.model } : {}),
        ...(typeof data.contextWindow === 'number' ? { contextWindow: data.contextWindow } : {}),
      },
    }]
  }
  if (type === 'request/header') {
    const header = recordOf(data.header)
    const config = recordOf(header.config)
    return [{
      type: 'session.metadata.updated',
      sessionId,
      payload: {
        sessionId,
        ...(typeof config.provider === 'string' ? { provider: config.provider } : {}),
        ...(typeof config.model === 'string' ? { model: config.model } : {}),
        ...(typeof config.reasoningEffort === 'string' ? { reasoningEffort: config.reasoningEffort } : {}),
      },
    }]
  }
  if (type === 'model/selection') {
    return [{
      type: 'session.metadata.updated',
      sessionId,
      payload: {
        sessionId,
        ...(typeof data.provider === 'string' ? { provider: data.provider } : {}),
        ...(typeof data.model === 'string' ? { model: data.model } : {}),
        ...(typeof data.reasoningEffort === 'string' ? { reasoningEffort: data.reasoningEffort } : {}),
      },
    }]
  }
  if (type === 'approval/asked') {
    return [{
      type: 'approval.requested',
      sessionId,
      payload: {
        id: stringOr(data.id, randomUUID()),
        sessionId,
        toolName: stringOr(data.toolName, 'tool'),
        reason: stringOr(data.reason, 'Approval required'),
      },
    }]
  }
  if (type === 'approval/decided') {
    const outcome = stringOr(data.outcome, 'rejected')
    return [{
      type: 'approval.resolved',
      sessionId,
      payload: { id: stringOr(data.id, randomUUID()), allowed: outcome === 'allowed-once' },
    }]
  }
  const preset = data.preset
  if (type === 'permission/preset' && (preset === 'workspace-write' || preset === 'danger-full-access')) {
    return [{
      type: 'permission.updated',
      sessionId,
      payload: {
        sessionId,
        mode: preset,
        approvalPolicy: preset === 'danger-full-access' ? 'never' : 'ask',
      },
    }]
  }
  if (type === 'approval/policy') {
    // sandbox/mode is the canonical setting rendered by the client. The
    // companion policy event only says ask/never, so it must not overwrite
    // workspace-write or danger-full-access in the UI state.
    return []
  }
  if (type === 'sandbox/mode' && isPermissionMode(data.mode)) {
    return [{ type: 'permission.updated', sessionId, payload: { sessionId, mode: data.mode } }]
  }
  return []
}

function normalizeUsage(value: unknown, contextWindow?: number): Record<string, number> | undefined {
  const usage = recordOf(value)
  const fields = ['inputTokens', 'outputTokens', 'totalTokens', 'cacheReadTokens', 'cacheWriteTokens']
  const normalized: Record<string, number> = {}
  for (const field of fields) if (typeof usage[field] === 'number' && usage[field] >= 0) normalized[field] = usage[field] as number
  if (Object.keys(normalized).length === 0) return undefined
  const input = normalized.inputTokens ?? 0
  const cached = normalized.cacheReadTokens ?? 0
  if (input + cached > 0) normalized.cacheHitPercent = cached / (input + cached) * 100
  if (contextWindow !== undefined && contextWindow > 0) {
    normalized.contextWindow = contextWindow
    normalized.contextUsed = input
  }
  return normalized
}

/** Estimate generation throughput from Harness's durable timed stream records. */
function outputRate(streamValue: unknown, outputTokens: number | undefined): number | undefined {
  if (typeof outputTokens !== 'number' || outputTokens <= 0 || !Array.isArray(streamValue)) return undefined
  let first: number | undefined
  let last: number | undefined
  for (const value of streamValue) {
    const record = recordOf(value)
    let start: number | undefined
    let end: number | undefined
    if (record.type === 'chunk' && typeof record.time === 'number') {
      start = record.time
      end = record.time
    } else if (typeof record.time0 === 'number') {
      start = record.time0
      const fragments = Array.isArray(record.args) ? record.args : Array.isArray(record.texts) ? record.texts : []
      const intervals = Array.isArray(record.dt) ? record.dt : []
      let elapsed = 0
      for (let index = 0; index < Math.max(0, fragments.length - 1); index += 1) {
        const delta = intervals[index]
        if (typeof delta === 'number' && delta >= 0) elapsed += delta
      }
      end = start + elapsed
    }
    if (start !== undefined) first = first === undefined ? start : Math.min(first, start)
    if (end !== undefined) last = last === undefined ? end : Math.max(last, end)
  }
  if (first === undefined || last === undefined || last <= first) return undefined
  return outputTokens / ((last - first) / 1_000)
}

/**
 * Only `text` blocks become the answer. Reasoning is pulled out separately by
 * reasoningText so chain-of-thought never lands in the reply the phone renders
 * as the assistant's message.
 */
function contentText(value: unknown): string {
  return blockText(value, 'text')
}

function reasoningText(value: unknown): string {
  return blockText(value, 'reasoning')
}

function blockText(value: unknown, kind: 'text' | 'reasoning'): string {
  if (!Array.isArray(value)) return ''
  return value.flatMap((entry) => {
    const block = recordOf(entry)
    if (block.type === kind && typeof block.text === 'string') return [block.text]
    return []
  }).join('')
}

function streamText(value: unknown): string {
  if (!Array.isArray(value)) return ''
  return value.flatMap((entry) => {
    const record = recordOf(entry)
    if (record.type === 'text-chunks' && Array.isArray(record.texts)) {
      return record.texts.filter((text): text is string => typeof text === 'string')
    }
    if (record.type === 'chunk') {
      const chunk = recordOf(record.chunk)
      return chunk.type === 'text-delta' && typeof chunk.text === 'string' ? [chunk.text] : []
    }
    return []
  }).join('')
}

function recordOf(value: unknown): Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
    ? value as Record<string, unknown>
    : {}
}

function stringOr(value: unknown, fallback: string): string {
  return typeof value === 'string' ? value : fallback
}

export default { name, inject, apply }
