import { hostname } from 'node:os'
import { createHash, randomUUID } from 'node:crypto'
import { createRequire } from 'node:module'
import { basename, dirname, isAbsolute, join, resolve } from 'node:path'
import { homedir } from 'node:os'
import { chmod, mkdir, opendir, readFile, rename, stat, writeFile } from 'node:fs/promises'
import { readFileSync, statSync } from 'node:fs'
import type { IncomingMessage, OutgoingHttpHeaders, ServerResponse } from 'node:http'
import type { Duplex } from 'node:stream'
import type { Context } from '@deepseek-ai/cordis'
import type { ApprovalOutcome, ApprovalRequestEvent } from '@deepseek-ai/dsh-user-approval/types'
import { WebSocket, WebSocketServer } from 'ws'
import {
  AttachmentUploadPayloadSchema,
  ChatAttachmentSchema,
  MAX_PROMPT_BODY_BYTES,
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
import { HttpError, json, readJson, RetryableHttpError } from './http.js'
import { PendingApprovals, type ApprovalDecision } from './pending-approvals.js'
import { PendingQuestions, firstAnswered } from './pending-questions.js'
import { ReplayBuffer } from './replay.js'

const MAX_ATTACHMENT_BYTES = 10 * 1024 * 1024
const MAX_ATTACHMENT_BASE64_CHARS = Math.ceil(MAX_ATTACHMENT_BYTES / 3) * 4
const IDEMPOTENCY_TTL_MS = 10 * 60_000
const MAX_IDEMPOTENCY_ENTRIES = 2_000
const ATTACHMENT_UPLOAD_RETENTION_MS = 30 * 24 * 60 * 60_000
/**
 * Expired attachment records are safety tombstones, not ordinary cache
 * entries: deleting one without an authoritative native reconciliation could
 * make a late retry upload the same file twice. Bound their total count and
 * the enclosing metadata file instead of using an unsafe TTL.
 */
const MAX_ATTACHMENT_UPLOAD_TOMBSTONES = 8_192
const MAX_SESSION_METADATA_BYTES = 32 * 1024 * 1024
// A file larger than the normal write budget can still be repaired by
// deleting records, but an unbounded read would turn a corrupt path into a
// memory-exhaustion vector.
const MAX_SESSION_METADATA_LOAD_BYTES = 64 * 1024 * 1024
const MAX_ATTACHMENT_RECONCILIATION_BATCH = 128
const MAX_REMOTE_MUTATION_RECORDS = 4_096

interface CapturedHttpResponse {
  readonly status: number
  readonly headers: OutgoingHttpHeaders
  readonly body: string | Buffer
}

interface IdempotencyEntry {
  expiresAt: number
  completed: boolean
  fingerprint: string | undefined
  result: Promise<CapturedHttpResponse>
}

/** Shared by every Connector socket attached to this Bridge process. */
export class IdempotentHttpResponses {
  private readonly entries = new Map<string, IdempotencyEntry>()

  async respond(
    key: string,
    fingerprint: string | undefined,
    req: IncomingMessage,
    res: ServerResponse,
    handler: (capture: ServerResponse) => Promise<void>,
  ): Promise<void> {
    const now = Date.now()
    for (const [entryKey, entry] of this.entries) {
      if (entry.completed && entry.expiresAt <= now) this.entries.delete(entryKey)
    }
    let entry = this.entries.get(key)
    if (entry === undefined) {
      if (this.entries.size >= MAX_IDEMPOTENCY_ENTRIES) {
        // Never evict an in-flight request, and never evict an unexpired
        // terminal record: the latter is the request-id tombstone that keeps
        // a lost response from executing the side effect a second time. If
        // all slots are inside their promised window, reject new mutations
        // until capacity is available rather than silently weakening
        // idempotency.
        throw new HttpError(503, 'idempotency capacity is busy')
      }
      const pending: IdempotencyEntry = {
        expiresAt: Number.POSITIVE_INFINITY,
        completed: false,
        fingerprint,
        result: Promise.resolve({ status: 500, headers: {}, body: '' }),
      }
      pending.result = captureHttpResponse(handler)
      entry = pending
      this.entries.set(key, entry)
      void entry.result.then(
        (captured) => {
          if (this.entries.get(key) === entry) {
            const outcome = idempotencyOutcomeOf(captured)
            if (outcome === 'retryable' || outcome === 'retryable-committed' || outcome === 'retryable-durable') {
              // The handler explicitly established that no side effect was
              // accepted. Let a same-id retry invoke it again after recovery.
              this.entries.delete(key)
            } else {
              // `unknown` is deliberately retained: a timeout or late native
              // failure may have happened after the side effect was accepted,
              // so replaying it is safer than executing twice.
              entry!.completed = true
              entry!.expiresAt = Date.now() + IDEMPOTENCY_TTL_MS
            }
          }
        },
        () => {
          // A handler that truly rejects did not produce a replayable result.
          if (this.entries.get(key) === entry) this.entries.delete(key)
        },
      )
    } else {
      // The winning handler consumes its own request body. Drain duplicate
      // bodies as well so their keep-alive connections remain reusable.
      req.resume()
      if (entry.fingerprint !== fingerprint) {
        throw new HttpError(409, 'idempotency key was reused with different request data')
      }
    }
    const captured = await entry.result
    res.writeHead(captured.status, captured.headers)
    res.end(captured.body)
  }
}

async function captureHttpResponse(handler: (capture: ServerResponse) => Promise<void>): Promise<CapturedHttpResponse> {
  let status = 200
  let headers: OutgoingHttpHeaders = {}
  let body: string | Buffer = ''
  const capture = {
    writeHead: (nextStatus: number, nextHeaders?: OutgoingHttpHeaders) => {
      status = nextStatus
      headers = nextHeaders ?? {}
      return capture
    },
    end: (chunk?: string | Buffer) => {
      body = chunk ?? ''
      return capture
    },
  } as unknown as ServerResponse
  await handler(capture)
  return { status, headers, body }
}

function idempotencyOutcomeOf(captured: CapturedHttpResponse): 'final' | 'retryable' | 'retryable-committed' | 'retryable-durable' | 'unknown' {
  const header = captured.headers['x-dsh-idempotency-outcome']
  const value = Array.isArray(header) ? header[0] : header
  return value === 'retryable' || value === 'retryable-committed' || value === 'retryable-durable'
    ? value : value === 'final' ? 'final' : 'unknown'
}

export const name = 'dsh-anywhere-native-bridge'
// workspaceRegistry is the source of truth for sessions archived from the
// Harness web UI. It must be injected explicitly or Cordis exposes it as a
// throwing optional getter and the mobile list cannot distinguish archived
// sessions from active ones.
// typertGateway is what actually stores an uploaded file. Accessing it
// without declaring it here throws before any of our own checks run, which is
// why uploads failed with "cannot get property \"typertGateway\" without
// inject" rather than our 501 message.
/**
 * Commands whose completion is a state change rather than conversation output.
 * They are issued by the app itself, and their effect reaches the phone as its
 * own event, so a transcript row for them is noise that never clears.
 */
const COMMAND_RESULT_SUPPRESSED = new Set(['permission', 'permissions', 'model'])

/**
 * Setup executions the bridge runs itself (`/permission` during permission
 * changes and session creation) surface as ordinary native `command/done`
 * events, which would render as tool/result cards the user never asked for.
 * The phone already learns the outcome from `permission.updated` (and from
 * `protocol.error` on failure). Each setup call arms a short per-session
 * window; native echoes whose text is the preset acknowledgement are
 * dropped inside it. User-typed commands never match both conditions.
 */
const silentSetupUntil = new Map<string, number>()
const SILENT_SETUP_WINDOW_MS = 10_000
const SILENT_SETUP_TEXT = /^preset (read-only|workspace-write|danger-full-access)$/

export function armSilentSetupWindow(sessionId: string): void {
  silentSetupUntil.set(sessionId, Date.now() + SILENT_SETUP_WINDOW_MS)
}

export function isSilentSetupEcho(sessionId: string, rawEvent: unknown): boolean {
  const expiry = silentSetupUntil.get(sessionId)
  if (expiry === undefined) return false
  if (expiry <= Date.now()) {
    silentSetupUntil.delete(sessionId)
    return false
  }
  if (typeof rawEvent !== 'object' || rawEvent === null) return false
  const record = rawEvent as Record<string, unknown>
  if (record['type'] !== 'command/done') return false
  const data = record['data']
  if (typeof data !== 'object' || data === null || Array.isArray(data)) return false
  const text = (data as Record<string, unknown>)['text']
  return typeof text === 'string' && SILENT_SETUP_TEXT.test(text)
}
// A targeted open should make an existing conversation useful immediately,
// without turning a tap into an unbounded replay on the phone. We still walk
// the complete durable log to build session-wide usage; only the newest rows
// are sent over the wire. The cap is deliberately generous (10k events):
// normal sessions are far smaller so they replay in full for free, and only
// giant sessions pay a heavy one-time replay on open. Past this, sessions
// stay windowed — true remote paging (fetch older on scroll) is the
// follow-up, not a bigger cap.
const HISTORY_EVENT_LIMIT = 10_000

export const inject = ['webServer', 'sessionController', 'workspaceRegistry', 'typertGateway', 'directoryPicker']

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

interface ConnectorLease {
  readonly connectorId: string
  readonly generation: number
  readonly relayGeneration: number
  readonly relayEpoch: string
}

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

export type NativeEventInput = Pick<EventEnvelope, 'type' | 'payload'> & {
  /** Optional correlation id for events that acknowledge a phone request.
   * This stays internal to the Bridge; the public event schema already has a
   * messageId field, so publish can carry it without changing payloads. */
  readonly messageId?: string
  readonly sessionId?: string
  /** History transcript events carry their replay batch through the Bridge
   * and Relay so clients can keep late rows from driving live side effects. */
  readonly historyBatchId?: string
  readonly deviceId?: string
  /** Control handshakes are sent to the current socket only and are not
   * business history that a later socket should replay. */
  readonly replay?: boolean
}

/** Mutable state belonging to one active Harness assistant-stream attempt. */
export interface LiveStreamAttempt {
  readonly key: string
  readonly messageId: string
  readonly sessionId: string
  reasoningTrail: string
}

/**
 * Result of reconciling a durable attachment operation after a Bridge
 * restart. `unknown` is deliberately distinct from `not-committed`: only
 * the latter permits the same request id to invoke the native uploader again.
 */
export type AttachmentUploadRecoveryResult =
  | { readonly state: 'found'; readonly response: unknown }
  | { readonly state: 'not-committed' }
  | { readonly state: 'unknown' }

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
    create(request: { requestId?: string; createRequestId?: string; cwd?: string; workspaceId?: string; agentPreset?: string; model?: { provider: string; model: string; reasoningEffort?: string }}): Promise<{ sessionId: string; agentPreset?: string }>
    /** Optional recovery hook for adapters that persist the create operation id. */
    findByRequestId?(requestId: string, signal: AbortSignal): Promise<{ sessionId: string } | undefined>
    /** Optional recovery hook for file-upload adapters that persist the
     * stable upload operation id alongside the staged receipt. Older Harness
     * builds do not expose this lookup; those builds fail closed on an
     * uncertain upload instead of issuing a duplicate native upload. */
    findAttachmentByRequestId?(requestId: string, signal: AbortSignal): Promise<unknown | undefined | AttachmentUploadRecoveryResult>
    /** Available in current Harness builds; optional for older connectors. */
    rename?(request: { sessionId: string; title: string }): Promise<unknown>
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
    create?(path: string, title?: string): Promise<{ id: string; path: string; title: string; sessionIds: readonly string[] }>
    get?(id: string): { id: string; path: string; title: string; sessionIds: readonly string[]; setTitle?(title: string): Promise<void> } | undefined
    delete?(id: string): Promise<boolean>
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
  readonly directoryPicker?: {
    capability(): {
      kind: string
      list?(path?: string, signal?: AbortSignal): Promise<{
        path: string
        entries: readonly { name: string; path: string }[]
      }>
    }
  }
}

interface JsonObject {
  readonly [key: string]: unknown
}

type SessionCreationSetup = {
  readonly branch?: string
  readonly title?: string
  readonly model?: { readonly provider: string; readonly model: string; readonly reasoningEffort?: string }
  readonly permissionMode?: 'read-only' | 'workspace-write' | 'danger-full-access'
}

interface SessionCreationRecord {
  readonly schemaVersion?: 1
  readonly fingerprint: string | undefined
  readonly response?: JsonObject
  readonly pending?: boolean
  /** Native create committed, but optional setup has not completed yet. */
  sessionId?: string
  /** Stable operation identity passed into the native create boundary. */
  readonly nativeOperationId?: string
  readonly setup?: SessionCreationSetup | undefined
  readonly setupComplete?: boolean
  /** A pre-stage-machine response may have been captured before setup finished. */
  readonly legacySetupUnknown?: boolean
  /** Observability metadata; completed records are retained as tombstones. */
  readonly completedAt?: number
}

/** Durable at-most-once records for native mutations whose Harness APIs do
 * not expose a lookup operation. A pending record is deliberately fail-closed
 * after a Bridge restart: replaying it would be less safe than asking an
 * operator to reconcile the unknown native result. */
interface RemoteMutationRecord {
  readonly fingerprint: string | undefined
  readonly pending?: boolean
  readonly createdAt?: number
  readonly status?: number
  readonly response?: unknown
  readonly completedAt?: number
}

interface AttachmentUploadRecord {
  readonly fingerprint: string | undefined
  /** Original filename used when an operator reconstructs a receipt. */
  readonly name?: string
  /** Stable operation identity understood by adapters that can reconcile a
   * staged receipt after the Bridge died before persisting the response. */
  readonly nativeOperationId?: string
  readonly pending?: boolean
  /** A pending record that outlived the client recovery contract.  It stays
   * as a permanent tombstone until an adapter/operator reconciles it. */
  readonly expired?: boolean
  /** A reconciled receipt remains tied to its expired tombstone.  Keeping the
   * record in this state prevents it from becoming an active record and
   * exceeding the bounded active-idempotency capacity during reconciliation. */
  readonly reconciled?: boolean
  readonly response?: JsonObject
  readonly createdAt?: number
  readonly completedAt?: number
  readonly expiredAt?: number
}

const MAX_SESSION_CREATION_RECORDS = 4096
const MAX_ATTACHMENT_UPLOAD_RECORDS = 8192
const SESSION_CREATION_RECORD_SCHEMA_VERSION = 1 as const

type PermissionMode = 'ask' | 'never' | 'read-only' | 'workspace-write' | 'danger-full-access'

/**
 * Small presentation metadata that is intentionally kept outside the Harness
 * session log. The workspace package owns the canonical archive set; this
 * store keeps per-session fallbacks for older Harness builds and mobile-only
 * title/branch choices.
 */
class SessionMetadataStore {
  private archived = new Set<string>()
  private unarchived = new Set<string>()
  private permissions = new Map<string, PermissionMode>()
  private titles = new Map<string, string>()
  private branches = new Map<string, string>()
  /** Durable request -> result records for session creation.  The HTTP
   * idempotency cache is intentionally short-lived, but a lost response must
   * remain queryable after that cache expires or the Bridge restarts. */
  private sessionCreationResults = new Map<string, SessionCreationRecord>()
  /** Durable command/workspace mutation results. */
  private remoteMutationResults = new Map<string, RemoteMutationRecord>()
  /** Attachment receipts need the same crash/retry protection as session
   * creation. A pending record fails closed after a native upload response is
   * lost; replaying the upload could otherwise create an orphaned file. */
  private attachmentUploadResults = new Map<string, AttachmentUploadRecord>()
  /** Round-robin cursor for bounded operator reconciliation.  Unknown early
   * tombstones must not starve later records that can be recovered. */
  private attachmentReconciliationCursor: string | undefined
  /** A corrupt metadata file must never make the create dedupe layer forget
   * an already committed session and execute the same request again. */
  private persistenceUnavailable = false
  /** The metadata file was valid but exceeded the normal write budget.  This
   * is recoverable: allow only shrink/reconciliation writes until it fits. */
  private persistenceCapacityExceeded = false
  private metadataByteLength = 0
  private persistQueue: Promise<void> = Promise.resolve()
  readonly ready: Promise<void>

  constructor(
    private readonly path: string,
    private readonly warn: (message: string) => void = () => undefined,
  ) {
    this.ready = this.load()
  }

  private rejectGrowthWhileOverCapacity(message: string): void {
    if (this.persistenceCapacityExceeded) {
      throw new HttpError(503, `${message}; reconcile or compact session-metadata.json first`, 'unknown')
    }
  }

  isArchived(sessionId: string, registry?: NativeContext['workspaceRegistry']): boolean {
    if (this.unarchived.has(sessionId)) return false
    return this.archived.has(sessionId) || registry?.archivedSessionIds.includes(sessionId) === true
  }

  permission(sessionId: string): PermissionMode | undefined {
    return this.permissions.get(sessionId)
  }

  title(sessionId: string): string | undefined {
    return this.titles.get(sessionId)
  }

  branch(sessionId: string): string | undefined {
    return this.branches.get(sessionId)
  }

  sessionCreationEntry(key: string, fingerprint: string | undefined): SessionCreationRecord | undefined {
    if (this.persistenceUnavailable) {
      throw new HttpError(503, 'session creation metadata is unavailable; repair session-metadata.json', 'unknown')
    }
    const entry = this.sessionCreationResults.get(key)
    if (entry === undefined) return undefined
    if (entry.fingerprint !== undefined && fingerprint !== undefined && entry.fingerprint !== fingerprint) {
      throw new HttpError(409, 'idempotency key was reused with different request data')
    }
    if (entry.response === undefined) {
      // A previous Bridge process recorded the operation before invoking the
      // native create but died before it could learn the session id. Never
      // execute that request a second time. The HTTP layer gets one chance to
      // reconcile the operation id with an adapter-provided authoritative list;
      // if that is unavailable it still fails closed.
      if (entry.sessionId === undefined && entry.pending !== true) {
        throw new HttpError(503, 'session creation result is still unknown', 'unknown')
      }
    }
    return entry
  }

  attachmentUploadEntry(key: string, fingerprint: string | undefined): JsonObject | undefined {
    if (this.persistenceUnavailable) {
      throw new HttpError(503, 'attachment upload metadata is unavailable; repair session-metadata.json', 'unknown')
    }
    const entry = this.attachmentUploadResults.get(key)
    if (entry === undefined) return undefined
    if (entry.fingerprint !== undefined && fingerprint !== undefined && entry.fingerprint !== fingerprint) {
      throw new HttpError(409, 'idempotency key was reused with different request data')
    }
    if (entry.expired === true && entry.reconciled !== true) {
      throw new HttpError(409, 'attachment upload recovery expired; reconcile the native operation before retrying')
    }
    if (entry.response === undefined) {
      throw new HttpError(503, 'attachment upload result is still unknown', 'unknown')
    }
    return entry.response
  }

  attachmentUploadPendingEntry(key: string, fingerprint: string | undefined): AttachmentUploadRecord | undefined {
    if (this.persistenceUnavailable) {
      throw new HttpError(503, 'attachment upload metadata is unavailable; repair session-metadata.json', 'unknown')
    }
    const entry = this.attachmentUploadResults.get(key)
    if (entry === undefined) return undefined
    if (entry.fingerprint !== undefined && fingerprint !== undefined && entry.fingerprint !== fingerprint) {
      throw new HttpError(409, 'idempotency key was reused with different request data')
    }
    const stale = entry.pending === true && entry.createdAt !== undefined &&
      entry.createdAt < Date.now() - ATTACHMENT_UPLOAD_RETENTION_MS
    return entry.response === undefined && entry.pending === true &&
      entry.expired !== true && !stale ? entry : undefined
  }

  attachmentUploadExpiredEntry(key: string, fingerprint: string | undefined): AttachmentUploadRecord | undefined {
    if (this.persistenceUnavailable) {
      throw new HttpError(503, 'attachment upload metadata is unavailable; repair session-metadata.json', 'unknown')
    }
    const entry = this.attachmentUploadResults.get(key)
    if (entry === undefined) return undefined
    if (entry.fingerprint !== undefined && fingerprint !== undefined && entry.fingerprint !== fingerprint) {
      throw new HttpError(409, 'idempotency key was reused with different request data')
    }
    const stale = entry.pending === true && entry.createdAt !== undefined &&
      entry.createdAt < Date.now() - ATTACHMENT_UPLOAD_RETENTION_MS
    return (entry.expired === true && entry.reconciled !== true) || stale ? entry : undefined
  }

  async setAttachmentUploadPending(key: string, fingerprint: string | undefined,
                                   nativeOperationId?: string, name?: string): Promise<void> {
    if (this.persistenceUnavailable) {
      throw new HttpError(503, 'attachment upload metadata is unavailable; repair session-metadata.json', 'unknown')
    }
    const now = Date.now()
    const cutoff = now - ATTACHMENT_UPLOAD_RETENTION_MS
    const previousResults = new Map(this.attachmentUploadResults)
    const previousCapacityExceeded = this.persistenceCapacityExceeded
    const previousMetadataByteLength = this.metadataByteLength
    let expiredCount = [...this.attachmentUploadResults.values()]
      .filter((entry) => entry.expired === true && entry.reconciled !== true).length
    let pruned = false
    for (const [entryKey, entry] of this.attachmentUploadResults) {
      if (entry.response !== undefined && entry.completedAt !== undefined && entry.completedAt < cutoff) {
        this.attachmentUploadResults.delete(entryKey)
        pruned = true
      } else if (entry.pending === true && entry.createdAt !== undefined && entry.createdAt < cutoff) {
        // The phone refuses to resume an attachment after the same 30-day
        // window, so an unknown pending marker must become an explicit,
        // fail-closed reconciliation tombstone instead of occupying an active
        // idempotency slot forever.  Keep the operation identity so a later
        // adapter lookup can recover the receipt or prove non-commitment.
        if (expiredCount >= MAX_ATTACHMENT_UPLOAD_TOMBSTONES) {
          this.attachmentUploadResults = previousResults
          throw new HttpError(
            503,
            'attachment upload tombstone capacity is full; reconcile expired uploads before retrying',
            'unknown',
          )
        }
        this.attachmentUploadResults.set(entryKey, {
          fingerprint: entry.fingerprint,
          ...(entry.name === undefined ? {} : { name: entry.name }),
          ...(entry.nativeOperationId === undefined ? {} : { nativeOperationId: entry.nativeOperationId }),
          expired: true,
          expiredAt: now,
        })
        expiredCount += 1
        pruned = true
      }
    }
    let durableResults = previousResults
    let durableCapacityExceeded = previousCapacityExceeded
    let durableMetadataByteLength = previousMetadataByteLength
    if (pruned) {
      try {
        await this.persist()
        durableResults = new Map(this.attachmentUploadResults)
        durableCapacityExceeded = this.persistenceCapacityExceeded
        durableMetadataByteLength = this.metadataByteLength
      } catch (error) {
        this.attachmentUploadResults = previousResults
        this.persistenceCapacityExceeded = previousCapacityExceeded
        this.metadataByteLength = previousMetadataByteLength
        throw error
      }
    }
    if (!this.attachmentUploadResults.has(key) && expiredCount >= MAX_ATTACHMENT_UPLOAD_TOMBSTONES) {
      // Reconciliation is intentionally required before accepting more
      // unknown operations. Keeping the existing tombstones is safer than
      // evicting one and allowing a duplicate native upload.
      throw new HttpError(
        503,
        'attachment upload tombstone capacity is full; reconcile expired uploads before retrying',
        'unknown',
      )
    }
    const activeCount = [...this.attachmentUploadResults.values()]
      .filter((entry) => entry.expired !== true).length
    if (!this.attachmentUploadResults.has(key) && activeCount >= MAX_ATTACHMENT_UPLOAD_RECORDS) {
      throw new HttpError(503, 'attachment upload idempotency capacity is full', 'unknown')
    }
    // Let the pruning pass above compact completed records even while the
    // file is over the normal byte budget. Only the new pending record is a
    // growth operation and must wait for reconciliation/compaction.
    this.rejectGrowthWhileOverCapacity('attachment upload metadata capacity is full')
    this.attachmentUploadResults.set(key, {
      fingerprint,
      ...(name === undefined ? {} : { name }),
      pending: true,
      createdAt: now,
      ...(nativeOperationId === undefined ? {} : { nativeOperationId }),
    })
    try {
      await this.persist()
    } catch (error) {
      this.attachmentUploadResults = durableResults
      this.persistenceCapacityExceeded = durableCapacityExceeded
      this.metadataByteLength = durableMetadataByteLength
      throw error
    }
  }

  async setAttachmentUploadResult(key: string, fingerprint: string | undefined,
                                  response: JsonObject, nativeOperationId?: string): Promise<void> {
    if (this.persistenceUnavailable) {
      throw new HttpError(503, 'attachment upload metadata is unavailable; repair session-metadata.json', 'unknown')
    }
    const previous = this.attachmentUploadResults.get(key)
    if (this.persistenceCapacityExceeded && previous?.expired !== true) {
      throw new HttpError(503, 'attachment upload metadata capacity is full; reconcile or compact session-metadata.json first', 'unknown')
    }
    const operationId = nativeOperationId ?? previous?.nativeOperationId
    const previousCapacityExceeded = this.persistenceCapacityExceeded
    const previousMetadataByteLength = this.metadataByteLength
    this.attachmentUploadResults.set(key, {
      fingerprint,
      ...(previous?.name === undefined ? {} : { name: previous.name }),
      ...(previous?.expired === true ? { expired: true, reconciled: true } : {}),
      response,
      completedAt: Date.now(),
      ...(operationId === undefined ? {} : { nativeOperationId: operationId }),
    })
    try {
      await this.persist(previous?.expired === true)
    } catch (error) {
      if (previous === undefined) this.attachmentUploadResults.delete(key)
      else this.attachmentUploadResults.set(key, previous)
      this.persistenceCapacityExceeded = previousCapacityExceeded
      this.metadataByteLength = previousMetadataByteLength
      throw error
    }
  }

  async markAttachmentUploadNotCommitted(key: string, fingerprint: string | undefined): Promise<void> {
    if (this.persistenceUnavailable) {
      throw new HttpError(503, 'attachment upload metadata is unavailable; repair session-metadata.json', 'unknown')
    }
    const entry = this.attachmentUploadResults.get(key)
    if (entry === undefined) return
    if (entry.fingerprint !== undefined && fingerprint !== undefined && entry.fingerprint !== fingerprint) {
      throw new HttpError(409, 'idempotency key was reused with different request data')
    }
    // A native 4xx/501 response proves the upload did not reach the file
    // service. Remove the marker so the same stable request id can retry after
    // the local capability is restored instead of remaining permanently
    // stuck in the fail-closed pending state.
    const previousCapacityExceeded = this.persistenceCapacityExceeded
    const previousMetadataByteLength = this.metadataByteLength
    this.attachmentUploadResults.delete(key)
    try {
      await this.persist()
    } catch (error) {
      this.attachmentUploadResults.set(key, entry)
      this.persistenceCapacityExceeded = previousCapacityExceeded
      this.metadataByteLength = previousMetadataByteLength
      throw error
    }
  }

  /**
   * Reconcile expired upload tombstones without requiring the original phone
   * request body. This is intentionally an operator/Connector operation: an
   * authoritative native lookup may either return the original receipt or
   * prove that no upload was committed.
   */
  async reconcileExpiredAttachmentUploads(
    findAttachmentByRequestId: ((operationId: string, signal: AbortSignal) =>
      Promise<unknown | undefined | AttachmentUploadRecoveryResult>) | undefined,
    limit = MAX_ATTACHMENT_RECONCILIATION_BATCH,
    afterKey?: string,
  ): Promise<{ scanned: number; found: number; notCommitted: number; unknown: number; nextCursor?: string }> {
    if (this.persistenceUnavailable) {
      throw new HttpError(503, 'attachment upload metadata is unavailable; repair session-metadata.json', 'unknown')
    }
    const boundedLimit = Number.isSafeInteger(limit)
      ? Math.min(Math.max(limit, 1), MAX_ATTACHMENT_RECONCILIATION_BATCH)
      : MAX_ATTACHMENT_RECONCILIATION_BATCH
    const candidates = [...this.attachmentUploadResults.entries()]
      .filter(([, entry]) => entry.expired === true && entry.reconciled !== true)
    if (candidates.length === 0) {
      this.attachmentReconciliationCursor = undefined
      return { scanned: 0, found: 0, notCommitted: 0, unknown: 0 }
    }
    const cursor = afterKey ?? this.attachmentReconciliationCursor
    let start = 0
    if (cursor !== undefined) {
      const cursorIndex = candidates.findIndex(([key]) => key === cursor)
      if (cursorIndex >= 0) start = (cursorIndex + 1) % candidates.length
    }
    let scanned = 0
    let found = 0
    let notCommitted = 0
    let unknown = 0
    let lastKey: string | undefined
    let index = start
    while (scanned < boundedLimit && scanned < candidates.length) {
      const [key, entry] = candidates[index]!
      index = (index + 1) % candidates.length
      lastKey = key
      scanned += 1
      if (findAttachmentByRequestId === undefined || entry.nativeOperationId === undefined) {
        unknown += 1
        continue
      }
      let recovery: AttachmentUploadRecoveryResult
      try {
        recovery = attachmentUploadRecoveryResultOf(await findAttachmentByRequestId(
          entry.nativeOperationId, AbortSignal.timeout(15_000)))
      } catch {
        unknown += 1
        continue
      }
      if (recovery.state === 'found') {
        const response = attachmentUploadResponseOf(recovery.response, entry.name ?? '')
        if (response === undefined) {
          unknown += 1
          continue
        }
        try {
          await this.setAttachmentUploadResult(key, entry.fingerprint, response, entry.nativeOperationId)
          found += 1
        } catch {
          unknown += 1
        }
      } else if (recovery.state === 'not-committed') {
        try {
          await this.markAttachmentUploadNotCommitted(key, entry.fingerprint)
          notCommitted += 1
        } catch {
          unknown += 1
        }
      } else {
        unknown += 1
      }
    }
    const nextCursor = scanned < candidates.length ? lastKey : undefined
    this.attachmentReconciliationCursor = nextCursor
    return nextCursor === undefined
      ? { scanned, found, notCommitted, unknown }
      : { scanned, found, notCommitted, unknown, nextCursor }
  }

  /**
   * Returns the request id which created a session for one authenticated
   * device.  Session snapshots use this correlation only to recover a
   * detached create after its live `session.created` event was lost.
   */
  async sessionCreationCorrelationForSession(deviceId: string, sessionId: string,
                                              observedCreateRequestId?: string): Promise<{
    requestId?: string
    suppressNativeOperationId?: boolean
  }> {
    const prefix = `${deviceId}\0`
    for (const [key, entry] of this.sessionCreationResults) {
      if (!key.startsWith(prefix)) continue
      const matchesSession = entry.sessionId === sessionId
      const matchesNativeOperation = observedCreateRequestId !== undefined &&
        entry.nativeOperationId === observedCreateRequestId
      if (!matchesSession && !matchesNativeOperation) continue
      // A native create may have committed before a later setup stage ran.
      // Do not project that request to the phone until the setup transaction
      // is complete: otherwise a crash between native create and the
      // permission/model/title steps makes iOS send the first prompt under
      // the wrong sandbox.  Hide the internal operation marker as well; it is
      // only an adapter recovery key, never a client request id.
      if (entry.setupComplete !== true) {
        return { suppressNativeOperationId: true }
      }
      return { requestId: key.slice(prefix.length) }
    }
    return {}
  }

  async sessionCreationRequestIdForSession(deviceId: string, sessionId: string,
                                           observedCreateRequestId?: string): Promise<string | undefined> {
    return (await this.sessionCreationCorrelationForSession(
      deviceId, sessionId, observedCreateRequestId)).requestId
  }

  async markSessionCreationNotCommitted(key: string, fingerprint: string | undefined): Promise<void> {
    if (this.persistenceUnavailable) {
      throw new HttpError(503, 'session creation metadata is unavailable; repair session-metadata.json', 'unknown')
    }
    const entry = this.sessionCreationResults.get(key)
    if (entry === undefined) return
    if (entry.fingerprint !== undefined && fingerprint !== undefined && entry.fingerprint !== fingerprint) {
      throw new HttpError(409, 'idempotency key was reused with different request data')
    }
    this.sessionCreationResults.delete(key)
    const previousCapacityExceeded = this.persistenceCapacityExceeded
    const previousMetadataByteLength = this.metadataByteLength
    try {
      await this.persist()
    } catch (error) {
      this.sessionCreationResults.set(key, entry)
      this.persistenceCapacityExceeded = previousCapacityExceeded
      this.metadataByteLength = previousMetadataByteLength
      throw error
    }
  }

  /**
   * Remove only completed session-create tombstones after an operator has
   * explicitly confirmed that the corresponding request ids are no longer
   * replayable.  Completed records are otherwise permanent: evicting one by
   * age would turn an offline retry into a second native session.  The
   * Connector-only admin route is therefore an intentional, auditable escape
   * hatch for the bounded metadata file rather than an automatic TTL.
   */
  async compactSessionCreationRecords(keys: readonly string[]): Promise<number> {
    if (this.persistenceUnavailable) {
      throw new HttpError(503, 'session creation metadata is unavailable; repair session-metadata.json', 'unknown')
    }
    if (keys.length > 128) throw new HttpError(400, 'at most 128 session creation records may be compacted at once')
    const uniqueKeys = [...new Set(keys)]
    const removed = new Map<string, SessionCreationRecord>()
    const previousCapacityExceeded = this.persistenceCapacityExceeded
    const previousMetadataByteLength = this.metadataByteLength
    for (const key of uniqueKeys) {
      const entry = this.sessionCreationResults.get(key)
      if (entry === undefined) continue
      if (entry.response === undefined || entry.setupComplete !== true) {
        throw new HttpError(409, 'only completed session creation records may be compacted')
      }
      removed.set(key, entry)
    }
    for (const key of removed.keys()) {
      this.sessionCreationResults.delete(key)
    }
    if (removed.size === 0) return 0
    try {
      await this.persist()
    } catch (error) {
      for (const [key, entry] of removed) this.sessionCreationResults.set(key, entry)
      this.persistenceCapacityExceeded = previousCapacityExceeded
      this.metadataByteLength = previousMetadataByteLength
      throw error
    }
    return removed.size
  }

  async setSessionCreationPending(key: string, fingerprint: string | undefined,
                                  setup: SessionCreationSetup,
                                  nativeOperationId?: string): Promise<void> {
    if (this.persistenceUnavailable) {
      throw new HttpError(503, 'session creation metadata is unavailable; repair session-metadata.json', 'unknown')
    }
    this.rejectGrowthWhileOverCapacity('session creation metadata capacity is full')
    if (!this.sessionCreationResults.has(key) && this.sessionCreationResults.size >= MAX_SESSION_CREATION_RECORDS) {
      // Completed records are permanent at-most-once tombstones. Evicting a
      // response after an arbitrary retention period would let a phone that
      // was offline for months invoke native create a second time. Fail closed
      // at capacity and require operator reconciliation instead.
      throw new HttpError(503, 'session creation idempotency capacity is full', 'unknown')
    }
    const previous = this.sessionCreationResults.get(key)
    const previousCapacityExceeded = this.persistenceCapacityExceeded
    const previousMetadataByteLength = this.metadataByteLength
    this.sessionCreationResults.set(key, {
      schemaVersion: SESSION_CREATION_RECORD_SCHEMA_VERSION,
      fingerprint, pending: true, setup, setupComplete: false,
      ...(nativeOperationId === undefined ? {} : { nativeOperationId }),
    })
    try {
      await this.persist()
    } catch (error) {
      if (previous === undefined) this.sessionCreationResults.delete(key)
      else this.sessionCreationResults.set(key, previous)
      this.persistenceCapacityExceeded = previousCapacityExceeded
      this.metadataByteLength = previousMetadataByteLength
      throw error
    }
  }

  async setSessionCreationStarted(key: string, fingerprint: string | undefined,
                                  sessionId: string, setup: SessionCreationSetup,
                                  nativeOperationId?: string): Promise<void> {
    if (this.persistenceUnavailable) {
      throw new HttpError(503, 'session creation metadata is unavailable; repair session-metadata.json', 'unknown')
    }
    this.rejectGrowthWhileOverCapacity('session creation metadata capacity is full')
    const previous = this.sessionCreationResults.get(key)
    const previousCapacityExceeded = this.persistenceCapacityExceeded
    const previousMetadataByteLength = this.metadataByteLength
    this.sessionCreationResults.set(key, {
      schemaVersion: SESSION_CREATION_RECORD_SCHEMA_VERSION,
      fingerprint,
      sessionId,
      setup,
      setupComplete: false,
      ...(nativeOperationId === undefined ? {} : { nativeOperationId }),
    })
    try {
      await this.persist()
    } catch (error) {
      if (previous === undefined) this.sessionCreationResults.delete(key)
      else this.sessionCreationResults.set(key, previous)
      this.persistenceCapacityExceeded = previousCapacityExceeded
      this.metadataByteLength = previousMetadataByteLength
      throw error
    }
  }

  async setSessionCreationResult(key: string, fingerprint: string | undefined,
                                 response: JsonObject, setup?: SessionCreationSetup): Promise<void> {
    if (this.persistenceUnavailable) {
      throw new HttpError(503, 'session creation metadata is unavailable; repair session-metadata.json', 'unknown')
    }
    this.rejectGrowthWhileOverCapacity('session creation metadata capacity is full')
    const sessionId = typeof response.sessionId === 'string' ? response.sessionId : undefined
    const previous = this.sessionCreationResults.get(key)
    const previousCapacityExceeded = this.persistenceCapacityExceeded
    const previousMetadataByteLength = this.metadataByteLength
    this.sessionCreationResults.set(key, {
      schemaVersion: SESSION_CREATION_RECORD_SCHEMA_VERSION,
      fingerprint,
      response,
      ...(sessionId === undefined ? {} : { sessionId }),
      ...(setup === undefined ? {} : { setup }),
      setupComplete: true,
      completedAt: Date.now(),
    })
    try {
      await this.persist()
    } catch (error) {
      if (previous === undefined) this.sessionCreationResults.delete(key)
      else this.sessionCreationResults.set(key, previous)
      this.persistenceCapacityExceeded = previousCapacityExceeded
      this.metadataByteLength = previousMetadataByteLength
      throw error
    }
  }

  remoteMutationEntry(key: string, fingerprint: string | undefined): RemoteMutationRecord | undefined {
    if (this.persistenceUnavailable) {
      throw new HttpError(503, 'remote mutation metadata is unavailable; repair session-metadata.json', 'unknown')
    }
    const entry = this.remoteMutationResults.get(key)
    if (entry === undefined) return undefined
    if (entry.fingerprint !== undefined && fingerprint !== undefined && entry.fingerprint !== fingerprint) {
      throw new HttpError(409, 'idempotency key was reused with different request data')
    }
    return entry
  }

  async setRemoteMutationPending(key: string, fingerprint: string | undefined): Promise<void> {
    if (this.persistenceUnavailable) {
      throw new HttpError(503, 'remote mutation metadata is unavailable; repair session-metadata.json', 'unknown')
    }
    this.rejectGrowthWhileOverCapacity('remote mutation metadata capacity is full')
    if (!this.remoteMutationResults.has(key) && this.remoteMutationResults.size >= MAX_REMOTE_MUTATION_RECORDS) {
      throw new HttpError(503, 'remote mutation idempotency capacity is full', 'unknown')
    }
    const previous = this.remoteMutationResults.get(key)
    const previousCapacityExceeded = this.persistenceCapacityExceeded
    const previousMetadataByteLength = this.metadataByteLength
    this.remoteMutationResults.set(key, { fingerprint, pending: true, createdAt: Date.now() })
    try {
      await this.persist()
    } catch (error) {
      if (previous === undefined) this.remoteMutationResults.delete(key)
      else this.remoteMutationResults.set(key, previous)
      this.persistenceCapacityExceeded = previousCapacityExceeded
      this.metadataByteLength = previousMetadataByteLength
      throw error
    }
  }

  async setRemoteMutationResult(key: string, fingerprint: string | undefined,
                                status: number, response: unknown): Promise<void> {
    if (this.persistenceUnavailable) {
      throw new HttpError(503, 'remote mutation metadata is unavailable; repair session-metadata.json', 'unknown')
    }
    const previous = this.remoteMutationResults.get(key)
    if (previous === undefined || previous.pending !== true) {
      throw new HttpError(409, 'remote mutation journal is missing its pending record', 'unknown')
    }
    const previousCapacityExceeded = this.persistenceCapacityExceeded
    const previousMetadataByteLength = this.metadataByteLength
    this.remoteMutationResults.set(key, {
      fingerprint,
      ...(previous.createdAt === undefined ? {} : { createdAt: previous.createdAt }),
      status,
      response: response === undefined ? null : response,
      completedAt: Date.now(),
    })
    try {
      await this.persist()
    } catch (error) {
      this.remoteMutationResults.set(key, previous)
      this.persistenceCapacityExceeded = previousCapacityExceeded
      this.metadataByteLength = previousMetadataByteLength
      throw error
    }
  }

  /**
   * Release a pending mutation only when the native adapter has positively
   * rejected it before accepting any side effect. Unknown failures must keep
   * the pending tombstone so a retry cannot execute the operation twice.
   */
  async markRemoteMutationNotCommitted(key: string, fingerprint: string | undefined): Promise<void> {
    if (this.persistenceUnavailable) {
      throw new HttpError(503, 'remote mutation metadata is unavailable; repair session-metadata.json', 'unknown')
    }
    const entry = this.remoteMutationResults.get(key)
    if (entry === undefined) return
    if (entry.fingerprint !== undefined && fingerprint !== undefined && entry.fingerprint !== fingerprint) {
      throw new HttpError(409, 'idempotency key was reused with different request data')
    }
    if (entry.pending !== true) return
    const previousCapacityExceeded = this.persistenceCapacityExceeded
    const previousMetadataByteLength = this.metadataByteLength
    this.remoteMutationResults.delete(key)
    try {
      await this.persist()
    } catch (error) {
      this.remoteMutationResults.set(key, entry)
      this.persistenceCapacityExceeded = previousCapacityExceeded
      this.metadataByteLength = previousMetadataByteLength
      throw error
    }
  }

  async compactRemoteMutationRecords(keys: readonly string[]): Promise<number> {
    if (this.persistenceUnavailable) {
      throw new HttpError(503, 'remote mutation metadata is unavailable; repair session-metadata.json', 'unknown')
    }
    if (keys.length > 128) throw new HttpError(400, 'at most 128 remote mutation records may be compacted at once')
    const removed = new Map<string, RemoteMutationRecord>()
    const previousCapacityExceeded = this.persistenceCapacityExceeded
    const previousMetadataByteLength = this.metadataByteLength
    for (const key of [...new Set(keys)]) {
      const entry = this.remoteMutationResults.get(key)
      if (entry === undefined) continue
      if (entry.pending === true || entry.response === undefined) {
        throw new HttpError(409, 'only completed remote mutation records may be compacted')
      }
      removed.set(key, entry)
    }
    for (const key of removed.keys()) {
      this.remoteMutationResults.delete(key)
    }
    if (removed.size === 0) return 0
    try {
      await this.persist()
    } catch (error) {
      for (const [key, entry] of removed) this.remoteMutationResults.set(key, entry)
      this.persistenceCapacityExceeded = previousCapacityExceeded
      this.metadataByteLength = previousMetadataByteLength
      throw error
    }
    return removed.size
  }

  remoteMutationPending(limit: number, afterKey?: string): {
    items: readonly { key: string; fingerprint?: string; createdAt?: number }[]
    nextAfterKey?: string
  } {
    const keys = [...this.remoteMutationResults.keys()]
      .filter((key) => this.remoteMutationResults.get(key)?.pending === true)
      .sort()
      .filter((key) => afterKey === undefined || key > afterKey)
    const selected = keys.slice(0, limit)
    return {
      items: selected.map((key) => {
        const entry = this.remoteMutationResults.get(key)!
        return {
          key,
          ...(entry.fingerprint === undefined ? {} : { fingerprint: entry.fingerprint }),
          ...(entry.createdAt === undefined ? {} : { createdAt: entry.createdAt }),
        }
      }),
      ...(keys.length > selected.length && selected.length > 0
        ? { nextAfterKey: selected[selected.length - 1] } : {}),
    }
  }

  /**
   * Resolve pending remote mutations only through an explicit Connector-admin
   * action. A "not-committed" resolution releases capacity; a completed
   * resolution installs the operator-supplied authoritative response so a
   * later retry replays it instead of executing the native mutation again.
   */
  async resolveRemoteMutations(keys: readonly string[], resolution: {
    kind: 'not-committed' | 'completed'
    status?: number
    response?: unknown
  }): Promise<number> {
    if (this.persistenceUnavailable) {
      throw new HttpError(503, 'remote mutation metadata is unavailable; repair session-metadata.json', 'unknown')
    }
    if (keys.length > 128) throw new HttpError(400, 'at most 128 remote mutation keys may be resolved at once')
    if (resolution.kind === 'completed' &&
        (resolution.status === undefined || !Number.isSafeInteger(resolution.status) ||
         resolution.status < 100 || resolution.status > 599 || resolution.response === undefined)) {
      throw new HttpError(400, 'completed resolution requires a valid status and response')
    }
    const uniqueKeys = [...new Set(keys)]
    const previous = new Map<string, RemoteMutationRecord>()
    for (const key of uniqueKeys) {
      const entry = this.remoteMutationResults.get(key)
      if (entry === undefined) continue
      if (entry.pending !== true) {
        throw new HttpError(409, 'only pending remote mutation records may be resolved')
      }
      previous.set(key, entry)
    }
    // Validate the complete batch before changing the in-memory map. A mixed
    // request (one pending key followed by a completed key) must not leave
    // the earlier key half-resolved when the endpoint returns 409.
    for (const [key, entry] of previous) {
      if (resolution.kind === 'not-committed') {
        this.remoteMutationResults.delete(key)
      } else {
        const status = resolution.status
        if (status === undefined || resolution.response === undefined) {
          throw new HttpError(400, 'completed resolution requires a valid status and response')
        }
        this.remoteMutationResults.set(key, {
          fingerprint: entry.fingerprint,
          ...(entry.createdAt === undefined ? {} : { createdAt: entry.createdAt }),
          status,
          response: resolution.response,
          completedAt: Date.now(),
        })
      }
    }
    if (previous.size === 0) return 0
    const previousCapacityExceeded = this.persistenceCapacityExceeded
    const previousMetadataByteLength = this.metadataByteLength
    try {
      await this.persist()
    } catch (error) {
      for (const [key, entry] of previous) this.remoteMutationResults.set(key, entry)
      this.persistenceCapacityExceeded = previousCapacityExceeded
      this.metadataByteLength = previousMetadataByteLength
      throw error
    }
    return previous.size
  }

  async setArchived(sessionId: string, archived: boolean): Promise<void> {
    const wasArchived = this.archived.has(sessionId)
    const wasUnarchived = this.unarchived.has(sessionId)
    const previousCapacityExceeded = this.persistenceCapacityExceeded
    const previousMetadataByteLength = this.metadataByteLength
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
    try {
      await this.persist()
    } catch (error) {
      if (wasArchived) this.archived.add(sessionId)
      else this.archived.delete(sessionId)
      if (wasUnarchived) this.unarchived.add(sessionId)
      else this.unarchived.delete(sessionId)
      this.persistenceCapacityExceeded = previousCapacityExceeded
      this.metadataByteLength = previousMetadataByteLength
      throw error
    }
  }

  async setPermission(sessionId: string, mode: PermissionMode): Promise<void> {
    const previous = this.permissions.get(sessionId)
    const previousCapacityExceeded = this.persistenceCapacityExceeded
    const previousMetadataByteLength = this.metadataByteLength
    this.permissions.set(sessionId, mode)
    try {
      await this.persist()
    } catch (error) {
      if (previous === undefined) this.permissions.delete(sessionId)
      else this.permissions.set(sessionId, previous)
      this.persistenceCapacityExceeded = previousCapacityExceeded
      this.metadataByteLength = previousMetadataByteLength
      throw error
    }
  }

  async setTitle(sessionId: string, title: string): Promise<void> {
    const trimmed = title.trim().slice(0, 512)
    if (trimmed.length === 0) return
    const previous = this.titles.get(sessionId)
    const previousCapacityExceeded = this.persistenceCapacityExceeded
    const previousMetadataByteLength = this.metadataByteLength
    this.titles.set(sessionId, trimmed)
    try {
      await this.persist()
    } catch (error) {
      if (previous === undefined) this.titles.delete(sessionId)
      else this.titles.set(sessionId, previous)
      this.persistenceCapacityExceeded = previousCapacityExceeded
      this.metadataByteLength = previousMetadataByteLength
      throw error
    }
  }

  async setBranch(sessionId: string, branch: string): Promise<void> {
    const trimmed = branch.trim().slice(0, 512)
    if (trimmed.length === 0) return
    const previous = this.branches.get(sessionId)
    const previousCapacityExceeded = this.persistenceCapacityExceeded
    const previousMetadataByteLength = this.metadataByteLength
    this.branches.set(sessionId, trimmed)
    try {
      await this.persist()
    } catch (error) {
      if (previous === undefined) this.branches.delete(sessionId)
      else this.branches.set(sessionId, previous)
      this.persistenceCapacityExceeded = previousCapacityExceeded
      this.metadataByteLength = previousMetadataByteLength
      throw error
    }
  }

  private async load(): Promise<void> {
    let migratedAttachmentMetadata = false
    try {
      const metadataStats = await stat(this.path)
      if (metadataStats.size > MAX_SESSION_METADATA_LOAD_BYTES) {
        throw new Error('session presentation metadata exceeds its load safety size')
      }
      this.metadataByteLength = metadataStats.size
      this.persistenceCapacityExceeded = metadataStats.size > MAX_SESSION_METADATA_BYTES
      const parsedValue: unknown = JSON.parse(await readFile(this.path, 'utf8'))
      if (typeof parsedValue !== 'object' || parsedValue === null || Array.isArray(parsedValue)) {
        throw new Error('session metadata root must be an object')
      }
      const parsed = parsedValue as JsonObject
      const schemaVersion = parsed.sessionCreationSchemaVersion
      if (schemaVersion !== undefined && schemaVersion !== SESSION_CREATION_RECORD_SCHEMA_VERSION) {
        throw new Error('session creation metadata schema version is unsupported')
      }
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
      const titles = parsed.titles
      if (typeof titles === 'object' && titles !== null && !Array.isArray(titles)) {
        for (const [id, title] of Object.entries(titles)) {
          if (typeof title === 'string' && title.trim().length > 0) this.titles.set(id, title.trim().slice(0, 512))
        }
      }
      const branches = parsed.branches
      if (typeof branches === 'object' && branches !== null && !Array.isArray(branches)) {
        for (const [id, branch] of Object.entries(branches)) {
          if (typeof branch === 'string' && branch.trim().length > 0) this.branches.set(id, branch.trim().slice(0, 512))
        }
      }
      const sessionCreations = parsed.sessionCreations
      if (sessionCreations !== undefined &&
          (typeof sessionCreations !== 'object' || sessionCreations === null || Array.isArray(sessionCreations))) {
        throw new Error('session creation metadata must be an object')
      }
      if (typeof sessionCreations === 'object' && sessionCreations !== null && !Array.isArray(sessionCreations)) {
        if (Object.keys(sessionCreations).length > MAX_SESSION_CREATION_RECORDS) {
          throw new Error('session creation metadata exceeds its safety capacity')
        }
        for (const [key, raw] of Object.entries(sessionCreations)) {
          if (typeof raw !== 'object' || raw === null || Array.isArray(raw)) {
            throw new Error('session creation metadata contains an invalid record')
          }
          if (raw.fingerprint !== undefined && typeof raw.fingerprint !== 'string') {
            throw new Error('session creation fingerprint metadata is invalid')
          }
          if (raw.schemaVersion !== undefined && raw.schemaVersion !== SESSION_CREATION_RECORD_SCHEMA_VERSION) {
            throw new Error('session creation record schema version is unsupported')
          }
          if (raw.setupComplete !== undefined && typeof raw.setupComplete !== 'boolean') {
            throw new Error('session creation completion metadata is invalid')
          }
          if (raw.completedAt !== undefined &&
              (typeof raw.completedAt !== 'number' || !Number.isFinite(raw.completedAt) || raw.completedAt < 0)) {
            throw new Error('session creation completion timestamp is invalid')
          }
          if (raw.nativeOperationId !== undefined && typeof raw.nativeOperationId !== 'string') {
            throw new Error('session creation native operation metadata is invalid')
          }
          const fingerprint = typeof raw.fingerprint === 'string' ? raw.fingerprint : undefined
          const nativeOperationId = typeof raw.nativeOperationId === 'string' ? raw.nativeOperationId : undefined
          const response = raw.response
          let setup: SessionCreationSetup | undefined
          if (raw.setup !== undefined) {
            setup = sessionCreationSetupOf(raw.setup)
            if (setup === undefined) throw new Error('session creation setup metadata is invalid')
          }
          if (typeof response === 'object' && response !== null && !Array.isArray(response)) {
            const sessionId = typeof raw.sessionId === 'string'
              ? raw.sessionId
              : typeof (response as JsonObject).sessionId === 'string'
                ? (response as JsonObject).sessionId as string
                : undefined
            if (sessionId === undefined || sessionId.length === 0) {
              throw new Error('session creation response is missing its session id')
            }
            const legacySetupUnknown = raw.schemaVersion === undefined || raw.setupComplete === undefined
            this.sessionCreationResults.set(key, {
              ...(raw.schemaVersion === SESSION_CREATION_RECORD_SCHEMA_VERSION
                ? { schemaVersion: SESSION_CREATION_RECORD_SCHEMA_VERSION } : {}),
              fingerprint,
              response: response as JsonObject,
              ...(sessionId === undefined ? {} : { sessionId }),
              ...(nativeOperationId === undefined ? {} : { nativeOperationId }),
              ...(setup === undefined ? {} : { setup }),
              setupComplete: legacySetupUnknown ? false : raw.setupComplete === true,
              ...(legacySetupUnknown ? { legacySetupUnknown: true } : {}),
              ...(typeof raw.completedAt === 'number' ? { completedAt: raw.completedAt } : {}),
            })
          } else if (typeof raw.sessionId === 'string') {
            if (raw.sessionId.length === 0) throw new Error('session creation session id is empty')
            this.sessionCreationResults.set(key, {
              ...(raw.schemaVersion === SESSION_CREATION_RECORD_SCHEMA_VERSION
                ? { schemaVersion: SESSION_CREATION_RECORD_SCHEMA_VERSION } : {}),
              fingerprint,
              sessionId: raw.sessionId,
              ...(nativeOperationId === undefined ? {} : { nativeOperationId }),
              ...(setup === undefined ? {} : { setup }),
              setupComplete: raw.setupComplete === true,
              ...(typeof raw.completedAt === 'number' ? { completedAt: raw.completedAt } : {}),
            })
          } else if (raw.pending === true) {
            this.sessionCreationResults.set(key, {
              ...(raw.schemaVersion === SESSION_CREATION_RECORD_SCHEMA_VERSION
                ? { schemaVersion: SESSION_CREATION_RECORD_SCHEMA_VERSION } : {}),
              fingerprint,
              pending: true,
              ...(nativeOperationId === undefined ? {} : { nativeOperationId }),
              ...(setup === undefined ? {} : { setup }),
              setupComplete: false,
            })
          } else {
            throw new Error('session creation metadata contains an incomplete record')
          }
        }
      }
      const remoteMutations = parsed.remoteMutations
      if (remoteMutations !== undefined &&
          (typeof remoteMutations !== 'object' || remoteMutations === null || Array.isArray(remoteMutations))) {
        throw new Error('remote mutation metadata must be an object')
      }
      if (typeof remoteMutations === 'object' && remoteMutations !== null && !Array.isArray(remoteMutations)) {
        if (Object.keys(remoteMutations).length > MAX_REMOTE_MUTATION_RECORDS) {
          throw new Error('remote mutation metadata exceeds its safety capacity')
        }
        for (const [key, raw] of Object.entries(remoteMutations)) {
          if (typeof raw !== 'object' || raw === null || Array.isArray(raw)) {
            throw new Error('remote mutation metadata contains an invalid record')
          }
          if (raw.fingerprint !== undefined && typeof raw.fingerprint !== 'string') {
            throw new Error('remote mutation fingerprint metadata is invalid')
          }
          if (raw.pending !== undefined && typeof raw.pending !== 'boolean') {
            throw new Error('remote mutation pending metadata is invalid')
          }
          if (raw.createdAt !== undefined &&
              (typeof raw.createdAt !== 'number' || !Number.isFinite(raw.createdAt) || raw.createdAt < 0)) {
            throw new Error('remote mutation creation timestamp is invalid')
          }
          if (raw.status !== undefined &&
              (typeof raw.status !== 'number' || !Number.isSafeInteger(raw.status) || raw.status < 100 || raw.status > 599)) {
            throw new Error('remote mutation status metadata is invalid')
          }
          if (raw.completedAt !== undefined &&
              (typeof raw.completedAt !== 'number' || !Number.isFinite(raw.completedAt) || raw.completedAt < 0)) {
            throw new Error('remote mutation completion timestamp is invalid')
          }
          const hasResponse = raw.response !== undefined
          if (raw.pending === true && hasResponse) {
            throw new Error('remote mutation metadata cannot be pending and completed')
          }
          if (raw.pending !== true && !hasResponse) {
            throw new Error('remote mutation metadata contains an incomplete record')
          }
          if (raw.pending !== true && raw.status === undefined) {
            throw new Error('remote mutation completed record is missing its status')
          }
          this.remoteMutationResults.set(key, {
            fingerprint: typeof raw.fingerprint === 'string' ? raw.fingerprint : undefined,
            ...(raw.pending === true ? { pending: true } : {}),
            ...(typeof raw.createdAt === 'number' ? { createdAt: raw.createdAt } : {}),
            ...(typeof raw.status === 'number' ? { status: raw.status } : {}),
            ...(hasResponse ? { response: raw.response } : {}),
            ...(typeof raw.completedAt === 'number' ? { completedAt: raw.completedAt } : {}),
          })
        }
      }
      const attachmentUploads = parsed.attachmentUploads
      if (attachmentUploads !== undefined &&
          (typeof attachmentUploads !== 'object' || attachmentUploads === null || Array.isArray(attachmentUploads))) {
        throw new Error('attachment upload metadata must be an object')
      }
      if (typeof attachmentUploads === 'object' && attachmentUploads !== null && !Array.isArray(attachmentUploads)) {
        let activeAttachmentRecordCount = 0
        let expiredAttachmentRecordCount = 0
        for (const [key, raw] of Object.entries(attachmentUploads)) {
          if (typeof raw !== 'object' || raw === null || Array.isArray(raw)) {
            throw new Error('attachment upload metadata contains an invalid record')
          }
          if (raw.fingerprint !== undefined && typeof raw.fingerprint !== 'string') {
            throw new Error('attachment upload fingerprint metadata is invalid')
          }
          if (raw.name !== undefined && typeof raw.name !== 'string') {
            throw new Error('attachment upload name metadata is invalid')
          }
          if (raw.nativeOperationId !== undefined && typeof raw.nativeOperationId !== 'string') {
            throw new Error('attachment upload operation metadata is invalid')
          }
          if (raw.pending !== undefined && typeof raw.pending !== 'boolean') {
            throw new Error('attachment upload pending metadata is invalid')
          }
          if (raw.expired !== undefined && typeof raw.expired !== 'boolean') {
            throw new Error('attachment upload expiration metadata is invalid')
          }
          if (raw.reconciled !== undefined && typeof raw.reconciled !== 'boolean') {
            throw new Error('attachment upload reconciliation metadata is invalid')
          }
          if (raw.createdAt !== undefined &&
              (typeof raw.createdAt !== 'number' || !Number.isFinite(raw.createdAt) || raw.createdAt < 0)) {
            throw new Error('attachment upload creation timestamp is invalid')
          }
          if (raw.completedAt !== undefined &&
              (typeof raw.completedAt !== 'number' || !Number.isFinite(raw.completedAt) || raw.completedAt < 0)) {
            throw new Error('attachment upload completion timestamp is invalid')
          }
          if (raw.expiredAt !== undefined &&
              (typeof raw.expiredAt !== 'number' || !Number.isFinite(raw.expiredAt) || raw.expiredAt < 0)) {
            throw new Error('attachment upload expiration timestamp is invalid')
          }
          const response = raw.response
          if (response !== undefined &&
              (typeof response !== 'object' || response === null || Array.isArray(response))) {
            throw new Error('attachment upload response metadata is invalid')
          }
          if (raw.reconciled === true && (raw.expired !== true || response === undefined)) {
            throw new Error('reconciled attachment upload metadata is inconsistent')
          }
          if (raw.expired === true && (raw.pending === true ||
              (response !== undefined && raw.reconciled !== true))) {
            throw new Error('expired attachment upload metadata is inconsistent')
          }
          if (response === undefined && raw.pending !== true && raw.expired !== true) {
            throw new Error('attachment upload metadata contains an incomplete record')
          }
          if (raw.expired === true && raw.reconciled !== true) {
            expiredAttachmentRecordCount += 1
            if (expiredAttachmentRecordCount > MAX_ATTACHMENT_UPLOAD_TOMBSTONES) {
              throw new Error('attachment upload metadata exceeds its tombstone safety capacity')
            }
          } else if (raw.expired !== true) {
            activeAttachmentRecordCount += 1
          }
          const completedAt = typeof raw.completedAt === 'number'
            ? raw.completedAt
            : response === undefined ? undefined : Date.now()
          const createdAt = typeof raw.createdAt === 'number'
            ? raw.createdAt
            : raw.pending === true ? Date.now() : undefined
          const expiredAt = typeof raw.expiredAt === 'number'
            ? raw.expiredAt
            : raw.expired === true ? Date.now() : undefined
          if ((response !== undefined && raw.completedAt === undefined) ||
              (raw.pending === true && raw.createdAt === undefined) ||
              (raw.expired === true && raw.expiredAt === undefined)) {
            migratedAttachmentMetadata = true
          }
          if (activeAttachmentRecordCount > MAX_ATTACHMENT_UPLOAD_RECORDS) {
            throw new Error('attachment upload metadata exceeds its active safety capacity')
          }
          this.attachmentUploadResults.set(key, {
            fingerprint: typeof raw.fingerprint === 'string' ? raw.fingerprint : undefined,
            ...(typeof raw.name === 'string' ? { name: raw.name } : {}),
            ...(typeof raw.nativeOperationId === 'string' ? { nativeOperationId: raw.nativeOperationId } : {}),
            ...(raw.pending === true ? { pending: true } : {}),
            ...(raw.expired === true ? { expired: true } : {}),
            ...(raw.reconciled === true ? { reconciled: true } : {}),
            ...(response === undefined ? {} : { response: response as JsonObject }),
            ...(createdAt === undefined ? {} : { createdAt }),
            ...(completedAt === undefined ? {} : { completedAt }),
            ...(expiredAt === undefined ? {} : { expiredAt }),
          })
        }
      }
    } catch (error) {
      // A missing or corrupt presentation file must never prevent Harness from
      // starting; the durable Harness session store remains authoritative.
      if (!isMissingFileError(error)) {
        this.persistenceUnavailable = true
        this.warn('Session presentation metadata is unreadable; refusing durable session creation until it is repaired')
      }
    }
    if (migratedAttachmentMetadata && !this.persistenceUnavailable) {
      try { await this.persist() } catch { /* persistenceUnavailable is set by persist */ }
    }
  }

  private persist(allowCapacityRecoveryReplacement = false): Promise<void> {
    if (this.persistenceUnavailable) {
      return Promise.reject(new Error('session presentation metadata is unavailable'))
    }
    // Capture an immutable snapshot at mutation time. Concurrent requests then
    // serialize atomic replacements instead of racing writeFile calls against
    // the same path or exposing a partially-written JSON document on crash.
    const snapshot = JSON.stringify({
      sessionCreationSchemaVersion: SESSION_CREATION_RECORD_SCHEMA_VERSION,
      archived: [...this.archived],
      unarchived: [...this.unarchived],
      permissions: Object.fromEntries(this.permissions),
      titles: Object.fromEntries(this.titles),
      branches: Object.fromEntries(this.branches),
      sessionCreations: Object.fromEntries(this.sessionCreationResults),
      remoteMutations: Object.fromEntries(this.remoteMutationResults),
      attachmentUploads: Object.fromEntries(this.attachmentUploadResults),
    }, null, 2)
    const snapshotBytes = Buffer.byteLength(snapshot, 'utf8')
    if (snapshotBytes > MAX_SESSION_METADATA_BYTES) {
      // A pre-existing oversized file is repairable only through shrink-only
      // writes. Reject growth, but do not poison the store so an operator can
      // reconcile expired attachment tombstones and compact it below the cap.
      const canReplaceOneExpiredRecord = allowCapacityRecoveryReplacement &&
        this.persistenceCapacityExceeded && snapshotBytes < MAX_SESSION_METADATA_LOAD_BYTES
      if (!canReplaceOneExpiredRecord &&
          (!this.persistenceCapacityExceeded || snapshotBytes >= this.metadataByteLength)) {
        // There may be no file yet (for example the very first oversized
        // request). Use the rejected snapshot as the recovery baseline so a
        // later deletion can still shrink it into a writable range.
        if (this.metadataByteLength === 0) this.metadataByteLength = snapshotBytes
        this.persistenceCapacityExceeded = true
        return Promise.reject(new Error('session presentation metadata exceeds its safety size'))
      }
    }
    this.persistQueue = this.persistQueue.catch(() => undefined).then(async () => {
      if (this.persistenceUnavailable) throw new Error('session presentation metadata is unavailable')
      const directory = dirname(this.path)
      await mkdir(directory, { recursive: true })
      await chmod(directory, 0o700)
      const temporaryPath = `${this.path}.${randomUUID()}.tmp`
      await writeFile(temporaryPath, `${snapshot}\n`, { encoding: 'utf8', mode: 0o600 })
      await rename(temporaryPath, this.path)
      this.metadataByteLength = snapshotBytes
      this.persistenceCapacityExceeded = snapshotBytes > MAX_SESSION_METADATA_BYTES
    }).catch((error: unknown) => {
      this.persistenceUnavailable = true
      throw error
    })
    return this.persistQueue
  }
}

function sessionCreationSetupOf(value: unknown): SessionCreationSetup | undefined {
  if (typeof value !== 'object' || value === null || Array.isArray(value)) return undefined
  const body = value as Record<string, unknown>
  if (body.branch !== undefined && typeof body.branch !== 'string') return undefined
  if (body.title !== undefined && typeof body.title !== 'string') return undefined
  if (body.permissionMode !== undefined && body.permissionMode !== 'read-only' &&
      body.permissionMode !== 'workspace-write' && body.permissionMode !== 'danger-full-access') return undefined
  const branch = typeof body.branch === 'string' ? body.branch : undefined
  const title = typeof body.title === 'string' ? body.title : undefined
  const rawModel = body.model
  let model: SessionCreationSetup['model']
  if (rawModel !== undefined &&
      (typeof rawModel !== 'object' || rawModel === null || Array.isArray(rawModel))) return undefined
  if (typeof rawModel === 'object' && rawModel !== null && !Array.isArray(rawModel)) {
    const modelBody = rawModel as Record<string, unknown>
    if (typeof modelBody.provider !== 'string' || typeof modelBody.model !== 'string') return undefined
    if (modelBody.reasoningEffort !== undefined && typeof modelBody.reasoningEffort !== 'string') return undefined
    model = {
      provider: modelBody.provider,
      model: modelBody.model,
      ...(typeof modelBody.reasoningEffort === 'string' ? { reasoningEffort: modelBody.reasoningEffort } : {}),
    }
  }
  const permissionMode = body.permissionMode === 'read-only' ||
    body.permissionMode === 'workspace-write' || body.permissionMode === 'danger-full-access'
    ? body.permissionMode : undefined
  if (branch === undefined && title === undefined && model === undefined && permissionMode === undefined) return {}
  return {
    ...(branch === undefined ? {} : { branch }),
    ...(title === undefined ? {} : { title }),
    ...(model === undefined ? {} : { model }),
    ...(permissionMode === undefined ? {} : { permissionMode }),
  }
}

function isPermissionMode(value: unknown): value is PermissionMode {
  return value === 'ask' || value === 'never' || value === 'read-only' || value === 'workspace-write' || value === 'danger-full-access'
}

function isMissingFileError(value: unknown): value is NodeJS.ErrnoException {
  return typeof value === 'object' && value !== null && 'code' in value && value.code === 'ENOENT'
}

function isPermissionPreset(value: PermissionMode): value is 'read-only' | 'workspace-write' | 'danger-full-access' {
  return value === 'read-only' || value === 'workspace-write' || value === 'danger-full-access'
}

function retryableSessionSetupError(error: unknown): HttpError {
  if (error instanceof HttpError) {
    // The native session already exists at this point. The outer HTTP cache
    // must release the id so the durable setup record can be resumed, while
    // the Connector must continue to report the create as result-unknown.
    return new HttpError(error.status, error.message, 'retryable-committed')
  }
  return new HttpError(502, error instanceof Error ? error.message : String(error), 'retryable-committed')
}

/**
 * These adapter errors are raised before the native mutation is accepted
 * (missing session/service or rejected input).  They are the only failures
 * allowed to release a durable remote-mutation pending record.  Timeouts and
 * generic adapter failures remain result-unknown and stay fail-closed.
 */
function remoteMutationDefinitelyNotCommitted(error: unknown): error is HttpError {
  return error instanceof HttpError &&
    (error.status === 400 || error.status === 404 || error.status === 409 || error.status === 413 || error.status === 501)
}

async function applySessionCreationSetup(
  ctx: NativeContext,
  metadata: SessionMetadataStore,
  sessionId: string,
  setup: SessionCreationSetup,
): Promise<void> {
  // A blank session is represented as “新会话” by the projection below. Do
  // not persist that placeholder: it used to override the native title
  // service forever, so the first real user message could never receive its
  // semantic Harness-generated title.
  if (setup.branch !== undefined && setup.branch.length > 0) {
    await metadata.setBranch(sessionId, setup.branch)
  }
  if (setup.title !== undefined && setup.title.length > 0 && ctx.sessionController.rename !== undefined) {
    try {
      await ctx.sessionController.rename({ sessionId, title: setup.title })
    } catch {
      // The metadata projection is an old-Harness fallback only for an
      // explicitly supplied title, never for the blank-session placeholder.
      await metadata.setTitle(sessionId, setup.title)
    }
  }
  // Older Harness versions ignore `model` during create. Repeating the
  // selection is harmless and makes recovery of a partial create idempotent.
  if (setup.model !== undefined) {
    await ctx.sessionController.selectModel({ sessionId, ...setup.model })
  }
  if (setup.permissionMode !== undefined) {
    armSilentSetupWindow(sessionId)
    const permissionResult = await executeCommand(ctx, sessionId, `/permission ${setup.permissionMode}`, [])
    const failure = remoteFailureOf(permissionResult)
    if (failure !== undefined) throw new HttpError(502, failure)
    await metadata.setPermission(sessionId, setup.permissionMode)
  }
}

function metadataPath(): string {
  return join(process.env.DSH_ANYWHERE_DATA_DIR ?? join(homedir(), 'Library', 'Application Support', 'DSH Anywhere'), 'session-metadata.json')
}

/**
 * Native Harness adapters receive a bounded opaque operation id rather than
 * the Bridge's NUL-delimited durable key.  If the adapter persists this id on
 * the created session, a Bridge restart can reconcile a tombstone that was
 * written just before the native create returned.
 */
function nativeOperationIdFor(durableKey: string): string {
  return createHash('sha256').update(durableKey).digest('hex')
}

function remoteMutationKeyFor(originDeviceId: string, path: string, requestId: string): string {
  return `${originDeviceId}\0${path}\0${requestId}`
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
  /** Set when the link carries a single-use code rather than the long secret. */
  readonly expiresAt?: number
}

/**
 * The connector keeps a freshly minted single-use code beside its config. A code
 * is preferred over the long-lived secret because it expires and is consumed on
 * use, so a QR left on screen is not a standing credential.
 */
async function readPairingCode(configPath: string): Promise<{ code: string; expiresAt: number } | undefined> {
  let parsed: unknown
  try {
    parsed = JSON.parse(await readFile(join(dirname(configPath), 'pairing-code.json'), 'utf8'))
  } catch {
    return undefined
  }
  const record = recordOf(parsed)
  const code = typeof record.code === 'string' ? record.code.trim() : ''
  const expiresAt = typeof record.expiresAt === 'number' ? record.expiresAt : 0
  // An expired file counts as absent: showing a dead code would walk the user
  // into a failure they have no way to diagnose.
  if (code === '' || expiresAt <= Date.now()) return undefined
  return { code, expiresAt }
}

export async function readPairingMaterial(configPath: string): Promise<PairingMaterial | undefined> {
  let parsed: unknown
  try {
    parsed = JSON.parse(await readFile(configPath, 'utf8'))
  } catch {
    return undefined
  }
  const record = recordOf(parsed)
  const relay = typeof record.relayURL === 'string' ? record.relayURL : undefined
  const machineId = typeof record.machineId === 'string' ? record.machineId : undefined
  if (relay === undefined || machineId === undefined) return undefined
  const issued = await readPairingCode(configPath)
  try {
    if (issued !== undefined) {
      return {
        link: pairingLink({ relay, machineId, pairingCode: issued.code }),
        relay: relayHTTPSURL(relay),
        machineId,
        expiresAt: issued.expiresAt,
      }
    }
    const pairingSecret = typeof record.pairingSecret === 'string' ? record.pairingSecret : undefined
    if (pairingSecret === undefined) return undefined
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
    ${credentialNote(material)}
    <p class="hint">Served on loopback only &mdash; the credential never leaves this Mac.</p>
  `, material.link)
}

/**
 * Says plainly which kind of credential the code above carries: the difference
 * decides whether it can be reused and how long it stays valid.
 */
function credentialNote(material: PairingMaterial): string {
  if (material.expiresAt === undefined) {
    return '<p class="hint">Long-lived pairing secret &mdash; reusable until rotated.</p>'
  }
  const minutes = Math.max(1, Math.round((material.expiresAt - Date.now()) / 60_000))
  return `<p class="hint">Single-use code &mdash; expires in about ${minutes} minute${minutes === 1 ? '' : 's'}.</p>`
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
  // A Bridge restart creates a new sequence space. Connectors persist their
  // cursor across socket reconnects, so the epoch makes that cursor scoped to
  // this Bridge process rather than accidentally to a later process.
  const bridgeEpoch = randomUUID()
  const approvals = new PendingApprovals()
  const questions = new PendingQuestions()
  const idempotentResponses = new IdempotentHttpResponses()
  const metadata = new SessionMetadataStore(metadataPath(), (message) => ctx.logger.warn(message))
  const clients = new Set<WebSocket>()
  const clientDeviceIds = new Map<WebSocket, string>()
  const relayDevices = new Set<string>()
  /** Each Connector process owns a lease on the Relay presence it reports.
   * A superseded process must not be able to clear the replacement's state. */
  const relayDeviceLeases = new Map<string, ConnectorLease>()
  /** Highest Relay machine lease observed for each phone. Bridge socket
   * ordering is only a tie-breaker; the Relay lease is the ownership source. */
  const latestRelayGenerations = new Map<string, { epoch: string; generation: number }>()
  /** Highest Bridge socket generation accepted for each device/Relay lease.
   * Keep it after an offline edge so a delayed old `online` cannot resurrect
   * the device once the current lease has been removed. */
  const latestBridgeLeases = new Map<string, {
    bridgeEpoch: string
    relayEpoch: string
    relayGeneration: number
    generation: number
  }>()
  const clientConnectorIds = new Map<WebSocket, string>()
  const connectorGenerations = new Map<string, number>()
  const clientConnectorGenerations = new Map<WebSocket, number>()
  let nextConnectorGeneration = 0
  const connectorGenerationOf = (connectorId: string): number | undefined => {
    const generation = connectorGenerations.get(connectorId)
    return generation !== undefined && [...clientConnectorGenerations.values()].includes(generation)
      ? generation : undefined
  }
  const hasActiveConnector = (connectorId: string): boolean =>
    [...clientConnectorIds.entries()].some(([client, value]) => value === connectorId && client.readyState === WebSocket.OPEN)
  const hasRemoteDecisionClient = (): boolean => relayDevices.size > 0 ||
    [...clientDeviceIds.values()].some((deviceId) => deviceId !== CONNECTOR_DEVICE_ID)
  const wss = new WebSocketServer({ noServer: true })

  const publish = (event: NativeEventInput, recipients: Iterable<WebSocket> = clients): void => {
    const sequence = replay.latestSequence + 1
    const next = EventEnvelopeSchema.parse({
      version: PROTOCOL_VERSION,
      messageId: event.messageId ?? randomUUID(),
      timestamp: Date.now(),
      machineId,
      deviceId: event.deviceId ?? 'broadcast',
      sequence,
      type: event.type,
      payload: event.payload,
      ...(event.sessionId === undefined ? {} : { sessionId: event.sessionId }),
      ...(event.historyBatchId === undefined ? {} : { historyBatchId: event.historyBatchId }),
    })
    const entry = replay.append(next, event.replay !== false)
    const wire = JSON.stringify({ ...next, sequence: entry.sequence })
    for (const client of recipients) {
      if (client.readyState === WebSocket.OPEN) client.send(wire)
    }
  }

  const route = ctx.webServer.register({
    kind: 'prefix',
    path: prefix,
    handler: async (req, res) => {
      const serve = async (target: ServerResponse): Promise<void> => {
        try {
          await handleHttp(
            ctx, req, target, prefix, pairing, pairingRateLimiter, approvals, machineId, metadata, publish,
            config.connectorConfigPath ?? defaultConnectorConfigPath(),
            questions,
            relayDevices,
            relayDeviceLeases,
            latestRelayGenerations,
            latestBridgeLeases,
            bridgeEpoch,
            connectorGenerationOf,
            () => {
              if (!hasRemoteDecisionClient()) {
                approvals.rejectAll()
                questions.rejectAll(new Error('all remote devices disconnected'))
              }
            },
          )
        } catch (error) {
          const status = error instanceof HttpError ? error.status : 500
          const outcome = error instanceof HttpError ? error.idempotencyOutcome : 'unknown'
          json(target, status, { error: error instanceof Error ? error.message : String(error) }, {
            'x-dsh-idempotency-outcome': outcome,
          })
        }
      }

      // The Connector forwards the phone's request id. Scope the cache to the
      // authenticated principal and exact mutation route so two Connector
      // processes cannot execute the same local side effect twice.
      const requestId = header(req, 'x-dsh-request-id')
      const authorization = header(req, 'authorization')
      // Authenticate before reserving an idempotency slot.  A caller with an
      // invalid token can reach this local HTTP listener, but must not be able
      // to fill the shared 2,000-entry tombstone budget with 401 responses and
      // starve the trusted Connector.  The authenticated device id is the
      // stable cache scope; the bearer itself is intentionally not retained in
      // the key or any captured request state.
      const authenticatedDevice = authorization === undefined
        ? undefined
        : pairing.authenticate(authorization)
      if (req.method === 'POST' && requestId !== undefined && requestId.length > 0 && requestId.length <= 256 &&
          authenticatedDevice !== undefined) {
        const pathname = new URL(req.url ?? '/', 'http://localhost').pathname
        const originDeviceId = authenticatedDevice.id === CONNECTOR_DEVICE_ID
          ? (header(req, 'x-dsh-origin-device-id') ?? '') : authenticatedDevice.id
        const key = createHash('sha256')
          .update(`${authenticatedDevice.id}\0${originDeviceId}\0${req.method}\0${pathname}\0${requestId}`)
          .digest('hex')
        const suppliedHash = header(req, 'x-dsh-request-hash')
        const fingerprint = suppliedHash !== undefined && /^[a-f0-9]{64}$/i.test(suppliedHash)
          ? suppliedHash.toLowerCase()
          : undefined
        try {
          await idempotentResponses.respond(key, fingerprint, req, res, serve)
        } catch (error) {
          const status = error instanceof HttpError ? error.status : 500
          json(res, status, { error: error instanceof Error ? error.message : String(error) })
        }
        return
      }
      await serve(res)
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
        // A WebSocket can emit `error` for a malformed frame or a peer-side
        // transport failure without closing first.  `ws` treats an unhandled
        // error event as an uncaught exception, which would bring down the
        // Bridge process and every Connector attached to it.  Install the
        // listener before replaying anything to the client; the close handler
        // below remains the single place that releases connection state.
        client.on('error', (error: unknown) => {
          const detail = error instanceof Error ? error.message : String(error)
          ctx.logger.warn(`Bridge WebSocket error: ${detail}`)
        })
        clients.add(client)
        clientDeviceIds.set(client, device.id)
        const requestedConnectorId = device.id === CONNECTOR_DEVICE_ID
          ? new URL(req.url ?? '/', 'http://localhost').searchParams.get('connectorId')
          : null
        const bridgeConnectionId = device.id === CONNECTOR_DEVICE_ID
          ? (requestedConnectorId !== null && requestedConnectorId.length > 0 && requestedConnectorId.length <= 256
            ? requestedConnectorId : randomUUID())
          : undefined
        if (device.id === CONNECTOR_DEVICE_ID) {
          const generation = ++nextConnectorGeneration
          clientConnectorIds.set(client, bridgeConnectionId!)
          clientConnectorGenerations.set(client, generation)
          connectorGenerations.set(bridgeConnectionId!, generation)
        }
        const after = parseAfter(req.url)
        const oldest = replay.after(0)[0]?.sequence
        const replayTruncated = after > 0 && oldest !== undefined && oldest > after + 1
        for (const entry of replay.after(after)) {
          client.send(JSON.stringify({ ...entry.event, sequence: entry.sequence }))
        }
        publish({
          deviceId: device.id,
          type: 'connection.ready',
          replay: false,
          payload: {
            machineId,
            deviceId: device.id,
            serverTime: Date.now(),
            // The current handshake is also stored in the replay buffer.  A
            // Connector must be able to distinguish this socket's greeting
            // from an older greeting that happens to have a larger sequence
            // than the replay entries already buffered for the socket.
            ...(bridgeConnectionId === undefined ? {} : { bridgeConnectionId }),
            capabilities: [
            'sessions', 'workspaces', 'archive', 'prompt', 'attachments',
            'cancel', 'approval', 'permissions', 'models', 'commands', 'usage', 'replay', 'questions',
            ],
            ...(after > 0 ? { resumedFrom: after } : {}),
            bridgeEpoch,
            ...(replayTruncated ? { replayTruncated: true } : {}),
          },
        }, [client])
        void (async () => {
          const items = await listSummaries(ctx, metadata, false, device.id)
          publish({ deviceId: device.id, type: 'session.snapshot', payload: items }, [client])
          await publishModelCatalog(ctx, publish, device.id)
          // Seed the live model projection from the authoritative snapshot
          // before the resume fast-path below. Existing sessions may not emit
          // a fresh model/selection record until the user changes the model;
          // without this seed, that first explicit switch looked like initial
          // setup and never produced the inline conversation notice.
          for (const item of items) {
            const summary = normalizeSessionSummary(item, ctx, metadata)
            if (summary.provider !== undefined && summary.model !== undefined) {
              modelSelections.set(summary.id, {
                provider: summary.provider,
                model: summary.model,
                ...(summary.reasoningEffort === undefined ? {} : { reasoningEffort: summary.reasoningEffort }),
              })
            }
          }
          if (after !== 0) return
          let remaining = 1_000
          for (const item of items.slice(0, 25)) {
            if (remaining <= 0 || client.readyState !== WebSocket.OPEN) break
            const summary = normalizeSessionSummary(item, ctx, metadata)
            const inspection = await ctx.sessionController.inspect(summary.id, AbortSignal.timeout(15_000))
            const allEvents = inspection.events
            const recentCount = Math.min(200, remaining)
            const recentStart = Math.max(0, allEvents.length - recentCount)
            const historyToolNames = new Map<string, string>()
            const historyUsageCounters = new Map<string, UsageCounter>()
            const historyModelSelections = new Map<string, ModelSelectionProjection>()
            const batchId = randomUUID()
            let publishedUsage = false
            // Same brackets as publishSessionHistory: the fresh client must
            // be able to replace each session transcript atomically even
            // though 25 sessions backfill over one socket.
            publish({ deviceId: device.id, sessionId: summary.id, type: 'history.started',
              historyBatchId: batchId,
              payload: { sessionId: summary.id, batchId } }, [client])
            for (let index = 0; index < allEvents.length; index += 1) {
              const event = allEvents[index]
              const normalized = normalizeSessionEvents(summary.id, event, historyToolNames, historyUsageCounters, historyModelSelections)
              if (index < recentStart) continue
              for (const next of normalized) {
                if (next.type === 'usage.updated') publishedUsage = true
                publish({ ...next, deviceId: device.id, historyBatchId: batchId }, [client])
              }
            }
            // The phone only needs recent message/tool rows, but the footer
            // must include the complete durable session. Processing all events
            // above builds that accumulator without flooding a fresh client
            // with thousands of historical transcript cards.
            const completeUsage = historyUsageCounters.get(summary.id)
            if (!publishedUsage && completeUsage !== undefined && hasUsage(completeUsage)) {
              publish({
                deviceId: device.id,
                sessionId: summary.id,
                type: 'usage.updated',
                historyBatchId: batchId,
                payload: {
                  sessionId: summary.id,
                  usage: { ...usageSnapshot(completeUsage), rounds: completeUsage.rounds, steps: completeUsage.steps },
                },
              }, [client])
            }
            publish({ deviceId: device.id, sessionId: summary.id, type: 'history.completed',
              historyBatchId: batchId,
              payload: { sessionId: summary.id, batchId } }, [client])
            remaining -= recentCount
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
          clientDeviceIds.delete(client)
          if (device.id === CONNECTOR_DEVICE_ID) {
            const connectorId = clientConnectorIds.get(client)
            clientConnectorIds.delete(client)
            const generation = clientConnectorGenerations.get(client)
            clientConnectorGenerations.delete(client)
            if (connectorId !== undefined && generation !== undefined &&
                connectorGenerations.get(connectorId) === generation && !hasActiveConnector(connectorId)) {
              connectorGenerations.delete(connectorId)
              for (const [deviceId, lease] of relayDeviceLeases) {
                if (lease.connectorId !== connectorId || lease.generation !== generation) continue
                relayDeviceLeases.delete(deviceId)
                relayDevices.delete(deviceId)
              }
            }
          }
          if (!hasRemoteDecisionClient()) {
            approvals.rejectAll()
            questions.rejectAll(new Error('all remote devices disconnected'))
          }
        })
      })
    },
  })

  const toolNames = new Map<string, string>()
  const usageCounters = new Map<string, UsageCounter>()
  // The Harness emits model/selection records without the previous value. A
  // small in-memory projection lets the bridge turn a real mid-session switch
  // into a transcript event while ignoring the initial selection.
  const modelSelections = new Map<string, ModelSelectionProjection>()
  // The Harness assigns the durable assistant-message UUID only after an
  // attempt settles. Keep the temporary stream id by its durable turn/step so
  // the following session/event can explicitly replace the live bubble.
  const liveStreamMessageIDs = new Map<string, string>()
  // Keep just a short trailing window of live reasoning. It is enough for the
  // composer activity line (which follows the newest text), avoids repeatedly
  // relaying an unbounded chain of thought, and the durable assistant event
  // restores the complete folded reasoning once the step commits.
  const liveStreamAttempts = new Map<string, LiveStreamAttempt>()
  ctx.on('agent/assistant-stream' as never, ((value: unknown) => {
    const payload = recordOf(value)
    const agent = recordOf(payload.agent)
    const sessionId = typeof agent.id === 'string' ? agent.id : undefined
    const frame = recordOf(payload.frame)
    const frameType = typeof frame.type === 'string' ? frame.type : ''
    const attemptId = typeof frame.attemptId === 'string' ? frame.attemptId : undefined
    if (sessionId === undefined || attemptId === undefined) return

    if (frameType === 'start') {
      const key = liveStreamKey(sessionId, frame.turn, frame.step)
      if (key === undefined) return
      const messageId = liveStreamMessageID(key)
      liveStreamMessageIDs.set(key, messageId)
      liveStreamAttempts.set(attemptId, { key, messageId, sessionId, reasoningTrail: '' })
      return
    }

    const attempt = liveStreamAttempts.get(attemptId)
    if (attempt === undefined) return
    if (frameType === 'chunk') {
      const event = liveStreamChunkEvent(attempt, frame.chunk)
      if (event !== undefined) publish(event)
      return
    }

    if (frameType === 'end') {
      const outcome = recordOf(frame.outcome)
      const committedMessage = outcome.kind === 'committed' && outcome.eventType === 'assistant/message'
      if (!committedMessage) {
        publish({
          sessionId: attempt.sessionId,
          type: 'assistant.message.discarded',
          payload: { messageId: attempt.messageId },
        })
        liveStreamMessageIDs.delete(attempt.key)
      }
      liveStreamAttempts.delete(attemptId)
    }
  }) as never, { global: true })

  ctx.on('session/event' as never, ((session: { id: string }, event: unknown) => {
    if (isSilentSetupEcho(session.id, event)) return
    const normalized = normalizeSessionEvents(
      session.id, event, toolNames, usageCounters, modelSelections, liveStreamMessageIDs,
    )
    for (const next of normalized) publish(next)
    if (recordOf(event).type === 'assistant/message') {
      const data = recordOf(recordOf(event).data)
      const key = liveStreamKey(session.id, data.turn, data.step)
      if (key !== undefined) liveStreamMessageIDs.delete(key)
    }
    // The native title service writes a durable `session/title` event after
    // the first actual user message. Project that fresh authoritative summary
    // immediately so a new phone session stops saying “新会话” without waiting
    // for the next manual list refresh. The same path covers web/Mac renames.
    if (isSessionTitleEvent(event)) {
      void listSummaries(ctx, metadata, true).then((items) => {
        const summary = items.find((item) => item.id === session.id)
        if (summary !== undefined) publish({ type: 'session.created', payload: summary })
      }).catch((error: unknown) => {
        publish({ type: 'protocol.error', payload: { code: 'session-title-refresh-failed', message: String(error), retryable: true } })
      })
    }
  }) as never, { global: true })

  ctx.on('session/created' as never, ((session: unknown) => {
    const summary = normalizeLiveSession(session, ctx, metadata)
    // Without this a delegated subagent still pops into the user's list, since
    // the Harness announces every new session.
    if (isSubagentSession(summary)) return
    publish({ type: 'session.created', payload: summary })
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
    if (!hasRemoteDecisionClient()) return next()
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
      const decision = await firstAnswered<ApprovalOutcome>(
        pending.result.then<ApprovalOutcome>((value) => value).catch(() => undefined),
        next(),
        (value) => value === 'allowed-once' || value === 'rejected',
      )
      approvals.discard(pending.id)
      publish({
        type: 'approval.resolved',
        sessionId: request.agent.id,
        payload: { id: pending.id, allowed: decision === 'allowed-once' },
      })
      return decision ?? 'unavailable'
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
    if (!hasRemoteDecisionClient()) return next()
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
  relayDevices: Set<string>,
  relayDeviceLeases: Map<string, ConnectorLease>,
  latestRelayGenerations: Map<string, { epoch: string; generation: number }>,
  latestBridgeLeases: Map<string, {
    bridgeEpoch: string
    relayEpoch: string
    relayGeneration: number
    generation: number
  }>,
  bridgeEpoch: string,
  connectorGenerationOf: (connectorId: string) => number | undefined,
  onRemotePresenceChanged: () => void,
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

  if (req.method === 'POST' && path === '/admin/attachments/reconcile') {
    if (device.id !== CONNECTOR_DEVICE_ID) {
      throw new HttpError(403, 'only the Connector may reconcile attachment uploads')
    }
    const body = objectOf(await readJson(req))
    const requestedLimit = body.limit === undefined ? MAX_ATTACHMENT_RECONCILIATION_BATCH : body.limit
    if (typeof requestedLimit !== 'number' || !Number.isSafeInteger(requestedLimit) ||
        requestedLimit < 1 || requestedLimit > MAX_ATTACHMENT_RECONCILIATION_BATCH) {
      throw new HttpError(400, `limit must be an integer between 1 and ${MAX_ATTACHMENT_RECONCILIATION_BATCH}`)
    }
    const afterKey = body.afterKey === undefined ? undefined : stringOf(body.afterKey)
    if (afterKey !== undefined && (afterKey.length === 0 || afterKey.length > 2_048)) {
      throw new HttpError(400, 'afterKey must be between 1 and 2048 characters')
    }
    const result = await metadata.reconcileExpiredAttachmentUploads(
      ctx.sessionController.findAttachmentByRequestId, requestedLimit, afterKey)
    json(res, 200, result)
    return
  }

  if (req.method === 'POST' && path === '/admin/session-creations/compact') {
    if (device.id !== CONNECTOR_DEVICE_ID) {
      throw new HttpError(403, 'only the Connector may compact session creation records')
    }
    const body = objectOf(await readJson(req))
    if (!Array.isArray(body.keys) || body.keys.length > 128 ||
        body.keys.some((key) => typeof key !== 'string' || key.length === 0 || key.length > 512)) {
      throw new HttpError(400, 'keys must be an array of at most 128 durable session creation keys')
    }
    const keys = body.keys as string[]
    const removed = await metadata.compactSessionCreationRecords(keys)
    json(res, 200, { removed })
    return
  }

  if (req.method === 'POST' && path === '/admin/remote-mutations/compact') {
    if (device.id !== CONNECTOR_DEVICE_ID) {
      throw new HttpError(403, 'only the Connector may compact remote mutation records')
    }
    const body = objectOf(await readJson(req))
    if (!Array.isArray(body.keys) || body.keys.length > 128 ||
        body.keys.some((key) => typeof key !== 'string' || key.length === 0 || key.length > 1_024)) {
      throw new HttpError(400, 'keys must be an array of at most 128 durable remote mutation keys')
    }
    const keys = body.keys as string[]
    const removed = await metadata.compactRemoteMutationRecords(keys)
    json(res, 200, { removed })
    return
  }

  if (req.method === 'GET' && path === '/admin/remote-mutations/pending') {
    if (device.id !== CONNECTOR_DEVICE_ID) {
      throw new HttpError(403, 'only the Connector may inspect pending remote mutations')
    }
    const rawLimit = url.searchParams.get('limit')
    const limit = rawLimit === null ? 128 : Number(rawLimit)
    if (!Number.isSafeInteger(limit) || limit < 1 || limit > 128) {
      throw new HttpError(400, 'limit must be an integer between 1 and 128')
    }
    const afterKey = url.searchParams.get('afterKey') ?? undefined
    if (afterKey !== undefined && (afterKey.length === 0 || afterKey.length > 1_024)) {
      throw new HttpError(400, 'afterKey must be between 1 and 1024 characters')
    }
    json(res, 200, metadata.remoteMutationPending(limit, afterKey))
    return
  }

  if (req.method === 'POST' && path === '/admin/remote-mutations/reconcile') {
    if (device.id !== CONNECTOR_DEVICE_ID) {
      throw new HttpError(403, 'only the Connector may reconcile remote mutations')
    }
    const body = objectOf(await readJson(req))
    if (!Array.isArray(body.keys) || body.keys.length > 128 ||
        body.keys.some((key) => typeof key !== 'string' || key.length === 0 || key.length > 1_024)) {
      throw new HttpError(400, 'keys must be an array of at most 128 durable remote mutation keys')
    }
    const kind = body.kind
    if (kind !== 'not-committed' && kind !== 'completed') {
      throw new HttpError(400, 'kind must be not-committed or completed')
    }
    if (body.confirm !== true) {
      throw new HttpError(400, 'remote mutation reconciliation requires confirm=true')
    }
    if (kind === 'completed' &&
        (typeof body.status !== 'number' || !Number.isSafeInteger(body.status) ||
         body.status < 100 || body.status > 599 || body.response === undefined)) {
      throw new HttpError(400, 'completed resolution requires a valid status and response')
    }
    const resolution = kind === 'completed'
      ? { kind: 'completed' as const, status: body.status as number, response: body.response }
      : { kind: 'not-committed' as const }
    const resolved = await metadata.resolveRemoteMutations(body.keys as string[], resolution)
    json(res, 200, { resolved, kind })
    return
  }

  const presenceMatch = /^\/devices\/([^/]+)\/presence$/.exec(path)
  if (req.method === 'POST' && presenceMatch !== null) {
    if (device.id !== CONNECTOR_DEVICE_ID) throw new HttpError(403, 'only the Connector may report Relay presence')
    const deviceId = decodeURIComponent(presenceMatch[1]!)
    const body = objectOf(await readJson(req))
    const connectorId = stringOf(body.connectorId)
    if (connectorId.length === 0 || connectorId.length > 256) {
      throw new HttpError(400, 'connectorId is required')
    }
    const generation = connectorGenerationOf(connectorId)
    if (generation === undefined) {
      // A delayed presence request from a Connector whose Bridge socket has
      // already gone away must not resurrect its lease.  The replacement will
      // report again after its own socket is established.
      throw new HttpError(409, 'connector is no longer connected')
    }
    const relayGeneration = typeof body.relayGeneration === 'number' ? body.relayGeneration : undefined
    const relayEpoch = stringOf(body.relayEpoch)
    if (relayGeneration === undefined || !Number.isSafeInteger(relayGeneration) || relayGeneration < 1) {
      throw new HttpError(400, 'relayGeneration is required')
    }
    if (relayEpoch.length === 0 || relayEpoch.length > 256) {
      throw new HttpError(400, 'relayEpoch is required')
    }
    if (body.online === true) {
      const latestRelayLease = latestRelayGenerations.get(deviceId)
      if (latestRelayLease !== undefined &&
          (relayGeneration < latestRelayLease.generation ||
           (relayGeneration === latestRelayLease.generation && relayEpoch !== latestRelayLease.epoch))) {
        throw new HttpError(409, 'Relay connector lease is stale')
      }
      const latestBridgeLease = latestBridgeLeases.get(deviceId)
      // Bridge generations fence delayed HTTP requests independently of the
      // Relay epoch.  A random Relay epoch has no ordering semantics, so an
      // older socket must not become authoritative merely because its epoch
      // string differs from the current one.  A newer persistent Relay lease
      // is the primary owner, however: its Bridge socket may have been opened
      // before an older owner's socket and must still be able to take over.
      // Only compare Bridge generations while both reports belong to the same
      // Relay lease.
      if (latestBridgeLease !== undefined &&
          latestBridgeLease.relayGeneration === relayGeneration &&
          latestBridgeLease.relayEpoch === relayEpoch &&
          generation < latestBridgeLease.generation) {
        throw new HttpError(409, 'Bridge connector lease is stale')
      }
      const currentLease = relayDeviceLeases.get(deviceId)
      const currentRelayLease = currentLease?.relayEpoch === relayEpoch &&
        currentLease.relayGeneration === relayGeneration
      const bridgeIsCurrent = currentLease === undefined ||
        !currentRelayLease || generation >= currentLease.generation
      if (bridgeIsCurrent) {
        latestRelayGenerations.set(deviceId, {
          epoch: relayEpoch,
          generation: relayGeneration,
        })
        latestBridgeLeases.set(deviceId, {
          bridgeEpoch,
          relayEpoch,
          relayGeneration,
          generation,
        })
        relayDeviceLeases.set(deviceId, {
          connectorId, generation, relayGeneration, relayEpoch,
        })
        relayDevices.add(deviceId)
      } else throw new HttpError(409, 'Bridge connector lease is stale')
    } else if (body.online === false) {
      const lease = relayDeviceLeases.get(deviceId)
      if (lease?.connectorId === connectorId && lease.generation === generation &&
          lease.relayGeneration === relayGeneration && lease.relayEpoch === relayEpoch) {
        relayDeviceLeases.delete(deviceId)
        relayDevices.delete(deviceId)
      }
    }
    else throw new HttpError(400, 'online must be a boolean')
    onRemotePresenceChanged()
    json(res, 202, { accepted: true, deviceId, online: body.online })
    return
  }

  if (req.method === 'GET' && path === '/sessions') {
    const includeArchived = url.searchParams.get('includeArchived') === 'true'
    const requestedDeviceId = device.id === CONNECTOR_DEVICE_ID
      ? url.searchParams.get('deviceId') ?? undefined
      : device.id
    json(res, 200, { items: await listSummaries(ctx, metadata, includeArchived, requestedDeviceId) })
    return
  }

  const openMatch = /^\/sessions\/([^/]+)\/open$/.exec(path)
  if (req.method === 'POST' && openMatch !== null) {
    const sessionId = decodeURIComponent(openMatch[1]!)
    const summary = (await listSummaries(ctx, metadata, true, device.id)).find((item) => item.id === sessionId)
    if (summary === undefined) throw new HttpError(404, 'session not found')
    const body = objectOf(await readJson(req))
    const recipient = historyRecipient(device.id, body.deviceId)
    await publishSessionHistory(ctx, summary, recipient, publish)
    json(res, 202, { accepted: true, sessionId })
    return
  }

  if (req.method === 'GET' && path === '/models') {
    json(res, 200, await ctx.sessionController.modelCatalog())
    return
  }
  if (req.method === 'GET' && path === '/workspaces') {
    json(res, 200, { workspaces: workspaceCatalog(ctx) })
    return
  }
  if (req.method === 'POST' && path === '/workspaces') {
    const requestId = header(req, 'x-dsh-request-id')
    if (requestId !== undefined && requestId.length > 256) {
      throw new HttpError(400, 'request id must be at most 256 characters')
    }
    const suppliedHash = header(req, 'x-dsh-request-hash')
    const fingerprint = suppliedHash !== undefined && /^[a-f0-9]{64}$/i.test(suppliedHash)
      ? suppliedHash.toLowerCase() : undefined
    const originDeviceId = device.id === CONNECTOR_DEVICE_ID
      ? (header(req, 'x-dsh-origin-device-id') ?? device.id) : device.id
    if (originDeviceId.length === 0 || originDeviceId.length > 256) {
      throw new HttpError(400, 'origin device id is invalid')
    }
    if (device.id === CONNECTOR_DEVICE_ID && originDeviceId !== CONNECTOR_DEVICE_ID &&
        !relayDevices.has(originDeviceId)) {
      throw new HttpError(403, 'origin device is not connected through Relay')
    }
    const body = objectOf(await readJson(req))
    const pathValue = stringOf(body.path)
    const title = optionalStringOf(body.title)?.trim().slice(0, 512)
    const durableKey = requestId === undefined || requestId.length === 0
      ? undefined : remoteMutationKeyFor(originDeviceId, path, requestId)
    if (durableKey !== undefined) {
      const remembered = metadata.remoteMutationEntry(durableKey, fingerprint)
      if (remembered?.response !== undefined && remembered.status !== undefined) {
        json(res, remembered.status, remembered.response)
        return
      }
      if (remembered?.pending === true) {
        throw new HttpError(503, 'remote mutation result is still unknown; reconcile before retrying', 'unknown')
      }
    }
    const registry = workspaceRegistryOf(ctx)
    if (registry?.create === undefined) {
      // A completed durable response remains authoritative even if a later
      // Bridge process was started without the optional workspace adapter.
      // Only new native work requires the capability check.
      throw new HttpError(501, 'Harness workspace creation is unavailable')
    }
    if (durableKey !== undefined) await metadata.setRemoteMutationPending(durableKey, fingerprint)
    let workspace: { id: string; path: string; title: string; sessionIds: readonly string[] }
    try {
      workspace = await registry.create(pathValue, title && title.length > 0 ? title : undefined)
    } catch (error) {
      if (durableKey !== undefined) {
        try {
          // WorkspaceRegistry.create is an atomic capability: a thrown
          // validation/capability error means no workspace was accepted.
          // Release that pending identity so a corrected request can retry;
          // persistence failure keeps the safer unknown tombstone.
          await metadata.markRemoteMutationNotCommitted(durableKey, fingerprint)
        } catch (cleanupError) {
          throw new HttpError(503,
            cleanupError instanceof Error ? cleanupError.message : String(cleanupError), 'unknown')
        }
        throw new RetryableHttpError(400, error instanceof Error ? error.message : String(error))
      }
      throw new HttpError(400, error instanceof Error ? error.message : String(error))
    }
    const response = { workspace: workspaceProjection(workspace) }
    if (durableKey !== undefined) await metadata.setRemoteMutationResult(durableKey, fingerprint, 201, response)
    json(res, 201, response)
    return
  }
  if (req.method === 'GET' && path === '/directories') {
    const picker = directoryPickerOf(ctx)
    const capability = picker?.capability()
    if (capability === undefined) {
      throw new HttpError(501, 'Harness directory browsing is unavailable')
    }
    try {
      const signal = AbortSignal.timeout(15_000)
      // The desktop web app deliberately uses the native macOS chooser when
      // it is attached to a local display.  That chooser has no `list` API:
      // it can only show a dialog on the Mac itself.  The paired phone needs
      // an in-app folder browser, so retain the Harness browse implementation
      // when present and provide its same one-level read-only operation for
      // the native chooser case.
      const listing = capability.kind === 'browse' && capability.list !== undefined
        ? await capability.list(url.searchParams.get('path') ?? undefined, signal)
        : capability.kind === 'native'
          ? await listDirectoriesForPairedDevice(url.searchParams.get('path') ?? undefined, signal)
          : undefined
      if (listing === undefined) throw new HttpError(501, 'Harness directory browsing is unavailable')
      json(res, 200, {
        path: listing.path,
        ...(dirname(listing.path) === listing.path ? {} : { parentPath: dirname(listing.path) }),
        directories: listing.entries.map((entry) => ({ name: entry.name, path: entry.path })),
      })
    } catch (error) {
      if (error instanceof HttpError) throw error
      throw new HttpError(400, error instanceof Error ? error.message : String(error))
    }
    return
  }
  if (req.method === 'GET' && path === '/modes') {
    if (ctx.typertGateway === undefined) throw new HttpError(501, 'Harness mode catalog is unavailable')
    const result = await ctx.typertGateway.invoke({ namespace: 'agentPresets', method: 'list', args: {}, signal: AbortSignal.timeout(15_000) })
    const failure = remoteFailureOf(result)
    if (failure !== undefined) throw new HttpError(502, failure)
    json(res, 200, modeCatalogFromRemote(result))
    return
  }
  if (req.method === 'POST' && path === '/sessions') {
    const requestId = header(req, 'x-dsh-request-id')
    if (requestId !== undefined && requestId.length > 256) {
      throw new HttpError(400, 'request id must be at most 256 characters')
    }
    const suppliedHash = header(req, 'x-dsh-request-hash')
    const fingerprint = suppliedHash !== undefined && /^[a-f0-9]{64}$/i.test(suppliedHash)
      ? suppliedHash.toLowerCase() : undefined
    // Parse the body before looking up a legacy durable record.  A pre-stage-
    // machine record cannot contain the requested setup, so a fingerprinted
    // retry must provide the body needed to safely finish that setup.
    const body = objectOf(await readJson(req))
    const bodyDeviceId = optionalStringOf(body.deviceId)
    const headerDeviceId = header(req, 'x-dsh-origin-device-id')
    if (device.id === CONNECTOR_DEVICE_ID &&
        bodyDeviceId !== undefined && headerDeviceId !== undefined && bodyDeviceId !== headerDeviceId) {
      throw new HttpError(400, 'origin device id does not match its request header')
    }
    const originDeviceId = device.id === CONNECTOR_DEVICE_ID
      ? bodyDeviceId ?? headerDeviceId ?? device.id
      : device.id
    if (originDeviceId.length === 0 || originDeviceId.length > 256) {
      throw new HttpError(400, 'origin device id is invalid')
    }
    if (device.id === CONNECTOR_DEVICE_ID && originDeviceId !== CONNECTOR_DEVICE_ID &&
        !relayDevices.has(originDeviceId)) {
      // A phone paired through Relay is not present in the Bridge-local
      // PairingAuthority.  The Connector's authenticated Relay lease is the
      // authoritative proof that this origin is a currently connected,
      // paired device; using the local pairing table here rejected every
      // normal remote session.create request with 403.
      throw new HttpError(403, 'origin device is not connected through Relay')
    }
    const cwd = optionalStringOf(body.cwd)
    const workspaceId = optionalStringOf(body.workspaceId)
    const agentPreset = optionalStringOf(body.agentPreset)
    const requestedTitle = optionalStringOf(body.title)?.trim().slice(0, 512)
    const requestedBranch = optionalStringOf(body.branch)?.trim().slice(0, 512)
    const model = body.model === undefined ? undefined : modelSelectionOf(body.model)
    const permissionMode = body.permissionMode === undefined
      ? undefined
      : permissionModeOf(body.permissionMode)
    if (permissionMode !== undefined && !isPermissionPreset(permissionMode)) {
      throw new HttpError(400, 'Harness permission presets are read-only, workspace-write and danger-full-access')
    }
    const setup = {
      ...(requestedBranch === undefined ? {} : { branch: requestedBranch }),
      ...(requestedTitle === undefined ? {} : { title: requestedTitle }),
      ...(model === undefined ? {} : { model }),
      ...(permissionMode === undefined ? {} : { permissionMode }),
    }
    // Keep the durable key bounded in the same way as the in-memory
    // idempotency layer and the protocol identifier schema.  Without this
    // guard an authenticated caller could make the on-disk session creation
    // map grow with arbitrarily large request-id headers.
    const durableKey = requestId === undefined || requestId.length === 0
      ? undefined : `${originDeviceId}\0${requestId}`
    const nativeOperationId = durableKey === undefined ? undefined : nativeOperationIdFor(durableKey)
    if (durableKey !== undefined) {
      const remembered = metadata.sessionCreationEntry(durableKey, fingerprint)
      if (remembered?.response !== undefined && remembered.setupComplete === true) {
        // The in-memory HTTP response cache may have expired or the Bridge may
        // have restarted.  Replay the durable create result without invoking
        // Harness a second time.
        json(res, 200, remembered.response)
        return
      }
      if (remembered?.pending === true) {
        // The Bridge may have died after Harness committed the native create
        // but before setSessionCreationStarted() persisted its session id.
        // Never call native create again. Adapters that persist the operation
        // id can reconcile it directly; the list fallback supports adapters
        // that expose the same marker on their session projection.
        let recoveredSessionID: string | undefined
        try {
          if (remembered.nativeOperationId !== undefined) {
            const findByRequestId = ctx.sessionController.findByRequestId
            if (findByRequestId !== undefined) {
              recoveredSessionID = (await findByRequestId(
                remembered.nativeOperationId, AbortSignal.timeout(15_000)))?.sessionId
            }
          }
          if (recoveredSessionID === undefined && remembered.nativeOperationId !== undefined) {
            // Search the adapter's raw projection before any client-facing
            // createRequestId correlation is applied.  A partial native
            // create must stay hidden from iOS until its post-create setup is
            // complete, so the normal list projection intentionally removes
            // this operation marker.
            const summaries = await listSummaries(ctx, metadata, true, undefined, false)
            recoveredSessionID = summaries.find((item) =>
              item.createRequestId === remembered.nativeOperationId)?.id
          }
        } catch {
          recoveredSessionID = undefined
        }
        if (recoveredSessionID === undefined) {
          throw new HttpError(503, 'session creation result is still unknown', 'unknown')
        }
        await metadata.setSessionCreationStarted(
          durableKey, fingerprint, recoveredSessionID, setup, remembered.nativeOperationId)
        try {
          await applySessionCreationSetup(ctx, metadata, recoveredSessionID, setup)
        } catch (error) {
          throw retryableSessionSetupError(error)
        }
        const summary = (await listSummaries(ctx, metadata, true, originDeviceId))
          .find((item) => item.id === recoveredSessionID)
        const response = { sessionId: recoveredSessionID, ...(summary === undefined ? {} : { summary }) }
        await metadata.setSessionCreationResult(durableKey, fingerprint, response, setup)
        json(res, 200, response)
        return
      }
      if (remembered?.legacySetupUnknown === true) {
        // Old releases persisted only `{ sessionId }` (or a response without
        // the stage marker).  Never assume that optional setup completed. A
        // body hash is required before we reconstruct and apply the setup; if
        // the old caller did not provide one, fail closed rather than guessing
        // which permission/model/title was requested.
        if (remembered.fingerprint === undefined || fingerprint === undefined) {
          throw new HttpError(503, 'legacy session creation result is unknown; retry with a request hash', 'unknown')
        }
        if (remembered.sessionId === undefined) {
          throw new HttpError(503, 'legacy session creation result is unknown', 'unknown')
        }
        try {
          await applySessionCreationSetup(ctx, metadata, remembered.sessionId, setup)
        } catch (error) {
          throw retryableSessionSetupError(error)
        }
        const summary = (await listSummaries(ctx, metadata, true, originDeviceId)).find((item) => item.id === remembered.sessionId)
        const response = { sessionId: remembered.sessionId, ...(summary === undefined ? {} : { summary }) }
        await metadata.setSessionCreationResult(durableKey, fingerprint, response, setup)
        json(res, 200, response)
        return
      }
      if (remembered?.sessionId !== undefined) {
        // Native creation already committed, but a post-create setting failed.
        // Resume those idempotent settings instead of replaying a partial
        // `{ sessionId }` record as if the requested session were complete.
        if (remembered.setupComplete !== false || remembered.setup === undefined) {
          throw new HttpError(503, 'session creation setup record is unreadable', 'unknown')
        }
        const setup = remembered.setup
        try {
          await applySessionCreationSetup(ctx, metadata, remembered.sessionId, setup)
        } catch (error) {
          throw retryableSessionSetupError(error)
        }
        const summary = (await listSummaries(ctx, metadata, true, originDeviceId)).find((item) => item.id === remembered.sessionId)
        const response = { sessionId: remembered.sessionId, ...(summary === undefined ? {} : { summary }) }
        await metadata.setSessionCreationResult(durableKey, fingerprint, response, setup)
        json(res, 200, response)
        return
      }
    }
    if (durableKey !== undefined) {
      // Record the operation identity before invoking Harness.  If this
      // process dies while native creation is in flight, a restarted Bridge
      // has a durable tombstone and will refuse a duplicate execution.
      await metadata.setSessionCreationPending(durableKey, fingerprint, setup, nativeOperationId)
    }
    let result: { sessionId: string; agentPreset?: string }
    try {
      result = await ctx.sessionController.create({
        ...(nativeOperationId === undefined ? {} : {
          requestId: nativeOperationId,
          createRequestId: nativeOperationId,
        }),
        ...(cwd === undefined ? {} : { cwd }),
        ...(workspaceId === undefined ? {} : { workspaceId }),
        ...(agentPreset === undefined ? {} : { agentPreset }),
        ...(model === undefined ? {} : { model }),
      })
    } catch (error) {
      // A rejected native call is safe to forget only when the adapter can
      // authoritatively prove that the operation id never committed.  If the
      // adapter cannot answer (or answers with an existing session), retain
      // the pending tombstone and fail closed so a retry cannot create twice.
      let notCommitted = false
      const findByRequestId = ctx.sessionController.findByRequestId
      if (nativeOperationId !== undefined && findByRequestId !== undefined) {
        try {
          notCommitted = (await findByRequestId(
            nativeOperationId, AbortSignal.timeout(15_000))) === undefined
        } catch {
          notCommitted = false
        }
      }
      if (notCommitted && durableKey !== undefined) {
        await metadata.markSessionCreationNotCommitted(durableKey, fingerprint)
      }
      throw error
    }
    // The native create has already committed the side effect at this point.
    // Persist its identity before optional title/model/permission setup, so a
    // later setup failure or a lost response can never make a retry create a
    // second Harness session.  The complete projection below replaces this
    // minimal replay record once setup succeeds.
    if (durableKey !== undefined) {
      await metadata.setSessionCreationStarted(durableKey, fingerprint, result.sessionId, setup, nativeOperationId)
    }
    try {
      await applySessionCreationSetup(ctx, metadata, result.sessionId, setup)
    } catch (error) {
      throw retryableSessionSetupError(error)
    }
    const summary = (await listSummaries(ctx, metadata, true, originDeviceId)).find((item) => item.id === result.sessionId)
    const response = { ...result, ...(summary === undefined ? {} : { summary }) }
    if (durableKey !== undefined) await metadata.setSessionCreationResult(durableKey, fingerprint, response, setup)
    json(res, 201, response)
    return
  }

  const promptMatch = /^\/sessions\/([^/]+)\/prompt$/.exec(path)
  if (req.method === 'POST' && promptMatch !== null) {
    // Prompt content may include a bounded inline image compatibility path.
    // Its body budget is shared with the protocol/Relay instead of inheriting
    // the 1 MiB control-request default.
    const body = objectOf(await readJson(req, MAX_PROMPT_BODY_BYTES))
    const parsed = PromptSendPayloadSchema.safeParse({
      ...(body.text === undefined ? {} : { text: body.text }),
      ...(body.content === undefined ? {} : { content: body.content }),
      ...(body.attachments === undefined ? {} : { attachments: body.attachments }),
      ...(body.mode === undefined ? {} : { mode: body.mode }),
      ...(body.clientTimeZone === undefined ? {} : { clientTimeZone: body.clientTimeZone }),
    })
    if (!parsed.success) throw new HttpError(400, 'prompt requires text or an attachment')
    const text = typeof parsed.data.text === 'string' ? parsed.data.text.trim() : ''
    const mode = parsed.data.mode === 'steer' ? 'steer' : 'queue'
    const requestId = optionalStringOf(body.requestId) ?? randomUUID()
    const clientTimeZone = parsed.data.clientTimeZone
    // Attachments have to sit inside `content`: that is where the Harness looks
    // for receipt ids to bind to the message. Sending them in a field of their
    // own is what made the file arrive without the text that accompanied it.
    const declaredContent = parsed.data.content ?? []
    // Accept both legacy `attachments` and canonical `content` when a client
    // sends them together.  Silently choosing one field used to return
    // `accepted` while dropping the other field's receipts.  The shared
    // schema applies the combined <=16 attachment limit before this merge.
    const content = [
      ...(text.length === 0 || declaredContent.some((part) => part.type === 'text' && part.text === text)
        ? []
        : [{ type: 'text' as const, text }]),
      ...declaredContent,
      ...(parsed.data.attachments ?? []),
    ]
    const sessionId = decodeURIComponent(promptMatch[1]!)
    let result: { accepted: true }
    try {
      result = await ctx.sessionController.prompt({
        requestId,
        sessionId,
        mode,
        content,
        ...(clientTimeZone === undefined ? {} : { clientTimeZone }),
      }, AbortSignal.timeout(15_000))
    } catch (error) {
      const timedOut = error instanceof Error && (error.name === 'TimeoutError' || error.name === 'AbortError')
      if (!timedOut) {
        // A prompt rejection before Harness reports acceptance is safe to try
        // again with the same request id. Timeouts stay unknown because the
        // native call may have crossed its acceptance boundary already.
        throw new RetryableHttpError(503, error instanceof Error ? error.message : String(error))
      }
      throw error
    }
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
    const summary = (await listSummaries(ctx, metadata, true, device.id)).find((item) => item.id === sessionId)
    json(res, 202, { accepted: true, ...(summary === undefined ? {} : { summary }) })
    return
  }

  const renameMatch = /^\/sessions\/([^/]+)\/rename$/.exec(path)
  if (req.method === 'POST' && renameMatch !== null) {
    const sessionId = decodeURIComponent(renameMatch[1]!)
    const title = optionalStringOf(objectOf(await readJson(req)).title)?.trim()
    if (title === undefined || title.length === 0) throw new HttpError(400, 'session title is required')
    if (ctx.sessionController.rename === undefined) throw new HttpError(501, 'Harness session renaming is unavailable')
    await ctx.sessionController.rename({ sessionId, title: title.slice(0, 512) })
    // The connector follows this acknowledgement with a fresh authoritative
    // snapshot; a local cache must never outlive the native title projection.
    json(res, 202, { accepted: true, sessionId })
    return
  }

  const workspaceRenameMatch = /^\/workspaces\/([^/]+)\/rename$/.exec(path)
  if (req.method === 'POST' && workspaceRenameMatch !== null) {
    const workspaceId = decodeURIComponent(workspaceRenameMatch[1]!)
    const title = optionalStringOf(objectOf(await readJson(req)).title)?.trim()
    if (title === undefined || title.length === 0) throw new HttpError(400, 'workspace title is required')
    const registry = workspaceRegistryOf(ctx)
    const workspace = registry?.get?.(workspaceId)
    if (workspace === undefined || workspace.setTitle === undefined) {
      throw new HttpError(404, 'workspace not found')
    }
    await workspace.setTitle(title.slice(0, 512))
    json(res, 202, { accepted: true, workspaceId, title: title.slice(0, 512) })
    return
  }

  const workspaceDeleteMatch = /^\/workspaces\/([^/]+)\/delete$/.exec(path)
  if (req.method === 'POST' && workspaceDeleteMatch !== null) {
    const workspaceId = decodeURIComponent(workspaceDeleteMatch[1]!)
    const registry = workspaceRegistryOf(ctx)
    const workspace = registry?.get?.(workspaceId)
    if (workspace === undefined || registry?.delete === undefined) {
      throw new HttpError(404, 'workspace not found')
    }
    // Deleting a registration must not leave its sessions visible under a
    // phantom project on the next list refresh. Archive the member logs first,
    // then remove only the durable workspace record; the source directories and
    // session history remain untouched on disk.
    for (const sessionId of workspace.sessionIds) {
      await registry.archiveSession(sessionId)
      await metadata.setArchived(sessionId, true)
    }
    const deleted = await registry.delete(workspaceId)
    if (!deleted) throw new HttpError(404, 'workspace not found')
    json(res, 202, { accepted: true, workspaceId })
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
      throw new HttpError(400, 'Harness permission presets are read-only, workspace-write and danger-full-access')
    }
    // Harness persists a preset as sandbox mode plus approval policy. Calling
    // its native command keeps the actual sandbox aligned with the mobile UI.
    armSilentSetupWindow(sessionId)
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
    const requestId = header(req, 'x-dsh-request-id')
    if (requestId !== undefined && requestId.length > 256) {
      throw new HttpError(400, 'request id must be at most 256 characters')
    }
    const suppliedHash = header(req, 'x-dsh-request-hash')
    const fingerprint = suppliedHash !== undefined && /^[a-f0-9]{64}$/i.test(suppliedHash)
      ? suppliedHash.toLowerCase() : undefined
    const originDeviceId = device.id === CONNECTOR_DEVICE_ID
      ? (header(req, 'x-dsh-origin-device-id') ?? device.id) : device.id
    if (originDeviceId.length === 0 || originDeviceId.length > 256) {
      throw new HttpError(400, 'origin device id is invalid')
    }
    if (device.id === CONNECTOR_DEVICE_ID && originDeviceId !== CONNECTOR_DEVICE_ID &&
        !relayDevices.has(originDeviceId)) {
      throw new HttpError(403, 'origin device is not connected through Relay')
    }
    const body = objectOf(await readJson(req))
    const parsed = CommandExecutePayloadSchema.safeParse(body)
    if (!parsed.success) throw new HttpError(400, 'command line is required')
    const sessionId = decodeURIComponent(commandMatch[1]!)
    const durableKey = requestId === undefined || requestId.length === 0
      ? undefined : remoteMutationKeyFor(originDeviceId, path, requestId)
    if (durableKey !== undefined) {
      const remembered = metadata.remoteMutationEntry(durableKey, fingerprint)
      if (remembered?.response !== undefined && remembered.status !== undefined) {
        json(res, remembered.status, remembered.response)
        return
      }
      if (remembered?.pending === true) {
        throw new HttpError(503, 'remote mutation result is still unknown; reconcile before retrying', 'unknown')
      }
      await metadata.setRemoteMutationPending(durableKey, fingerprint)
    }
    let result: unknown
    try {
      result = await executeCommand(ctx, sessionId, parsed.data.line, parsed.data.attachments ?? [])
    } catch (error) {
      if (durableKey !== undefined && remoteMutationDefinitelyNotCommitted(error)) {
        try {
          await metadata.markRemoteMutationNotCommitted(durableKey, fingerprint)
        } catch (cleanupError) {
          throw new HttpError(503,
            cleanupError instanceof Error ? cleanupError.message : String(cleanupError), 'unknown')
        }
        throw new RetryableHttpError(
          error.status,
          error.message,
        )
      }
      throw error
    }
    if (durableKey !== undefined) await metadata.setRemoteMutationResult(durableKey, fingerprint, 202, result)
    json(res, 202, result)
    return
  }

  const uploadMatch = /^\/sessions\/([^/]+)\/attachments$/.exec(path)
  if (req.method === 'POST' && uploadMatch !== null) {
    // Base64 expands bytes by 4/3. Only this route receives the larger budget;
    // all ordinary control requests retain readJson's 1 MiB ceiling.
    const input = objectOf(await readJson(req, MAX_ATTACHMENT_BASE64_CHARS + 4_096))
    if (typeof input.data === 'string' && input.data.length > MAX_ATTACHMENT_BASE64_CHARS) {
      throw new HttpError(413, 'attachment is larger than 10 MiB')
    }
    const parsed = AttachmentUploadPayloadSchema.safeParse(input)
    if (!parsed.success) throw new HttpError(400, 'attachment name and base64 data are required')
    const body = parsed.data
    if (Buffer.byteLength(body.data, 'base64') > MAX_ATTACHMENT_BYTES) {
      throw new HttpError(413, 'attachment is larger than 10 MiB')
    }
    const sessionId = decodeURIComponent(uploadMatch[1]!)
    const requestId = header(req, 'x-dsh-request-id')
    if (requestId !== undefined && requestId.length > 256) {
      throw new HttpError(400, 'request id must be at most 256 characters')
    }
    const suppliedHash = header(req, 'x-dsh-request-hash')
    const fingerprint = suppliedHash !== undefined && /^[a-f0-9]{64}$/i.test(suppliedHash)
      ? suppliedHash.toLowerCase() : undefined
    const originDeviceId = device.id === CONNECTOR_DEVICE_ID
      ? (header(req, 'x-dsh-origin-device-id') ?? device.id) : device.id
    if (originDeviceId.length === 0 || originDeviceId.length > 256) {
      throw new HttpError(400, 'origin device id is invalid')
    }
    if (device.id === CONNECTOR_DEVICE_ID && originDeviceId !== CONNECTOR_DEVICE_ID &&
        !relayDevices.has(originDeviceId)) {
      throw new HttpError(403, 'origin device is not connected through Relay')
    }
    const durableKey = requestId === undefined || requestId.length === 0
      ? undefined : `${originDeviceId}\0${sessionId}\0${requestId}`
    const nativeOperationId = durableKey === undefined
      ? undefined : nativeOperationIdFor(`attachment\0${durableKey}`)
    if (durableKey !== undefined) {
      const expired = metadata.attachmentUploadExpiredEntry(durableKey, fingerprint)
      if (expired !== undefined) {
        // Replaying the original authenticated request is the executable
        // operator-reconciliation path for a tombstone. An expired marker is
        // no longer an automatic retry. Give an adapter
        // that supports reconciliation one explicit lookup opportunity; only
        // a receipt or authoritative non-commitment may release the permanent
        // tombstone.  Without that proof, keep failing closed so a late phone
        // retry cannot create a second native file.
        const findAttachmentByRequestId = ctx.sessionController.findAttachmentByRequestId
        if (findAttachmentByRequestId === undefined || expired.nativeOperationId === undefined) {
          throw new HttpError(409, 'attachment upload recovery expired; reconcile the native operation before retrying')
        }
        let recovery: AttachmentUploadRecoveryResult
        try {
          recovery = attachmentUploadRecoveryResultOf(await findAttachmentByRequestId(
            expired.nativeOperationId, AbortSignal.timeout(15_000)))
        } catch {
          recovery = { state: 'unknown' }
        }
        if (recovery.state === 'found') {
          const response = attachmentUploadResponseOf(recovery.response, body.name)
          if (response === undefined) {
            throw new HttpError(409, 'attachment upload recovery returned no receipt; operator reconciliation required')
          }
          await metadata.setAttachmentUploadResult(
            durableKey, fingerprint, response, expired.nativeOperationId)
          json(res, 200, response)
          return
        }
        if (recovery.state === 'not-committed') {
          await metadata.markAttachmentUploadNotCommitted(durableKey, fingerprint)
        } else {
          throw new HttpError(409, 'attachment upload recovery expired; native operation is still unknown')
        }
      }
      const pending = metadata.attachmentUploadPendingEntry(durableKey, fingerprint)
      if (pending !== undefined) {
        // A Bridge restart can happen after the native file service committed
        // its staged receipt but before this metadata file recorded the
        // response. Adapters that persist the stable operation id can return
        // that original receipt here. If the adapter cannot reconcile it, the
        // pending marker remains fail-closed: issuing a second upload would
        // create an orphaned file and violate at-most-once semantics.
        const findAttachmentByRequestId = ctx.sessionController.findAttachmentByRequestId
        if (findAttachmentByRequestId !== undefined && pending.nativeOperationId !== undefined) {
          try {
            const recovered = await findAttachmentByRequestId(
              pending.nativeOperationId, AbortSignal.timeout(15_000))
            const recovery = attachmentUploadRecoveryResultOf(recovered)
            if (recovery.state === 'found') {
              const response = attachmentUploadResponseOf(recovery.response, body.name)
              if (response === undefined) throw new Error('attachment recovery returned no receipt')
              await metadata.setAttachmentUploadResult(
                durableKey, fingerprint, response, pending.nativeOperationId)
              json(res, 200, response)
              return
            }
            if (recovery.state === 'not-committed') {
              // The adapter has authoritative knowledge that the operation
              // never crossed the native upload boundary. Release the marker
              // and continue through the ordinary upload path below.
              await metadata.markAttachmentUploadNotCommitted(durableKey, fingerprint)
            } else {
              throw new HttpError(503, 'attachment upload result is still unknown', 'retryable-durable')
            }
          } catch {
            // Recovery is best effort. Keep the durable pending marker and
            // report an unknown result below; never fall back to a duplicate
            // native upload after an ambiguous adapter failure.
            throw new HttpError(503, 'attachment upload result is still unknown', 'retryable-durable')
          }
        } else {
          throw new HttpError(503, 'attachment upload result is still unknown', 'retryable-durable')
        }
      }
      const remembered = metadata.attachmentUploadEntry(durableKey, fingerprint)
      if (remembered !== undefined) {
        json(res, 201, remembered)
        return
      }
      // Commit a fail-closed marker before invoking the native file service.
      // If the response is lost after the upload side effect, a later retry
      // will see the pending marker instead of uploading a second file.
      await metadata.setAttachmentUploadPending(durableKey, fingerprint, nativeOperationId, body.name)
    }
    let result: Record<string, unknown>
    try {
      result = await uploadAttachment(ctx, sessionId, body.data, body.name, nativeOperationId)
    } catch (error) {
      // A native client error is a proof that no file side effect was
      // accepted. The local 501 capability error is also deterministic: the
      // upload service was never invoked. Release the durable marker and
      // allow a same-id retry; keep other 5xx/unknown failures pending because
      // the file service may have committed before its response was lost.
      if (durableKey !== undefined && error instanceof HttpError &&
          (error.status < 500 || error.status === 501)) {
        await metadata.markAttachmentUploadNotCommitted(durableKey, fingerprint)
        throw new HttpError(error.status, error.message, 'retryable')
      }
      throw error
    }
    if (durableKey !== undefined) {
      await metadata.setAttachmentUploadResult(durableKey, fingerprint, result, nativeOperationId)
    }
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
  deviceId?: string,
  projectCreationCorrelation = true,
): Promise<ReturnType<typeof normalizeSessionSummary>[]> {
  const result = await ctx.sessionController.list({}, AbortSignal.timeout(15_000))
  const summaries = (await Promise.all(result.items.map(async (item) => {
      const summary = normalizeSessionSummary(item, ctx, metadata)
      if (!projectCreationCorrelation || deviceId === undefined) return summary
      const correlation = await metadata.sessionCreationCorrelationForSession(
        deviceId, summary.id, summary.createRequestId)
      if (correlation.suppressNativeOperationId) {
        const { createRequestId: _internalOperationId, ...withoutCorrelation } = summary
        return withoutCorrelation
      }
      const createRequestId = correlation.requestId ?? summary.createRequestId
      return createRequestId === undefined ? summary : { ...summary, createRequestId }
    })))
    // A subagent session is how the agent delegates its own work, not a
    // conversation the user started. Listing them buried the real ones: 18 of
    // 40 rows were subagents in practice, each titled with its task prompt.
    .filter((item) => !isSubagentSession(item))
  return includeArchived ? summaries : summaries.filter((item) => item.archived !== true)
}

/**
 * Inspect one durable Harness session and publish its history as ordinary
 * transcript events bracketed by `history.started` / `history.completed`
 * carrying one batch id. The Connector receives these on the same bridge
 * socket as live output, so iOS does not need a second history transport or
 * a local copy of the Harness storage format; the brackets let it replace
 * the session transcript atomically instead of interleaving the replay with
 * (and renumbering) live output.
 */
export function historyRecipient(authenticatedDeviceId: string, requestedDeviceId: unknown): string {
  // Only the trusted local Connector may route a request on behalf of a
  // paired phone. A direct bridge client cannot target another device.
  return authenticatedDeviceId === CONNECTOR_DEVICE_ID
    && typeof requestedDeviceId === 'string' && requestedDeviceId.length > 0
    && requestedDeviceId.length <= 256
    ? requestedDeviceId : authenticatedDeviceId
}

async function publishSessionHistory(
  ctx: NativeContext,
  session: ReturnType<typeof normalizeSessionSummary>,
  deviceId: string,
  publish: (event: NativeEventInput, recipients?: Iterable<WebSocket>) => void,
  recipients?: Iterable<WebSocket>,
): Promise<number> {
  const inspection = await ctx.sessionController.inspect(session.id, AbortSignal.timeout(60_000))
  const allEvents = inspection.events
  const recentCount = Math.min(HISTORY_EVENT_LIMIT, allEvents.length)
  const recentStart = Math.max(0, allEvents.length - recentCount)
  const historyToolNames = new Map<string, string>()
  const historyUsageCounters = new Map<string, UsageCounter>()
  const historyModelSelections = new Map<string, ModelSelectionProjection>()
  const batchId = randomUUID()
  let published = 0
  let publishedUsage = false

  publish({ deviceId, sessionId: session.id, type: 'history.started',
    historyBatchId: batchId,
    payload: { sessionId: session.id, batchId } }, recipients)
  for (let index = 0; index < allEvents.length; index += 1) {
    const normalized = normalizeSessionEvents(
      session.id,
      allEvents[index],
      historyToolNames,
      historyUsageCounters,
      historyModelSelections,
    )
    if (index < recentStart) continue
    for (const next of normalized) {
      if (next.type === 'usage.updated') publishedUsage = true
      publish({ ...next, deviceId, historyBatchId: batchId }, recipients)
      published += 1
    }
  }

  // If the recent window did not contain a usage event, send the complete
  // session aggregate so the footer remains correct after opening an old log.
  // It travels inside the brackets so the atomic replace keeps it.
  const completeUsage = historyUsageCounters.get(session.id)
  if (!publishedUsage && completeUsage !== undefined && hasUsage(completeUsage)) {
    publish({
      deviceId,
      sessionId: session.id,
      type: 'usage.updated',
      historyBatchId: batchId,
      payload: {
        sessionId: session.id,
        usage: { ...usageSnapshot(completeUsage), rounds: completeUsage.rounds, steps: completeUsage.steps },
      },
    }, recipients)
    published += 1
  }
  publish({ deviceId, sessionId: session.id, type: 'history.completed',
    historyBatchId: batchId,
    payload: { sessionId: session.id, batchId } }, recipients)
  return published
}

/**
 * Subagent sessions link back to the session that spawned them. `origin` is the
 * explicit marker; the parent link is the fallback for builds that set only it.
 */
export function isSubagentSession(item: { origin?: string; parentSessionId?: string }): boolean {
  return item.origin === 'subagent' || item.parentSessionId !== undefined
}

function isSessionTitleEvent(value: unknown): boolean {
  return recordOf(value).type === 'session/title'
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
  nativeOperationId?: string,
): Promise<Record<string, unknown>> {
  if (ctx.typertGateway === undefined) throw new HttpError(501, 'Harness file upload service is unavailable')
  const result = await ctx.typertGateway.invoke({
    namespace: 'fileUploads',
    method: 'upload',
    args: {
      agentId: sessionId,
      request: {
        data,
        name,
        // The current generated file-upload contract ignores unknown request
        // fields, while adapters that support recovery can persist this
        // operation id next to the staged receipt. Keeping it stable across
        // Bridge restarts is what makes findAttachmentByRequestId useful.
        ...(nativeOperationId === undefined ? {} : { requestId: nativeOperationId }),
      },
    },
    signal: AbortSignal.timeout(120_000),
  })
  const response = attachmentUploadResponseOf(result, name)
  if (response === undefined) throw new HttpError(502, 'Harness file upload returned no receipt')
  return response
}

function attachmentUploadResponseOf(value: unknown, name: string): Record<string, unknown> | undefined {
  const result = recordOf(value)
  const nested = recordOf(result.value)
  const receiptId = typeof result.receiptId === 'string' ? result.receiptId : stringOr(nested.receiptId, '')
  if (receiptId.length === 0) return undefined
  const file = recordOf(result.file ?? nested.file)
  return {
    receiptId,
    name,
    ...(typeof file.mediaType === 'string' ? { mediaType: file.mediaType } : {}),
    ...(typeof file.size === 'number' ? { size: file.size } : {}),
  }
}

function attachmentUploadRecoveryResultOf(value: unknown): AttachmentUploadRecoveryResult {
  if (value === undefined) return { state: 'unknown' }
  const record = recordOf(value)
  const state = typeof record.state === 'string'
    ? record.state
    : typeof record.status === 'string' ? record.status : undefined
  if (state === 'not-committed' || state === 'definitelyNotCommitted') {
    return { state: 'not-committed' }
  }
  if (state === 'unknown') return { state: 'unknown' }
  if (state === 'found') {
    return {
      state: 'found',
      response: record.response ?? record.value,
    }
  }
  // Older adapters returned the receipt object directly. Preserve that
  // contract as a successful lookup while allowing new adapters to return an
  // explicit three-state result.
  return { state: 'found', response: value }
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

/** Typert wraps the native return value in `{ ok, value }`; direct local
 * adapters sometimes return the value itself, so accept both shapes. */
function remoteValueOf(value: unknown): JsonObject {
  const remote = recordOf(value)
  const nested = recordOf(remote.value)
  return Object.keys(nested).length > 0 ? nested : remote
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
  agentPreset?: string
  mode?: string
  branch?: string
  provider?: string
  model?: string
  reasoningEffort?: string
  permissionMode?: PermissionMode
  createRequestId?: string
} {
  const item = recordOf(value)
  const id = typeof item.sessionId === 'string'
    ? item.sessionId
    : typeof item.id === 'string' ? item.id : 'unknown'
  const cwd = typeof item.cwd === 'string' ? item.cwd : undefined
  // A title projection is written by the Harness auto-title service and by
  // native/web renames. It must always beat our legacy metadata fallback so
  // a mobile rename cannot permanently shadow a later native change.
  const explicitTitle = sessionTitleOf(item) ?? metadata?.title(id)
  const workspace = workspaceFor(ctx, id, cwd)
  const selection = selectionFor(item)
  const permissionMode = metadata?.permission(id)
  const archived = item.archived === true || metadata?.isArchived(id, workspaceRegistryOf(ctx))
  const branch = metadata?.branch(id) ?? (typeof item.branch === 'string' ? item.branch : undefined)
  const createRequestId = typeof item.createRequestId === 'string'
    ? item.createRequestId
    : typeof item.creationRequestId === 'string'
      ? item.creationRequestId
      : typeof item.requestId === 'string' ? item.requestId : undefined
  return {
    id,
    title: explicitTitle ?? (item.blank === true ? '新会话' : (cwd === undefined ? `Session ${id.slice(0, 8)}` : basename(cwd))),
    updatedAt: typeof item.updatedAt === 'number' ? item.updatedAt : Date.now(),
    ...(cwd === undefined ? {} : { cwd }),
    ...(workspace === undefined ? {} : workspace),
    ...(archived ? { archived: true } : {}),
    ...(typeof item.running === 'boolean' ? { running: item.running } : {}),
    ...(typeof item.blank === 'boolean' ? { blank: item.blank } : {}),
    ...(typeof item.parentSessionId === 'string' ? { parentSessionId: item.parentSessionId } : {}),
    ...(typeof item.agentPreset === 'string' ? { agentPreset: item.agentPreset } : {}),
    ...(typeof item.mode === 'string' ? { mode: item.mode } : {}),
    ...(branch === undefined ? {} : { branch }),
    ...(item.origin === 'subagent' ? { origin: 'subagent' as const } : {}),
    ...(selection === undefined ? {} : selection),
    ...(permissionMode === undefined ? {} : { permissionMode }),
    ...(createRequestId === undefined ? {} : { createRequestId }),
  }
}

function normalizeLiveSession(value: unknown, ctx?: NativeContext, metadata?: SessionMetadataStore): ReturnType<typeof normalizeSessionSummary> {
  const session = recordOf(value)
  const header = recordOf(session.header)
  // Carry the spawn link through so a freshly delegated subagent can be told
  // apart from a session the user just started.
  const parentSessionId = typeof session.parentSessionId === 'string'
    ? session.parentSessionId
    : typeof header.parentSessionId === 'string' ? header.parentSessionId : undefined
  const agentPreset = typeof session.agentPreset === 'string'
    ? session.agentPreset
    : typeof header.agentPreset === 'string' ? header.agentPreset : undefined
  const mode = typeof session.mode === 'string'
    ? session.mode
    : typeof header.mode === 'string' ? header.mode : undefined
  const branch = typeof session.branch === 'string'
    ? session.branch
    : typeof header.branch === 'string' ? header.branch : undefined
  return normalizeSessionSummary({
    sessionId: typeof session.id === 'string' ? session.id : 'unknown',
    cwd: header.cwd,
    updatedAt: Date.now(),
    ...(parentSessionId === undefined ? {} : { parentSessionId }),
    ...(agentPreset === undefined ? {} : { agentPreset }),
    ...(mode === undefined ? {} : { mode }),
    ...(branch === undefined ? {} : { branch }),
    ...(session.origin === 'subagent' ? { origin: 'subagent' } : {}),
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
  // A session outside every registered workspace gets no workspace identity.
  // Synthesising `cwd:<path>` used to make the phone present one phantom
  // workspace per directory (29 of 36 sessions in practice), so its list never
  // matched the Harness sidebar, which only lists registered workspaces.
  return undefined
}

function workspaceProjection(workspace: { id: string; path: string; title: string }): { id: string; path: string; title: string } {
  return { id: workspace.id, path: workspace.path, title: workspace.title }
}

/** The registry includes empty workspaces; session rows cannot reconstruct it. */
export function workspaceCatalog(ctx: Pick<NativeContext, 'workspaceRegistry'>): { id: string; path: string; title: string }[] {
  return workspaceRegistryOf(ctx)?.list().map(workspaceProjection) ?? []
}

export function modeCatalogFromRemote(result: unknown): {
  defaultMode?: string
  modes: { id: string; name: string; description?: string }[]
} {
  const remote = remoteValueOf(result)
  const presets: unknown[] = Array.isArray(remote.presets) ? remote.presets : []
  const modes = presets.map((preset) => recordOf(preset))
    .filter((preset) => typeof preset.id === 'string' && typeof preset.broken !== 'string')
    .map((preset) => ({
      id: preset.id as string,
      name: typeof preset.name === 'string' && preset.name.trim().length > 0 ? preset.name : preset.id as string,
      ...(typeof preset.description === 'string' && preset.description.trim().length > 0 ? { description: preset.description } : {}),
      ...(preset.isDefault === true ? { isDefault: true } : {}),
    }))
  const defaultMode = modes.find((mode) => mode.isDefault === true)?.id
  return { ...(defaultMode === undefined ? {} : { defaultMode }), modes: modes.map(({ isDefault: _isDefault, ...mode }) => mode) }
}

function directoryPickerOf(ctx: NativeContext): NonNullable<NativeContext['directoryPicker']> | undefined {
  try {
    return ctx.directoryPicker
  } catch {
    return undefined
  }
}

/**
 * One-level directory browser used only while Harness selected its native OS
 * chooser.  It intentionally mirrors the browse capability's scope: the
 * paired device receives directory names and absolute paths only, never file
 * names or file contents.  Calls are still protected by the connector token
 * at the HTTP route above.
 */
async function listDirectoriesForPairedDevice(path: string | undefined, signal: AbortSignal): Promise<{
  path: string
  entries: { name: string; path: string }[]
}> {
  if (path !== undefined && !isAbsolute(path)) {
    throw new Error(`cannot list "${path}": not an absolute path`)
  }
  signal.throwIfAborted()
  const directoryPath = resolve(path ?? homedir())
  const directory = await opendir(directoryPath)
  const entries: { name: string; path: string }[] = []
  try {
    for await (const entry of directory) {
      signal.throwIfAborted()
      const entryPath = join(directoryPath, entry.name)
      if (entry.isDirectory()) {
        insertBoundedDirectory(entries, { name: entry.name, path: entryPath })
        continue
      }
      // `Dirent#isDirectory` does not follow symbolic links.  The native
      // Harness browser does, so preserve enterable linked folders too.
      if (entry.isSymbolicLink()) {
        try {
          if ((await stat(entryPath)).isDirectory()) insertBoundedDirectory(entries, { name: entry.name, path: entryPath })
        } catch {
          // A broken or unreadable link is not enterable; omit it like the
          // native browse capability does.
        }
      }
    }
  } finally {
    await directory.close().catch(() => undefined)
  }
  return { path: directoryPath, entries }
}

/** Match Harness's browse backend: sorted, bounded to one thousand folders. */
function insertBoundedDirectory(entries: { name: string; path: string }[], entry: { name: string; path: string }): void {
  const maximumEntries = 1_000
  if (entries.length === maximumEntries && entry.name.localeCompare(entries[entries.length - 1]!.name) >= 0) return
  let lower = 0
  let upper = entries.length
  while (lower < upper) {
    const middle = (lower + upper) >>> 1
    if (entry.name.localeCompare(entries[middle]!.name) < 0) upper = middle
    else lower = middle + 1
  }
  entries.splice(lower, 0, entry)
  if (entries.length > maximumEntries) entries.pop()
}

/**
 * Cordis optional injections are exposed as throwing getters. Optional
 * chaining cannot catch that getter failure, so a profile without the
 * workspace service previously turned a valid GET /sessions into HTTP 500.
 */
function workspaceRegistryOf(ctx: Pick<NativeContext, 'workspaceRegistry'> | undefined): NonNullable<NativeContext['workspaceRegistry']> | undefined {
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

type ModelSelectionProjection = {
  provider: string
  model: string
  reasoningEffort?: string
}

/**
 * Usage shown in the footer is session-wide, while assistant/message usage is
 * one turn. Keep the accumulator separate from the wire payload so the phone
 * can show both without mistaking the latest turn for the whole conversation.
 */
type UsageCounter = {
  rounds: number
  steps: number
  contextWindow?: number
  contextUsed?: number
  inputTokens: number
  outputTokens: number
  totalTokens: number
  cacheReadTokens: number
  cacheWriteTokens: number
  hasInputTokens: boolean
  hasOutputTokens: boolean
  hasTotalTokens: boolean
  hasCacheReadTokens: boolean
  hasCacheWriteTokens: boolean
  seenMessageIds: Set<string>
  tokensPerSecond?: number
}

function newUsageCounter(): UsageCounter {
  return {
    rounds: 0,
    steps: 0,
    inputTokens: 0,
    outputTokens: 0,
    totalTokens: 0,
    cacheReadTokens: 0,
    cacheWriteTokens: 0,
    hasInputTokens: false,
    hasOutputTokens: false,
    hasTotalTokens: false,
    hasCacheReadTokens: false,
    hasCacheWriteTokens: false,
    seenMessageIds: new Set<string>(),
  }
}

function usageCounterFor(map: Map<string, UsageCounter>, sessionId: string): UsageCounter {
  const existing = map.get(sessionId)
  if (existing !== undefined) return existing
  const created = newUsageCounter()
  map.set(sessionId, created)
  return created
}

function aggregateUsage(counter: UsageCounter, usage: Record<string, number>, messageId: string): Record<string, number> {
  // A reconnect can replay the same durable assistant event. Do not charge its
  // tokens twice in the session footer, although the latest throughput/context
  // hints are still refreshed below.
  if (!counter.seenMessageIds.has(messageId)) {
    counter.seenMessageIds.add(messageId)
    if (typeof usage.inputTokens === 'number') {
      counter.inputTokens += usage.inputTokens
      counter.hasInputTokens = true
    }
    if (typeof usage.outputTokens === 'number') {
      counter.outputTokens += usage.outputTokens
      counter.hasOutputTokens = true
    }
    if (typeof usage.totalTokens === 'number') {
      counter.totalTokens += usage.totalTokens
      counter.hasTotalTokens = true
    }
    if (typeof usage.cacheReadTokens === 'number') {
      counter.cacheReadTokens += usage.cacheReadTokens
      counter.hasCacheReadTokens = true
    }
    if (typeof usage.cacheWriteTokens === 'number') {
      counter.cacheWriteTokens += usage.cacheWriteTokens
      counter.hasCacheWriteTokens = true
    }
  }
  if (typeof usage.contextWindow === 'number') counter.contextWindow = usage.contextWindow
  if (typeof usage.contextUsed === 'number') counter.contextUsed = usage.contextUsed
  if (typeof usage.tokensPerSecond === 'number') counter.tokensPerSecond = usage.tokensPerSecond

  return usageSnapshot(counter)
}

function hasUsage(counter: UsageCounter): boolean {
  return counter.hasInputTokens || counter.hasOutputTokens || counter.hasTotalTokens
    || counter.hasCacheReadTokens || counter.hasCacheWriteTokens
}

function usageSnapshot(counter: UsageCounter): Record<string, number> {
  const result: Record<string, number> = {}
  if (counter.hasInputTokens) result.inputTokens = counter.inputTokens
  if (counter.hasOutputTokens) result.outputTokens = counter.outputTokens
  if (counter.hasTotalTokens) {
    result.totalTokens = counter.totalTokens
  } else if (counter.hasInputTokens || counter.hasOutputTokens) {
    // Some adapters omit totalTokens. The sum still gives the user a useful,
    // deterministic whole-session number instead of a blank footer.
    result.totalTokens = counter.inputTokens + counter.outputTokens
  }
  if (counter.hasCacheReadTokens) result.cacheReadTokens = counter.cacheReadTokens
  if (counter.hasCacheWriteTokens) result.cacheWriteTokens = counter.cacheWriteTokens
  if (counter.hasInputTokens && counter.hasCacheReadTokens && counter.inputTokens + counter.cacheReadTokens > 0) {
    result.cacheHitPercent = counter.cacheReadTokens / (counter.inputTokens + counter.cacheReadTokens) * 100
  }
  if (counter.contextWindow !== undefined) result.contextWindow = counter.contextWindow
  if (counter.contextUsed !== undefined) result.contextUsed = counter.contextUsed
  if (counter.tokensPerSecond !== undefined) result.tokensPerSecond = counter.tokensPerSecond
  return result
}

function modelSelectionProjection(data: JsonObject): ModelSelectionProjection | undefined {
  const provider = typeof data.provider === 'string' ? data.provider : undefined
  const model = typeof data.model === 'string' ? data.model : undefined
  if (provider === undefined || model === undefined) return undefined
  const reasoningEffort = typeof data.reasoningEffort === 'string' ? data.reasoningEffort : undefined
  return { provider, model, ...(reasoningEffort === undefined ? {} : { reasoningEffort }) }
}

function sameModelSelection(left: ModelSelectionProjection, right: ModelSelectionProjection): boolean {
  return left.provider === right.provider
    && left.model === right.model
    && left.reasoningEffort === right.reasoningEffort
}

/** A bridge-local, bounded identifier for the transient output of one durable
 * assistant turn/step. The same turn/step appears on the final session event;
 * unlike the Harness attempt id, it survives the boundary where the durable
 * message UUID is minted. */
function liveStreamKey(sessionId: string, turn: unknown, step: unknown): string | undefined {
  if (typeof turn !== 'number' || typeof step !== 'number'
      || !Number.isSafeInteger(turn) || !Number.isSafeInteger(step) || turn < 0 || step < 0) return undefined
  return `${sessionId}\u0000${turn}\u0000${step}`
}

function liveStreamMessageID(key: string): string {
  return `stream-${createHash('sha256').update(key).digest('hex')}`
}

/** The mobile live-trail renders the tail of this snapshot. Keeping it small
 * prevents a long reasoning turn from repeatedly shipping its entire trace;
 * the full reasoning remains in the canonical durable assistant event. */
export const LIVE_REASONING_TRAIL_LIMIT = 4_096

export function liveReasoningTrail(previous: string, chunk: string): string {
  return `${previous}${chunk}`.slice(-LIVE_REASONING_TRAIL_LIMIT)
}

/**
 * Project one real Harness stream chunk onto the existing phone events. This
 * is deliberately limited to visible answer text and the bounded reasoning
 * trail: block markers and tool-call deltas have no useful composer status.
 */
export function liveStreamChunkEvent(attempt: LiveStreamAttempt, value: unknown): NativeEventInput | undefined {
  const chunk = recordOf(value)
  if (chunk.type === 'text-delta' && typeof chunk.text === 'string' && chunk.text.length > 0) {
    return {
      sessionId: attempt.sessionId,
      type: 'assistant.message.delta',
      payload: { messageId: attempt.messageId, text: chunk.text },
    }
  }
  if (chunk.type === 'reasoning-delta' && typeof chunk.text === 'string' && chunk.text.length > 0) {
    attempt.reasoningTrail = liveReasoningTrail(attempt.reasoningTrail, chunk.text)
    // `assistant.reasoning` already has a compatible phone decoder. Use the
    // temporary stream id so this live row is replaced atomically by the
    // durable message (or discarded for a non-committing attempt).
    return {
      sessionId: attempt.sessionId,
      type: 'assistant.reasoning',
      payload: { messageId: attempt.messageId, text: attempt.reasoningTrail },
    }
  }
  return undefined
}

export function normalizeSessionEvents(
  sessionId: string,
  value: unknown,
  toolNames: Map<string, string>,
  usageCounters = new Map<string, UsageCounter>(),
  modelSelections = new Map<string, ModelSelectionProjection>(),
  liveStreamMessageIDs?: ReadonlyMap<string, string>,
): NativeEventInput[] {
  const event = recordOf(value)
  const type = typeof event.type === 'string' ? event.type : ''
  const data = recordOf(event.data)

  if (type === 'user/message') {
    const source = recordOf(data.source)
    if (source.kind !== 'user') return []
    const attachments = contentAttachments(data.content)
    const requestId = typeof data.requestId === 'string' && data.requestId.length > 0
      ? data.requestId : undefined
    return [{
      type: 'user.message.accepted',
      sessionId,
      ...(requestId === undefined ? {} : { messageId: requestId }),
      payload: {
        id: stringOr(data.id, randomUUID()),
        role: 'user',
        markdown: contentText(data.content),
        ...(attachments.length === 0 ? {} : { attachments }),
      },
    }]
  }
  if (type === 'assistant/message') {
    const message = recordOf(data.message)
    const counters = usageCounterFor(usageCounters, sessionId)
    const usage = normalizeUsage(data.usage, counters.contextWindow)
    const tokensPerSecond = outputRate(data.stream, usage?.outputTokens)
    if (usage !== undefined && tokensPerSecond !== undefined) usage.tokensPerSecond = tokensPerSecond
    const source = recordOf(message.source)
    const messageId = stringOr(message.id, randomUUID())
    const streamKey = liveStreamKey(sessionId, data.turn, data.step)
    const replacesMessageId = streamKey === undefined ? undefined : liveStreamMessageIDs?.get(streamKey)
    const sessionUsage = usage === undefined ? undefined : aggregateUsage(counters, usage, messageId)
    // Assistant-side images (model-returned or read back) travel the same
    // attachment path as user uploads, thumbnails included.
    const attachments = contentAttachments(message.content)
    const normalized: NativeEventInput[] = [{
      type: 'assistant.message.completed',
      sessionId,
      payload: {
        id: messageId,
        role: 'assistant',
        markdown: contentText(message.content),
        ...(attachments.length === 0 ? {} : { attachments }),
        ...(usage === undefined ? {} : { usage }),
        ...(typeof source.provider === 'string' ? { provider: source.provider } : {}),
        ...(typeof source.model === 'string' ? { model: source.model } : {}),
        ...(replacesMessageId === undefined ? {} : { replacesMessageId }),
      },
    }]
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
        payload: {
          sessionId,
          usage: { ...sessionUsage, rounds: counters.rounds, steps: counters.steps },
        },
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
  // Commands the app issues as control actions — permission and model changes —
  // are state changes, not conversation. Their effect is already broadcast as
  // `permission.updated` / the model selection, so publishing them here left a
  // permanent "Permission preset: …" card at the bottom of the session that
  // never went away.
  if (COMMAND_RESULT_SUPPRESSED.has(stringOr(data.name, ''))) return []
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
    const doneName = stringOr(data.name, '')
    const doneId = stringOr(data.commandId, '')
    const knownName = toolNames.get(doneId) ?? doneName
    if (COMMAND_RESULT_SUPPRESSED.has(doneName) || COMMAND_RESULT_SUPPRESSED.has(knownName)) {
      // Still forget the name so the map cannot grow.
      toolNames.delete(doneId)
      return []
    }

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
    const counters = usageCounterFor(usageCounters, sessionId)
    counters.rounds += 1
    return [{ type: 'turn.state.changed', sessionId, payload: { sessionId, state: 'running' } }]
  }
  if (type === 'turn/end') {
    const reason = stringOr(data.reason, 'completed')
    return [{ type: 'turn.state.changed', sessionId, payload: { sessionId, state: reason } }]
  }
  if (type === 'step/start') {
    const counters = usageCounterFor(usageCounters, sessionId)
    counters.steps += 1
    return []
  }
  if (type === 'request/context') {
    const contextWindow = typeof data.contextWindow === 'number' ? data.contextWindow : undefined
    if (contextWindow !== undefined) {
      usageCounterFor(usageCounters, sessionId).contextWindow = contextWindow
    }
    const selection = modelSelectionProjection(data)
    if (selection !== undefined) modelSelections.set(sessionId, selection)
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
    const selection = modelSelectionProjection(config)
    if (selection !== undefined) modelSelections.set(sessionId, selection)
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
    const current = modelSelectionProjection(data)
    if (current === undefined) return []
    const previous = modelSelections.get(sessionId)
    modelSelections.set(sessionId, current)
    const normalized: NativeEventInput[] = []
    if (previous !== undefined && !sameModelSelection(previous, current)) {
      normalized.push({
        type: 'session.model.changed',
        sessionId,
        payload: {
          sessionId,
          previous,
          current,
        },
      })
    }
    normalized.push({
      type: 'session.metadata.updated',
      sessionId,
      payload: {
        sessionId,
        provider: current.provider,
        model: current.model,
        ...(current.reasoningEffort === undefined ? {} : { reasoningEffort: current.reasoningEffort }),
      },
    })
    return normalized
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
  if (type === 'permission/preset' && isPermissionMode(preset) && isPermissionPreset(preset)) {
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

/**
 * Keep message attachment events lightweight, but complete: phone uploads
 * resolve locally by receiptId, while anything else (web uploads, Mac-side
 * files, model-returned images) carries an embedded thumbnail, because the
 * phone has no byte path to those. Thumbnails are read synchronously from
 * the Harness attachment store and capped small; anything unreadable or
 * oversized degrades to a name-only row rather than failing the message.
 */
const ATTACHMENT_THUMBNAIL_MAX_BYTES = 256 * 1024

/** Resolve `sha256:<hex>` content references to bytes in DSH_HOME. */
function attachmentObjectPath(attachmentId: string): string | undefined {
  const hex = attachmentId.startsWith('sha256:') ? attachmentId.slice('sha256:'.length) : attachmentId
  if (!/^[0-9a-f]{16,128}$/i.test(hex)) return undefined
  const home = process.env.DSH_HOME ?? join(homedir(), '.dsh')
  return join(home, 'attachments', 'v1', 'objects', hex.slice(0, 2).toLowerCase(), hex.toLowerCase())
}

function attachmentThumbnail(attachmentId: string, mediaType: string): string | undefined {
  try {
    const path = attachmentObjectPath(attachmentId)
    if (path === undefined) return undefined
    if (!mediaType.toLowerCase().startsWith('image/')) return undefined
    if (statSync(path).size > ATTACHMENT_THUMBNAIL_MAX_BYTES) return undefined
    return `data:${mediaType};base64,${readFileSync(path).toString('base64')}`
  } catch {
    return undefined
  }
}

function contentAttachments(value: unknown): Array<{
  id: string
  name: string
  mediaType?: string | undefined
  receiptId?: string | undefined
  thumbnail?: string | undefined
}> {
  if (!Array.isArray(value)) return []
  return value.flatMap((entry) => {
    const block = recordOf(entry)
    if (block.type === 'file' && typeof block.receiptId === 'string') {
      const receiptId = block.receiptId
      const parsed = ChatAttachmentSchema.safeParse({
        id: receiptId,
        receiptId,
        name: stringOr(block.name, 'Attachment'),
        ...(typeof block.mediaType === 'string' ? { mediaType: block.mediaType } : {}),
      })
      return parsed.success ? [parsed.data] : []
    }
    if (block.type === 'image') {
      // Prefer the durable content reference as a stable id (a random id
      // duplicates the row on every replay) and embed a thumbnail: without
      // either, the phone renders a permanent empty slot it can never fill.
      const attachment = recordOf(block.attachment)
      const attachmentId = typeof attachment.attachmentId === 'string' ? attachment.attachmentId : undefined
      const mediaType = typeof attachment.mediaType === 'string'
        ? attachment.mediaType
        : stringOr(block.mediaType, 'image/jpeg')
      const id = attachmentId ?? stringOr(block.id, `image-${randomUUID()}`)
      const thumbnail = attachmentId === undefined
        ? undefined
        : attachmentThumbnail(attachmentId, mediaType)
      const parsed = ChatAttachmentSchema.safeParse({
        id,
        name: stringOr(attachment.name, stringOr(block.name, 'Image')),
        mediaType,
        ...(thumbnail === undefined ? {} : { thumbnail }),
      })
      return parsed.success ? [parsed.data] : []
    }
    return []
  })
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

function recordOf(value: unknown): Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
    ? value as Record<string, unknown>
    : {}
}

function stringOr(value: unknown, fallback: string): string {
  return typeof value === 'string' ? value : fallback
}

export default { name, inject, apply }
