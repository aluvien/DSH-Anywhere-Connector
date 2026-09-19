import { createHash, randomUUID } from "node:crypto";
import {
  CommandEnvelopeSchema,
  AttachmentUploadedPayloadSchema,
  CommandResultPayloadSchema,
  EventEnvelopeSchema,
  ModelCatalogPayloadSchema,
  ModeCatalogPayloadSchema,
  PromptAcceptedPayloadSchema,
  PROTOCOL_VERSION,
  RelayMessageSchema,
  RelayPayloadMessageSchema,
  SessionSummarySchema,
  WorkspaceCatalogPayloadSchema,
  WorkspaceSchema,
  DirectoryListPayloadSchema,
  type CommandEnvelope,
  type EventEnvelope,
  type SessionSummary,
} from "@dsh-anywhere/protocol";
import WebSocket, { type RawData } from "ws";
import { redactSecrets, type ConnectorConfig } from "./config.js";
import { requestPairingCode, writePairingCodeFile } from "./setup.js";

const MAX_REPLAY_EVENTS = 2_000;
const MAX_REPLAY_BYTES = 8 * 1024 * 1024;
const MAX_PENDING_EVENTS = 1_000;
const MAX_PENDING_BYTES = 8 * 1024 * 1024;
const MAX_RELAY_BUFFERED_BYTES = 32 * 1024 * 1024;
const COMMAND_DEDUP_TTL_MS = 10 * 60_000;
const MAX_COMMAND_RESULT_ENTRIES = 2_000;
const LONG_BRIDGE_TIMEOUT_MS = 125_000;
const UNSOLICITED_SESSION_SNAPSHOT_PREFIX = "snapshot-push-";
/** Comfortably inside the relay's 10-minute code lifetime. */
const PAIRING_CODE_REFRESH_MS = 5 * 60_000;

type CommandExecutionOutcome =
  | { readonly state: "completed" }
  | { readonly state: "failed"; readonly retryable: boolean };

export interface Logger {
  info(message: string): void;
  warn(message: string): void;
}

export interface WebSocketLike {
  readonly readyState: number;
  readonly bufferedAmount?: number;
  send(data: string): void;
  close(code?: number, reason?: string): void;
  terminate?(): void;
  ping?(): void;
  on(event: "open" | "pong", listener: () => void): this;
  on(event: "close", listener: (code?: number, reason?: string) => void): this;
  on(event: "error", listener: (error: Error) => void): this;
  on(event: "message", listener: (raw: RawData) => void): this;
}

export interface ConnectorDependencies {
  readonly webSocketFactory?: (url: string, headers: Readonly<Record<string, string>>) => WebSocketLike;
  readonly fetch?: typeof fetch;
  readonly logger?: Logger;
  readonly reconnectBaseMs?: number;
  readonly reconnectMaxMs?: number;
  readonly heartbeatMs?: number;
  /**
   * Where to publish the current one-time pairing code for the local pairing
   * page. Omitting it publishes nothing, and the page keeps using the
   * long-lived secret.
   */
  readonly pairingCodePath?: string;
}

export type ConnectorState = "stopped" | "connecting" | "connected" | "reconnecting";

interface BridgeRequest {
  readonly method: "GET" | "POST";
  readonly path: string;
  readonly body?: Record<string, unknown>;
  readonly headers?: Readonly<Record<string, string>>;
}

type TransientStreamingEvent = Extract<EventEnvelope, {
  type: "assistant.message.delta" | "assistant.message.discarded" | "assistant.reasoning";
}>;

/** A durable reasoning record belongs to every client. Only the temporary
 * stream-id form is private to a device that opted into live output. */
function isTransientStreamingEvent(event: EventEnvelope): event is TransientStreamingEvent {
  return event.type === "assistant.message.delta"
    || event.type === "assistant.message.discarded"
    || (event.type === "assistant.reasoning" && event.payload.messageId.startsWith("stream-"));
}

/**
 * Keeps the public Relay connection and the local DSH bridge deliberately separate.
 * The Connector only ever opens outbound connections; no local port is exposed.
 */
export class DSHAnywhereConnector {
  /** A new Bridge socket gets a new lease identity.  Presence requests from a
   * dead socket must not be mistaken for requests from its replacement. */
  private bridgeConnectorId: string | undefined;
  /** Server-issued monotonic lease for the current Relay machine socket. */
  private relayLeaseGeneration: number | undefined;
  private relayEpoch: string | undefined;
  /** Last Bridge event cursor acknowledged by this Connector. */
  private bridgeAfterSequence = 0;
  /** Identifies the Bridge process that owns the replay cursor. */
  private bridgeEpoch: string | undefined;
  /** Bridge replays events before its ready envelope; hold them until the
   * epoch/cursor contract has been checked. */
  private bridgeReady = false;
  private bridgeBufferedEvents: EventEnvelope[] = [];
  private relay: WebSocketLike | undefined;
  private bridge: WebSocketLike | undefined;
  private relayTimer: NodeJS.Timeout | undefined;
  private bridgeTimer: NodeJS.Timeout | undefined;
  private heartbeatTimer: NodeJS.Timeout | undefined;
  private pairingCodeTimer: NodeJS.Timeout | undefined;
  private readonly pairingCodePath: string | undefined;
  private awaitingPong = false;
  private relayAttempts = 0;
  private bridgeAttempts = 0;
  // Seeded from the clock, not zero: the counter is what the phone orders its
  // transcript by and what `replayAfter` filters on, and the device remembers
  // the last value it saw. Restarting the connector used to reset it to 1, so
  // every new event sorted as "oldest" *and* fell below the device's remembered
  // sequence — new output arrived out of order, or was dropped entirely.
  private sequence = Date.now();
  private running = false;
  private state: ConnectorState = "stopped";
  private readonly pendingEvents: EventEnvelope[] = [];
  private readonly recentEvents: EventEnvelope[] = [];
  private pendingEventBytes = 0;
  private recentEventBytes = 0;
  private pendingEventsDropped = false;
  /** Each device's archive view is a query choice, never a global cache. */
  private readonly includeArchivedByDevice = new Map<string, boolean>();
  /** Monotonic query generations prevent a slow presence refresh from
   * overwriting a newer archive/filter selection on the same device. */
  private readonly sessionSnapshotGenerationByDevice = new Map<string, number>();
  /** Explicit list requests must not be silently superseded by an automatic
   * refresh. Defer that refresh until the caller's pending request settles. */
  private readonly pendingSessionListRequests = new Map<string, { requestId: string; generation: number }>();
  /** The most recent explicit list identity remains after its response settles
   * so a late duplicate cannot change the device's archive preference. */
  private readonly latestSessionListCommands = new Map<string, {
    requestId: string;
    generation: number;
    includeArchived: boolean;
  }>();
  /** A request superseded by a newer explicit list remains a tombstone for
   * the dedupe window. Without this, the first retry can be rejected and a
   * second delivery of the same request id can re-enter as a fresh query. */
  private readonly supersededSessionListRequests = new Map<string, number>();
  /** Workspace catalogs are an independent projection from session lists.
   * A mutation push or a later explicit request must fence a slower catalog
   * response, without changing the archive-list generation above. */
  private readonly workspaceCatalogGenerationByDevice = new Map<string, number>();
  private readonly latestWorkspaceCatalogCommands = new Map<string, {
    requestId: string;
    generation: number;
  }>();
  private readonly supersededWorkspaceCatalogRequests = new Map<string, number>();
  private readonly deferredSessionSnapshotDevices = new Set<string>();
  /** Workspace mutations and session projections are separate resources. A
   * stale session query must not suppress the catalog refresh that follows a
   * successful workspace rename/delete. */
  private readonly deferredWorkspaceCatalogDevices = new Set<string>();
  /** Mutation-triggered refreshes remain authoritative until their own
   * post-mutation read has settled. A list request that starts in the middle
   * of that window must receive one more refresh afterwards. */
  private readonly inFlightSessionMutations = new Map<string, number>();
  /** Devices explicitly opted in to transient output for one open session.
   * This state belongs to the Connector (which knows device identity), not the
   * Bridge (which has one trusted Connector socket). */
  private readonly streamingDevicesBySession = new Map<string, Set<string>>();
  /** Coalesces duplicate Relay delivery/retry by the caller's stable id. */
  private readonly commandExecutions = new Map<string, {
    promise: Promise<CommandExecutionOutcome>
    expiresAt: number
    /** Unbounded only for one active request; survives transport queue eviction. */
    events: EventEnvelope[]
  }>();
  /** Keeps correlated results for the same lifetime as command dedupe. A
   * replay receives a fresh transport sequence so iOS does not discard it as
   * an old event after a reconnect. */
  private readonly commandResults = new Map<string, { events: EventEnvelope[]; expiresAt: number }>();
  private readonly onlineRelayDevices = new Set<string>();
  private readonly presenceUpdates = new Map<string, Promise<void>>();

  private readonly webSocketFactory: (url: string, headers: Readonly<Record<string, string>>) => WebSocketLike;
  private readonly request: typeof fetch;
  private readonly logger: Logger;
  private readonly reconnectBaseMs: number;
  private readonly reconnectMaxMs: number;
  private readonly heartbeatMs: number;

  constructor(readonly config: ConnectorConfig, dependencies: ConnectorDependencies = {}) {
    this.webSocketFactory = dependencies.webSocketFactory ?? defaultWebSocketFactory;
    this.request = dependencies.fetch ?? fetch;
    this.logger = dependencies.logger ?? consoleLogger;
    this.reconnectBaseMs = dependencies.reconnectBaseMs ?? 500;
    this.reconnectMaxMs = dependencies.reconnectMaxMs ?? 30_000;
    this.heartbeatMs = dependencies.heartbeatMs ?? 25_000;
    this.pairingCodePath = dependencies.pairingCodePath;
  }

  get status(): ConnectorState {
    return this.state;
  }

  start(): void {
    if (this.running) return;
    this.running = true;
    this.state = "connecting";
    this.connectRelay();
    this.connectBridge();
    this.startPairingCodeRefresh();
  }

  async stop(): Promise<void> {
    this.running = false;
    this.state = "stopped";
    this.clearTimers();
    this.relay?.close(1000, "connector stopped");
    this.bridge?.close(1000, "connector stopped");
    this.relay = undefined;
    this.bridge = undefined;
    this.bridgeConnectorId = undefined;
    this.relayLeaseGeneration = undefined;
    this.relayEpoch = undefined;
    this.bridgeAfterSequence = 0;
    this.bridgeEpoch = undefined;
    this.bridgeReady = false;
    this.bridgeBufferedEvents = [];
    this.pendingEvents.length = 0;
    this.recentEvents.length = 0;
    this.pendingEventBytes = 0;
    this.recentEventBytes = 0;
    this.pendingEventsDropped = false;
    this.streamingDevicesBySession.clear();
    this.commandExecutions.clear();
    this.commandResults.clear();
    this.onlineRelayDevices.clear();
    this.presenceUpdates.clear();
    this.sessionSnapshotGenerationByDevice.clear();
    this.pendingSessionListRequests.clear();
    this.latestSessionListCommands.clear();
    this.supersededSessionListRequests.clear();
    this.workspaceCatalogGenerationByDevice.clear();
    this.latestWorkspaceCatalogCommands.clear();
    this.supersededWorkspaceCatalogRequests.clear();
    this.deferredSessionSnapshotDevices.clear();
    this.deferredWorkspaceCatalogDevices.clear();
    this.inFlightSessionMutations.clear();
  }

  private connectRelay(): void {
    if (!this.running) return;
    this.state = this.relayAttempts === 0 ? "connecting" : "reconnecting";
    const socket = this.webSocketFactory(relayConnectURL(this.config.relayURL), authorization(this.config.machineToken));
    this.relay = socket;
    socket.on("open", () => {
      if (this.relay !== socket || !this.running) return;
      this.relayAttempts = 0;
      this.state = "connected";
      this.startHeartbeat(socket);
      this.flushPendingEvents();
      this.log("info", "Relay connected");
    });
    socket.on("message", (raw: RawData) => this.onRelayMessage(socket, raw));
    socket.on("pong", () => {
      if (this.relay === socket) this.awaitingPong = false;
    });
    socket.on("error", (error: Error) => this.log("warn", `Relay socket error: ${safeError(error, this.config)}`));
    socket.on("close", (code?: number) => {
      if (this.relay !== socket) return;
      this.stopHeartbeat();
      this.relay = undefined;
      const relayGeneration = this.relayLeaseGeneration;
      const relayEpoch = this.relayEpoch;
      const bridgeConnectorId = this.bridgeConnectorId;
      this.relayLeaseGeneration = undefined;
      this.relayEpoch = undefined;
      const disconnectedDevices = [...this.onlineRelayDevices];
      this.onlineRelayDevices.clear();
      for (const deviceId of disconnectedDevices) {
        void this.reportDevicePresence(deviceId, false, bridgeConnectorId, relayGeneration, relayEpoch);
      }
      if (code === 4001) {
        // Relay uses 4001 when another Connector with the same machine lease
        // takes over. Reconnecting here would make two processes continuously
        // evict one another and would flap every remote-device presence edge.
        this.log("warn", "Relay connection was superseded by another Connector; stopping this instance");
        void this.stop();
        return;
      }
      if (this.running) this.scheduleRelayReconnect();
    });
  }

  private connectBridge(): void {
    if (!this.running) return;
    const connectorId = randomUUID();
    this.bridgeConnectorId = connectorId;
    this.bridgeReady = false;
    this.bridgeBufferedEvents = [];
    const socket = this.webSocketFactory(
      bridgeEventsURL(this.config.bridgeBaseURL, connectorId, this.bridgeAfterSequence),
      authorization(this.config.bridgeToken),
    );
    this.bridge = socket;
    socket.on("open", () => {
      if (this.bridge !== socket || !this.running) return;
      this.bridgeAttempts = 0;
      this.log("info", "Local DSH bridge connected");
      for (const deviceId of this.onlineRelayDevices) {
        void this.reportDevicePresence(deviceId, true, connectorId, this.relayLeaseGeneration, this.relayEpoch);
        // A Bridge greeting may contain a snapshot from before the Relay or
        // Bridge reconnect. Refresh every currently-online device from the
        // authoritative HTTP list instead of forwarding that stale greeting.
        void this.pushSessionSnapshot(deviceId);
      }
    });
    socket.on("message", (raw: RawData) => this.onBridgeMessage(socket, raw));
    socket.on("error", (error: Error) => this.log("warn", `Bridge socket error: ${safeError(error, this.config)}`));
    socket.on("close", () => {
      if (this.bridge !== socket) return;
      this.bridge = undefined;
      if (this.bridgeConnectorId === connectorId) this.bridgeConnectorId = undefined;
      if (this.running) this.scheduleBridgeReconnect();
    });
  }

  private onBridgeMessage(socket: WebSocketLike, raw: RawData): void {
    if (socket !== this.bridge || !this.running) return;
    const parsed = parseJson(raw);
    const event = EventEnvelopeSchema.safeParse(parsed);
    if (!event.success) {
      this.log("warn", "Ignored invalid event from local DSH bridge");
      return;
    }
    if (event.data.type === "connection.ready") {
      // Current Bridges stamp the greeting with the connector id from this
      // socket's query string. Replayed greetings carry the id of the socket
      // that originally produced them, so sequence ordering is not needed to
      // distinguish history from the current handshake.
      const connectionId = event.data.payload.bridgeConnectionId;
      if (connectionId === undefined) {
        // A direct phone/browser client may have a legitimate greeting in the
        // Bridge replay buffer, but it has no Connector socket identity. It is
        // therefore history, not evidence that this Connector is incompatible.
        // Keep it quarantined until the current socket's identified greeting
        // arrives; handleBridgeEvent() will ignore the historical control
        // event after the current handshake authorizes the stream.
        this.log("warn", "Ignored Bridge greeting without a Connector socket identity");
        if (!this.bridgeReady && this.bridgeBufferedEvents.length < MAX_REPLAY_EVENTS) {
          this.bridgeBufferedEvents.push(event.data);
        }
        return;
      }
      if (connectionId !== this.bridgeConnectorId) {
        if (this.bridgeBufferedEvents.length < MAX_REPLAY_EVENTS) {
          this.bridgeBufferedEvents.push(event.data);
        }
        return;
      }
      const nextEpoch = event.data.payload.bridgeEpoch;
      const epochChanged = this.bridgeEpoch !== undefined && nextEpoch !== undefined && nextEpoch !== this.bridgeEpoch;
      if (epochChanged || event.data.payload.replayTruncated === true) {
        // The cursor belongs to the previous Bridge process, or its retained
        // buffer no longer reaches that cursor. Restart the socket from zero
        // so the Bridge's authoritative snapshot/history can establish a new
        // sequence epoch instead of silently dropping every new low sequence.
        this.bridgeEpoch = nextEpoch;
        this.bridgeAfterSequence = 0;
        this.bridgeReady = false;
        this.bridgeBufferedEvents = [];
        socket.close(1000, "Bridge replay epoch changed");
        return;
      }
      if (nextEpoch !== undefined) this.bridgeEpoch = nextEpoch;
      if (event.data.sequence > this.bridgeAfterSequence) this.bridgeAfterSequence = event.data.sequence;
      this.bridgeReady = true;
      const buffered = this.bridgeBufferedEvents;
      this.bridgeBufferedEvents = [];
      for (const bufferedEvent of buffered) this.handleBridgeEvent(bufferedEvent);
      // Forward the handshake that authorized this socket after any retained
      // replay entries, preserving the legacy phone-visible ready signal. The
      // Bridge epoch and socket id are local replay-control metadata; strip
      // them before forwarding so an older Relay can still validate the public
      // event schema.
      const { bridgeEpoch: _bridgeEpoch, bridgeConnectionId: _bridgeConnectionId,
        replayTruncated: _replayTruncated, ...publicReadyPayload } = event.data.payload;
      this.sendEvent({ ...event.data, payload: publicReadyPayload });
      return;
    }
    if (!this.bridgeReady) {
      // The Bridge deliberately sends replay entries before connection.ready.
      // Do not expose them until the ready envelope confirms that their epoch
      // is compatible with the cursor we persisted across reconnects.
      if (this.bridgeBufferedEvents.length < MAX_REPLAY_EVENTS) {
        this.bridgeBufferedEvents.push(event.data);
      }
      return;
    }
    this.handleBridgeEvent(event.data);
  }

  private handleBridgeEvent(event: EventEnvelope): void {
    if (event.sequence > this.bridgeAfterSequence) this.bridgeAfterSequence = event.sequence;
    if (event.type === "connection.ready") return;
    // The bridge socket is owned by the connector, not by one phone. Its
    // connection greeting includes an unfiltered session snapshot which can
    // race a device's current archive/list query and replace the UI with an
    // old projection. Lists travel through correlated HTTP commands below;
    // retain live created/title events but never forward this bridge greeting.
    if (event.type === "session.snapshot") return;
    if (isTransientStreamingEvent(event)) {
      this.sendStreamingEvent(event);
      return;
    }
    if (event.type === "assistant.message.completed" && event.payload.replacesMessageId !== undefined) {
      this.sendStreamingCompletion(event);
      return;
    }
    this.sendEvent(event);
  }

  private onRelayMessage(socket: WebSocketLike, raw: RawData): void {
    if (socket !== this.relay || !this.running) return;
    const message = RelayMessageSchema.safeParse(parseJson(raw));
    if (!message.success) {
      this.log("warn", "Ignored invalid message from Relay");
      return;
    }
    if (message.data.type === "relay.error") {
      this.log("warn", `Relay error ${message.data.code}: ${message.data.message}`);
      return;
    }
    if (message.data.type === "relay.ready") {
      // Presence fencing needs the Relay-issued monotonic lease. A wall-clock
      // timestamp or a made-up legacy epoch cannot order delayed reports after
      // a Relay restart, so keep the transport connected but do not announce
      // any phone as online until the current Relay supplies both fields.
      const leaseGeneration = message.data.leaseGeneration;
      const relayEpoch = message.data.relayEpoch;
      if (leaseGeneration === undefined || relayEpoch === undefined) {
        this.relayLeaseGeneration = undefined;
        this.relayEpoch = undefined;
        this.log("warn", "Relay is missing machine lease metadata; presence remains offline");
        return;
      }
      this.relayLeaseGeneration = leaseGeneration;
      this.relayEpoch = relayEpoch;
      for (const deviceId of this.onlineRelayDevices) {
        void this.reportDevicePresence(deviceId, true, this.bridgeConnectorId,
                                       this.relayLeaseGeneration, this.relayEpoch);
      }
      return;
    }
    if (message.data.type === "relay.presence") {
      if (message.data.role === "device" && message.data.deviceId !== undefined) {
        if (message.data.online) this.onlineRelayDevices.add(message.data.deviceId);
        else this.onlineRelayDevices.delete(message.data.deviceId);
        void this.reportDevicePresence(message.data.deviceId, message.data.online,
                                       this.bridgeConnectorId, this.relayLeaseGeneration, this.relayEpoch);
        if (message.data.online) void this.pushSessionSnapshot(message.data.deviceId);
      }
      return;
    }
    if (message.data.type !== "relay.payload" || message.data.sender !== "device") return;
    const command = CommandEnvelopeSchema.safeParse(message.data.body);
    if (!command.success || command.data.machineId !== this.config.machineId) {
      this.log("warn", "Ignored invalid command from Relay");
      return;
    }
    this.log("info", `Received ${command.data.type} from device ${shortID(command.data.deviceId)}`);
    this.dispatchCommand(command.data);
  }

  private dispatchCommand(command: CommandEnvelope): void {
    const now = Date.now();
    for (const [key, execution] of this.commandExecutions) {
      if (execution.expiresAt <= now) this.commandExecutions.delete(key);
    }
    for (const [key, result] of this.commandResults) {
      if (result.expiresAt <= now && !this.commandExecutions.has(key)) this.commandResults.delete(key);
    }
    for (const [key, expiresAt] of this.supersededSessionListRequests) {
      if (expiresAt <= now) this.supersededSessionListRequests.delete(key);
    }
    for (const [key, expiresAt] of this.supersededWorkspaceCatalogRequests) {
      if (expiresAt <= now) this.supersededWorkspaceCatalogRequests.delete(key);
    }
    // A superseded request id remains a tombstone for the whole dedupe
    // window. This covers the internal retry path and repeated deliveries
    // after the first superseded response has already been sent.
    if (command.type === "session.list" && this.isSupersededSessionList(command)) {
      this.sendSupersededSessionList(command);
      return;
    }
    if (command.type === "workspace.catalog" && this.isSupersededWorkspaceCatalog(command)) {
      this.sendSupersededWorkspaceCatalog(command);
      return;
    }
    const key = commandKey(command.machineId, command.deviceId, command.requestId);
    const existing = this.commandExecutions.get(key);
    if (existing !== undefined) {
      // A successful execution is safe to replay without touching the local
      // side effect. A failed execution is different: the first failure may
      // have been a temporary Bridge outage or a timeout whose idempotent
      // request is still running there. Re-submit the same request id so the
      // Bridge either starts it after recovery or returns its stored result;
      // never turn a retry into a fresh side effect with a new id.
      void existing.promise.then((outcome) => {
        if (this.commandExecutions.get(key) !== existing) return;
        if (outcome.state === "failed" && outcome.retryable) {
          this.commandExecutions.delete(key);
          this.commandResults.delete(key);
          this.dispatchCommand(command);
        } else {
          this.replayCommandResult(command);
        }
      });
      return;
    }
    this.commandResults.delete(key);
    const promise = this.executeCommand(command);
    this.commandExecutions.set(key, { promise, expiresAt: now + COMMAND_DEDUP_TTL_MS, events: [] });
    void promise;
  }

  private async executeCommand(command: CommandEnvelope): Promise<CommandExecutionOutcome> {
    let sessionSnapshotGeneration: number | undefined;
    let workspaceCatalogGeneration: number | undefined;
    try {
      // The Connector owns the Relay-side replay window. This lets a device
      // connect after the bridge has already emitted its initial snapshot.
      if (command.type === "connection.resume") {
        this.includeArchivedByDevice.set(command.deviceId, command.payload.includeArchived === true);
        this.replayAfter(command.payload.lastSequence, command.deviceId);
        // Resume is the one command every released iOS build reliably sends.
        // Follow it with an authoritative list so session discovery does not
        // depend on a separate refresh command or Relay presence timing.
        await this.pushSessionSnapshot(command.deviceId);
        return { state: "completed" };
      }
      // Record the selected archive view before waiting for the bridge. An
      // older, slower list response must not overwrite a newer user choice
      // and make the following archive mutation refresh the wrong projection.
      const isSessionList = command.type === "session.list";
      const includeArchived = isSessionList && command.payload.includeArchived === true;
      sessionSnapshotGeneration = isSessionList
        ? this.beginSessionSnapshotQuery(command.deviceId, includeArchived)
        : undefined;
      workspaceCatalogGeneration = command.type === "workspace.catalog"
        ? this.beginWorkspaceCatalogQuery(command.deviceId, command.requestId)
        : undefined;
      if (sessionSnapshotGeneration !== undefined) {
        this.rememberLatestSessionListCommand(command.deviceId, command.requestId,
                                              sessionSnapshotGeneration, includeArchived);
        if (this.inFlightSessionMutations.has(command.deviceId)) {
          this.deferredSessionSnapshotDevices.add(command.deviceId);
        }
        this.pendingSessionListRequests.set(command.deviceId, {
          requestId: command.requestId,
          generation: sessionSnapshotGeneration,
        });
      }
      if (command.type === "session.open") {
        this.setStreamingPreference(command.sessionId ?? command.payload.sessionId,
                                    command.deviceId, command.payload.streaming === true);
      }
      const request = bridgeRequestFor(command);
      // A photo can be several megabytes after base64 encoding. Keep normal
      // commands snappy, but give the local Harness upload service enough time
      // to download, decode, and persist a large attachment.
      const response = await this.callBridge(
        request,
        bridgeTimeoutFor(command),
        command.requestId,
      );
      await this.emitCommandResult(command, response, sessionSnapshotGeneration, workspaceCatalogGeneration);
      return { state: "completed" };
    } catch (error) {
      const staleSessionList = command.type === "session.list" &&
        sessionSnapshotGeneration !== undefined &&
        !this.isCurrentSessionSnapshotQuery(command.deviceId, sessionSnapshotGeneration);
      const staleWorkspaceCatalog = command.type === "workspace.catalog" &&
        workspaceCatalogGeneration !== undefined &&
        !this.isCurrentWorkspaceCatalogQuery(command.deviceId, workspaceCatalogGeneration);
      if (command.type === "session.list") this.finishSessionListRequest(command, undefined);
      // A newer request (or an automatic authoritative push) owns the current
      // projection. Do not surface the older timeout as a user error or retry
      // it into an outdated archive/catalog response.
      if (staleSessionList || staleWorkspaceCatalog) return { state: "completed" };
      const retryable = this.sendProtocolError(command, error);
      if (command.type === "session.list") this.flushDeferredSessionSnapshot(command.deviceId);
      return { state: "failed", retryable };
    }
  }

  private async callBridge(request: BridgeRequest, timeoutMs = 15_000, idempotencyKey?: string): Promise<unknown> {
    const encodedBody = request.body === undefined ? undefined : JSON.stringify(request.body);
    const bodyHash = encodedBody === undefined
      ? undefined
      : createHash("sha256").update(encodedBody).digest("hex");
    const response = await this.request(bridgeAPIURL(this.config.bridgeBaseURL, request.path), {
      method: request.method,
      headers: {
        ...authorization(this.config.bridgeToken),
        ...request.headers,
        ...(idempotencyKey === undefined ? {} : { "x-dsh-request-id": idempotencyKey }),
        ...(encodedBody === undefined ? {} : {
          "content-type": "application/json",
          "x-dsh-request-hash": bodyHash!,
        }),
      },
      ...(encodedBody === undefined ? {} : { body: encodedBody }),
      signal: AbortSignal.timeout(timeoutMs),
    });
    if (!response.ok) {
      const outcomeHeader = response.headers.get("x-dsh-idempotency-outcome");
      const outcome = outcomeHeader === "retryable" || outcomeHeader === "unknown"
        ? outcomeHeader : undefined;
      throw new BridgeRequestError(response.status, `HTTP ${response.status}`, outcome);
    }
    const contentType = response.headers.get("content-type") ?? "";
    return contentType.includes("application/json") ? response.json() : undefined;
  }

  private reportDevicePresence(deviceId: string, online: boolean,
                               connectorId = this.bridgeConnectorId,
                               relayGeneration = this.relayLeaseGeneration,
                               relayEpoch = this.relayEpoch): Promise<void> {
    if (connectorId === undefined || relayGeneration === undefined || relayEpoch === undefined) return Promise.resolve();
    const previous = this.presenceUpdates.get(deviceId) ?? Promise.resolve();
    const update = previous.catch(() => undefined).then(async () => {
      try {
        await this.callBridge({
          method: "POST",
          path: `/devices/${encodeURIComponent(deviceId)}/presence`,
          body: { online, connectorId, relayGeneration, relayEpoch },
        });
      } catch (error) {
        this.log("warn", `Could not report device presence to local bridge: ${safeError(error, this.config)}`);
      }
    });
    this.presenceUpdates.set(deviceId, update);
    void update.finally(() => {
      if (this.presenceUpdates.get(deviceId) === update) this.presenceUpdates.delete(deviceId);
    });
    return update;
  }

  private async emitCommandResult(command: CommandEnvelope, response: unknown,
                                  sessionSnapshotGeneration?: number,
                                  workspaceCatalogGeneration?: number): Promise<void> {
    if (command.type === "session.open") {
      // The bridge publishes the requested historical events over its existing
      // event socket. There is no extra command-result card for opening a
      // conversation; the phone only needs the transcript events themselves.
      return;
    }
    if (command.type === "prompt.send") {
      const data = asRecord(response);
      if (data.accepted === true) {
        const sessionId = requireSessionId(command);
        // The HTTP acceptance is the request receipt.  Keep it separate from
        // the broadcast durable user-message event so a lost transcript frame
        // can be replayed to exactly this device without guessing by text.
        this.sendEvent({
          version: PROTOCOL_VERSION,
          messageId: command.requestId,
          machineId: this.config.machineId,
          deviceId: command.deviceId,
          sessionId,
          sequence: ++this.sequence,
          timestamp: Date.now(),
          type: "prompt.accepted",
          payload: PromptAcceptedPayloadSchema.parse({ sessionId, requestId: command.requestId }),
        }, command.deviceId, command.requestId);
      }
      return;
    }
    if (command.type === "session.list") {
      const data = asRecord(response);
      const items = Array.isArray(data.items) ? data.items.map((item) => SessionSummarySchema.parse(item)) : [];
      if (sessionSnapshotGeneration === undefined ||
          !this.isCurrentSessionSnapshotQuery(command.deviceId, sessionSnapshotGeneration)) return;
      const pending = this.pendingSessionListRequests.get(command.deviceId);
      if (pending?.requestId !== command.requestId || pending.generation !== sessionSnapshotGeneration) return;
      this.pendingSessionListRequests.delete(command.deviceId);
      this.log("info", `Sending session snapshot (${items.length} sessions) to device ${shortID(command.deviceId)}`);
      this.sendSessionSnapshot(items, command.deviceId, command.requestId);
      this.flushDeferredSessionSnapshot(command.deviceId);
      return;
    }
    if (command.type === "session.create") {
      const data = asRecord(response);
      const sessionId = typeof data.sessionId === "string" ? data.sessionId : undefined;
      if (sessionId === undefined) throw new BridgeRequestError(502, "bridge response lacks sessionId");
      const summary = asRecord(data.summary);
      const fallbackSummary = {
        id: sessionId,
        // A server list projection replaces this immediately. Keep the same
        // blank-session placeholder in the narrow fallback path.
        title: command.payload.title ?? "新会话",
        updatedAt: Date.now(),
      };
      this.sendEvent({
        version: PROTOCOL_VERSION,
        messageId: command.requestId,
        machineId: this.config.machineId,
        deviceId: command.deviceId,
        sessionId,
        sequence: ++this.sequence,
        timestamp: Date.now(),
        type: "session.created",
        payload: SessionSummarySchema.parse({
          ...(Object.keys(summary).length > 0 ? summary : fallbackSummary),
          createRequestId: command.requestId,
        }),
      });
      if (command.payload.initialPrompt !== undefined) {
        await this.callBridge({
          method: "POST",
          path: `/sessions/${encodeURIComponent(sessionId)}/prompt`,
          body: { text: command.payload.initialPrompt, requestId: command.requestId, deviceId: command.deviceId },
        }, LONG_BRIDGE_TIMEOUT_MS, command.requestId);
      }
      return;
    }
    if (command.type === "session.archive" || command.type === "session.model"
        || command.type === "permission.set"
        || command.type === "workspace.rename" || command.type === "workspace.delete"
        || command.type === "session.rename") {
      const workspaceMutation = command.type === "workspace.rename" || command.type === "workspace.delete";
      // These operations mutate native Harness metadata. Refresh the same
      // filtered list used by the live bridge so archived sessions disappear
      // immediately while model/workspace labels update in place.
      // permission.set joins this branch (instead of the generic
      // command.result card) because its effect already arrives as
      // `permission.updated`: a "Command completed" card would be noise, and
      // failures still surface through `protocol.error`.
      if (this.pendingSessionListRequests.has(command.deviceId)) {
        // Let the explicit request finish first. Its response may have been
        // issued before this mutation and is therefore not necessarily the
        // current list; a deferred refresh below supplies the authoritative
        // post-mutation projection without orphaning the pending request.
        this.deferredSessionSnapshotDevices.add(command.deviceId);
        if (workspaceMutation) void this.pushWorkspaceCatalog(command.deviceId);
        return;
      }
      const generation = this.beginSessionSnapshotQuery(command.deviceId);
      this.inFlightSessionMutations.set(command.deviceId,
        (this.inFlightSessionMutations.get(command.deviceId) ?? 0) + 1);
      try {
        const refreshed = asRecord(await this.callBridge({ method: "GET", path: this.sessionListPath(command.deviceId) }));
        const items = Array.isArray(refreshed.items)
          ? refreshed.items.map((item) => SessionSummarySchema.parse(item))
          : [];
        if (!this.isCurrentSessionSnapshotQuery(command.deviceId, generation)) {
          // An explicit list or another refresh crossed this mutation. Keep a
          // final post-mutation read queued instead of silently accepting the
          // older projection.
          this.deferredSessionSnapshotDevices.add(command.deviceId);
          if (workspaceMutation) this.deferredWorkspaceCatalogDevices.add(command.deviceId);
          return;
        }
        // A list is a mutable projection, not an immutable command result.
        // Do not associate this snapshot with the mutation's idempotency cache;
        // a duplicate mutation will query the current list instead of replaying
        // an old snapshot with a fresh transport sequence.
        this.sendSessionSnapshot(items, command.deviceId);
        if (workspaceMutation) await this.pushWorkspaceCatalog(command.deviceId);
      } finally {
        const remaining = (this.inFlightSessionMutations.get(command.deviceId) ?? 1) - 1;
        if (remaining <= 0) this.inFlightSessionMutations.delete(command.deviceId);
        else this.inFlightSessionMutations.set(command.deviceId, remaining);
        if (!this.inFlightSessionMutations.has(command.deviceId)) {
          this.flushDeferredSessionSnapshot(command.deviceId);
          this.flushDeferredWorkspaceCatalog(command.deviceId);
        }
      }
      return;
    }
    if (command.type === "model.catalog") {
      const data = asRecord(response);
      this.sendEvent({
        version: PROTOCOL_VERSION,
        messageId: command.requestId,
        machineId: this.config.machineId,
        deviceId: command.deviceId,
        sequence: ++this.sequence,
        timestamp: Date.now(),
        type: "model.catalog",
        payload: ModelCatalogPayloadSchema.parse(data),
      });
      return;
    }
    if (command.type === "workspace.catalog") {
      if (workspaceCatalogGeneration === undefined ||
          !this.isCurrentWorkspaceCatalogQuery(command.deviceId, workspaceCatalogGeneration)) return;
      const data = asRecord(response);
      this.sendEvent({
        version: PROTOCOL_VERSION,
        messageId: command.requestId,
        machineId: this.config.machineId,
        deviceId: command.deviceId,
        sequence: ++this.sequence,
        timestamp: Date.now(),
        type: "workspace.catalog",
        payload: WorkspaceCatalogPayloadSchema.parse(data),
      });
      return;
    }
    if (command.type === "workspace.create") {
      const data = asRecord(response);
      const workspace = asRecord(data.workspace);
      this.sendEvent({
        version: PROTOCOL_VERSION,
        messageId: command.requestId,
        machineId: this.config.machineId,
        deviceId: command.deviceId,
        sequence: ++this.sequence,
        timestamp: Date.now(),
        type: "workspace.created",
        payload: WorkspaceSchema.parse(workspace),
      });
      return;
    }
    if (command.type === "mode.catalog") {
      const data = asRecord(response);
      this.sendEvent({
        version: PROTOCOL_VERSION,
        messageId: command.requestId,
        machineId: this.config.machineId,
        deviceId: command.deviceId,
        sequence: ++this.sequence,
        timestamp: Date.now(),
        type: "mode.catalog",
        payload: ModeCatalogPayloadSchema.parse(data),
      });
      return;
    }
    if (command.type === "directory.list") {
      const data = asRecord(response);
      this.sendEvent({
        version: PROTOCOL_VERSION,
        messageId: command.requestId,
        machineId: this.config.machineId,
        deviceId: command.deviceId,
        sequence: ++this.sequence,
        timestamp: Date.now(),
        type: "directory.list",
        payload: DirectoryListPayloadSchema.parse(data),
      });
      return;
    }
    if (command.type === "command.execute") {
      const raw = asRecord(response);
      // Typert remote calls may return a RemoteResult wrapper while the local
      // fallback returns CommandExecution directly. Accept both shapes.
      const data = Object.keys(asRecord(raw.value)).length > 0 ? asRecord(raw.value) : raw;
      const result = asRecord(data.result);
      this.sendEvent({
        version: PROTOCOL_VERSION,
        messageId: command.requestId,
        machineId: this.config.machineId,
        deviceId: command.deviceId,
        ...(command.sessionId === undefined ? {} : { sessionId: command.sessionId }),
        sequence: ++this.sequence,
        timestamp: Date.now(),
        type: "command.result",
        payload: CommandResultPayloadSchema.parse({
          sessionId: command.sessionId ?? "unknown",
          requestId: command.requestId,
          matched: data.matched === true || (Object.keys(data).length > 0 && data.commandId !== undefined),
          ...(typeof data.commandId === "string" ? { commandId: data.commandId } : {}),
          ...(typeof result.kind === "string" ? { kind: result.kind } : {}),
          ...(typeof result.text === "string" ? { text: result.text } : {}),
        }),
      });
      return;
    }
    if (command.type === "attachment.upload") {
      const data = asRecord(response);
      this.sendEvent({
        version: PROTOCOL_VERSION,
        messageId: command.requestId,
        machineId: this.config.machineId,
        deviceId: command.deviceId,
        ...(command.sessionId === undefined ? {} : { sessionId: command.sessionId }),
        sequence: ++this.sequence,
        timestamp: Date.now(),
        type: "attachment.uploaded",
        payload: AttachmentUploadedPayloadSchema.parse({
          sessionId: command.sessionId ?? "unknown",
          requestId: command.requestId,
          receiptId: String(data.receiptId ?? ""),
          name: command.payload.name,
          ...(typeof data.mediaType === "string" ? { mediaType: data.mediaType } : {}),
          ...(typeof data.size === "number" ? { size: data.size } : {}),
        }),
      });
    }
  }

  private replayCommandResult(command: CommandEnvelope): void {
    const key = commandKey(command.machineId, command.deviceId, command.requestId);
    const cached = this.commandResults.get(key);
    const execution = this.commandExecutions.get(key);
    const events = cached?.events ?? execution?.events ?? this.recentEvents.filter((event) =>
      event.messageId === command.requestId && event.deviceId === command.deviceId);
    if (command.type === "session.list") {
      // A list has no durable side effect to cache. Re-read the authoritative
      // projection and correlate the fresh snapshot to the duplicate request;
      // replaying the old snapshot would either be stale or be filtered out.
      void this.replaySessionList(command);
      return;
    }
    if (command.type === "workspace.catalog") {
      // A catalog has no durable side effect to cache. Re-read the current
      // native registry and correlate the fresh response to this request;
      // replaying an older catalog could overwrite a mutation push.
      void this.replayWorkspaceCatalog(command);
      return;
    }
    // Reissue through sendEvent so the result receives a fresh monotonic
    // transport sequence. Reusing the original sequence is silently filtered
    // by the iOS reducer after it has processed later events.
    for (const event of events.filter((candidate) => candidate.type !== "session.snapshot")) {
      this.sendEvent({ ...event, timestamp: Date.now() }, command.deviceId, command.requestId);
    }
    if (isSessionProjectionMutation(command)) {
      // Snapshots change as other clients mutate the Mac. Re-query after a
      // duplicate instead of replaying the historical projection cached by the
      // first execution.
      void this.pushSessionSnapshot(command.deviceId);
      if (command.type === "workspace.rename" || command.type === "workspace.delete") {
        void this.pushWorkspaceCatalog(command.deviceId);
      }
    }
  }

  private async replaySessionList(command: Extract<CommandEnvelope, { type: "session.list" }>): Promise<void> {
    const latest = this.latestSessionListCommands.get(command.deviceId);
    if (latest !== undefined && latest.requestId !== command.requestId) {
      this.sendSupersededSessionList(command);
      return;
    }
    const generation = this.beginSessionSnapshotQuery(command.deviceId, command.payload.includeArchived === true);
    this.rememberLatestSessionListCommand(command.deviceId, command.requestId, generation,
                                          command.payload.includeArchived === true);
    this.pendingSessionListRequests.set(command.deviceId, {
      requestId: command.requestId,
      generation,
    });
    try {
      const data = asRecord(await this.callBridge({ method: "GET", path: this.sessionListPath(command.deviceId) }));
      const items = Array.isArray(data.items) ? data.items.map((item) => SessionSummarySchema.parse(item)) : [];
      const pending = this.pendingSessionListRequests.get(command.deviceId);
      if (!this.isCurrentSessionSnapshotQuery(command.deviceId, generation) ||
          pending?.requestId !== command.requestId || pending.generation !== generation) return;
      this.pendingSessionListRequests.delete(command.deviceId);
      this.sendSessionSnapshot(items, command.deviceId, command.requestId, command.requestId);
      this.flushDeferredSessionSnapshot(command.deviceId);
    } catch (error) {
      this.log("warn", `Failed to replay session list for device ${shortID(command.deviceId)}: ${safeError(error, this.config)}`);
      this.finishSessionListRequest(command, generation);
      if (!this.isCurrentSessionSnapshotQuery(command.deviceId, generation)) return;
      this.sendProtocolError(command, error);
      this.flushDeferredSessionSnapshot(command.deviceId);
    }
  }

  private async replayWorkspaceCatalog(command: Extract<CommandEnvelope, { type: "workspace.catalog" }>): Promise<void> {
    const latest = this.latestWorkspaceCatalogCommands.get(command.deviceId);
    if (latest !== undefined && latest.requestId !== command.requestId) {
      this.sendSupersededWorkspaceCatalog(command);
      return;
    }
    const generation = this.beginWorkspaceCatalogQuery(command.deviceId, command.requestId);
    try {
      const data = asRecord(await this.callBridge({ method: "GET", path: "/workspaces" }));
      if (!this.isCurrentWorkspaceCatalogQuery(command.deviceId, generation)) return;
      const current = this.latestWorkspaceCatalogCommands.get(command.deviceId);
      if (current?.requestId !== command.requestId || current.generation !== generation) return;
      this.sendEvent({
        version: PROTOCOL_VERSION,
        messageId: command.requestId,
        machineId: this.config.machineId,
        deviceId: command.deviceId,
        sequence: ++this.sequence,
        timestamp: Date.now(),
        type: "workspace.catalog",
        payload: WorkspaceCatalogPayloadSchema.parse(data),
      }, command.deviceId, command.requestId);
    } catch (error) {
      this.log("warn", `Failed to replay workspace catalog for device ${shortID(command.deviceId)}: ${safeError(error, this.config)}`);
      if (!this.isCurrentWorkspaceCatalogQuery(command.deviceId, generation)) return;
      this.sendProtocolError(command, error);
    }
  }

  private sendSupersededSessionList(command: Extract<CommandEnvelope, { type: "session.list" }>): void {
    this.sendEvent({
      version: PROTOCOL_VERSION,
      messageId: command.requestId,
      machineId: this.config.machineId,
      deviceId: command.deviceId,
      sequence: ++this.sequence,
      timestamp: Date.now(),
      type: "protocol.error",
      payload: {
        code: "request-superseded",
        message: "A newer session list request already established the current filter.",
        retryable: false,
      },
    }, command.deviceId, command.requestId);
  }

  private sendSupersededWorkspaceCatalog(command: Extract<CommandEnvelope, { type: "workspace.catalog" }>): void {
    this.sendEvent({
      version: PROTOCOL_VERSION,
      messageId: command.requestId,
      machineId: this.config.machineId,
      deviceId: command.deviceId,
      sequence: ++this.sequence,
      timestamp: Date.now(),
      type: "protocol.error",
      payload: {
        code: "request-superseded",
        message: "A newer workspace catalog request already established the current registry.",
        retryable: false,
      },
    }, command.deviceId, command.requestId);
  }

  private sendProtocolError(command: CommandEnvelope, error: unknown): boolean {
    // A successful native mutation can still be followed by a broken HTTP
    // response (for example a truncated JSON body).  Only an explicit
    // client-error response proves that session creation was rejected before
    // it reached the Harness; every other create failure keeps the original
    // request id in the recoverable "result unknown" state.
    const definitelyRejected = error instanceof BridgeRequestError
      && error.status >= 400 && error.status < 500 && error.outcome !== "unknown";
    const resultUnknown = !definitelyRejected && (
      (error instanceof Error && error.name === "TimeoutError")
      || (error instanceof BridgeRequestError && error.outcome === "unknown")
      || command.type === "session.create"
    );
    const reason = resultUnknown
      ? "Local operation did not confirm completion before the deadline; its result is unknown"
      : error instanceof BridgeRequestError
        ? `Local DSH bridge request failed (HTTP ${error.status})`
        : "Local DSH bridge request failed";
    this.log("warn", `${reason} for ${command.type}: ${safeError(error, this.config)}`);
    // A Connector-side timeout is safe to retry with the same id: the Bridge
    // idempotency entry either is still running or can return its stored result.
    // An explicit Bridge `unknown` outcome remains non-retryable because the
    // native side may already have committed a partial effect.
    const retryable = resultUnknown
      ? command.type === "session.create" || (error instanceof Error && error.name === "TimeoutError")
      : isRetryable(error);
    this.sendEvent({
      version: PROTOCOL_VERSION,
      messageId: command.requestId,
      machineId: this.config.machineId,
      deviceId: command.deviceId,
      ...(command.sessionId === undefined ? {} : { sessionId: command.sessionId }),
      sequence: ++this.sequence,
      timestamp: Date.now(),
      type: "protocol.error",
      payload: {
        code: resultUnknown ? "bridge-result-unknown" : "bridge-request-failed",
        message: reason,
        // A retry keeps this request id. The Bridge's idempotency layer then
        // either starts an unaccepted request after recovery or returns the
        // result of a side effect that was already accepted.
        retryable,
      },
    }, command.deviceId, command.requestId);
    return retryable;
  }

  private async pushSessionSnapshot(deviceId: string): Promise<void> {
    if (this.pendingSessionListRequests.has(deviceId) || this.inFlightSessionMutations.has(deviceId)) {
      this.deferredSessionSnapshotDevices.add(deviceId);
      return;
    }
    const generation = this.beginSessionSnapshotQuery(deviceId);
    try {
      const data = asRecord(await this.callBridge({ method: "GET", path: this.sessionListPath(deviceId) }));
      const items = Array.isArray(data.items) ? data.items.map((item) => SessionSummarySchema.parse(item)) : [];
      if (!this.isCurrentSessionSnapshotQuery(deviceId, generation)) return;
      this.log("info", `Device ${shortID(deviceId)} online; pushing session snapshot (${items.length} sessions)`);
      this.sendSessionSnapshot(items, deviceId);
    } catch (error) {
      this.log("warn", `Failed to push session snapshot to device ${shortID(deviceId)}: ${safeError(error, this.config)}`);
    }
  }

  private async pushWorkspaceCatalog(deviceId: string): Promise<void> {
    const generation = this.beginWorkspaceCatalogQuery(deviceId);
    try {
      const data = asRecord(await this.callBridge({ method: "GET", path: "/workspaces" }));
      if (!this.isCurrentWorkspaceCatalogQuery(deviceId, generation)) return;
      this.sendEvent({
        version: PROTOCOL_VERSION,
        messageId: `workspace-push-${randomUUID()}`,
        machineId: this.config.machineId,
        deviceId,
        sequence: ++this.sequence,
        timestamp: Date.now(),
        type: "workspace.catalog",
        payload: WorkspaceCatalogPayloadSchema.parse(data),
      }, deviceId);
    } catch (error) {
      this.log("warn", `Failed to push workspace catalog to device ${shortID(deviceId)}: ${safeError(error, this.config)}`);
    }
  }

  private sendSessionSnapshot(
    items: SessionSummary[],
    deviceId: string,
    messageId: string = `${UNSOLICITED_SESSION_SNAPSHOT_PREFIX}${randomUUID()}`,
    commandRequestId?: string,
  ): void {
    // One full snapshot is authoritative. The old compatibility pre-snapshot
    // briefly replaced current rows with stale stripped data, causing the
    // home screen to flash several times during launch.
    this.sendEvent({
      version: PROTOCOL_VERSION,
      messageId,
      machineId: this.config.machineId,
      deviceId,
      sequence: ++this.sequence,
      timestamp: Date.now(),
      type: "session.snapshot",
      payload: items,
    }, deviceId, commandRequestId);
  }

  private sessionListPath(deviceId: string): string {
    const query = this.includeArchivedByDevice.get(deviceId) === true ? "includeArchived=true&" : "";
    return `/sessions?${query}deviceId=${encodeURIComponent(deviceId)}`;
  }

  private beginSessionSnapshotQuery(deviceId: string, includeArchived?: boolean): number {
    if (includeArchived !== undefined) this.includeArchivedByDevice.set(deviceId, includeArchived);
    const generation = (this.sessionSnapshotGenerationByDevice.get(deviceId) ?? 0) + 1;
    this.sessionSnapshotGenerationByDevice.set(deviceId, generation);
    return generation;
  }

  private isCurrentSessionSnapshotQuery(deviceId: string, generation: number): boolean {
    return this.sessionSnapshotGenerationByDevice.get(deviceId) === generation;
  }

  private isSupersededSessionList(command: Extract<CommandEnvelope, { type: "session.list" }>): boolean {
    return this.supersededSessionListRequests.has(this.queryTombstoneKey(command.deviceId, command.requestId));
  }

  private rememberLatestSessionListCommand(deviceId: string, requestId: string,
                                           generation: number, includeArchived: boolean): void {
    const previous = this.latestSessionListCommands.get(deviceId);
    if (previous !== undefined && previous.requestId !== requestId) {
      this.supersededSessionListRequests.set(
        this.queryTombstoneKey(deviceId, previous.requestId), Date.now() + COMMAND_DEDUP_TTL_MS,
      );
    }
    this.latestSessionListCommands.set(deviceId, { requestId, generation, includeArchived });
  }

  private beginWorkspaceCatalogQuery(deviceId: string, requestId?: string): number {
    const generation = (this.workspaceCatalogGenerationByDevice.get(deviceId) ?? 0) + 1;
    this.workspaceCatalogGenerationByDevice.set(deviceId, generation);
    if (requestId !== undefined) {
      const previous = this.latestWorkspaceCatalogCommands.get(deviceId);
      if (previous !== undefined && previous.requestId !== requestId) {
        this.supersededWorkspaceCatalogRequests.set(
          this.queryTombstoneKey(deviceId, previous.requestId), Date.now() + COMMAND_DEDUP_TTL_MS,
        );
      }
      this.latestWorkspaceCatalogCommands.set(deviceId, { requestId, generation });
    }
    return generation;
  }

  private isCurrentWorkspaceCatalogQuery(deviceId: string, generation: number): boolean {
    return this.workspaceCatalogGenerationByDevice.get(deviceId) === generation;
  }

  private isSupersededWorkspaceCatalog(command: Extract<CommandEnvelope, { type: "workspace.catalog" }>): boolean {
    return this.supersededWorkspaceCatalogRequests.has(this.queryTombstoneKey(command.deviceId, command.requestId));
  }

  private queryTombstoneKey(deviceId: string, requestId: string): string {
    return `${deviceId}\0${requestId}`;
  }

  private finishSessionListRequest(command: CommandEnvelope, generation: number | undefined): void {
    const pending = this.pendingSessionListRequests.get(command.deviceId);
    if (pending === undefined || pending.requestId !== command.requestId ||
        (generation !== undefined && pending.generation !== generation)) return;
    this.pendingSessionListRequests.delete(command.deviceId);
  }

  private flushDeferredSessionSnapshot(deviceId: string): void {
    if (this.pendingSessionListRequests.has(deviceId) || this.inFlightSessionMutations.has(deviceId)) return;
    if (!this.deferredSessionSnapshotDevices.delete(deviceId)) return;
    void this.pushSessionSnapshot(deviceId);
  }

  private flushDeferredWorkspaceCatalog(deviceId: string): void {
    if (!this.deferredWorkspaceCatalogDevices.delete(deviceId)) return;
    void this.pushWorkspaceCatalog(deviceId);
  }

  private setStreamingPreference(sessionId: string, deviceId: string, enabled: boolean): void {
    const devices = this.streamingDevicesBySession.get(sessionId) ?? new Set<string>();
    if (enabled) devices.add(deviceId);
    else devices.delete(deviceId);
    if (devices.size === 0) this.streamingDevicesBySession.delete(sessionId);
    else this.streamingDevicesBySession.set(sessionId, devices);
  }

  /** Live deltas, reasoning snapshots, and abandoned-attempt cleanups are
   * never broadcast: legacy clients do not know that their temporary ids must
   * be removed. Readdressing the body itself, rather than only Relay's target,
   * also keeps replay scoped to the opted-in device. */
  private sendStreamingEvent(event: Extract<EventEnvelope,
    { type: "assistant.message.delta" | "assistant.message.discarded" | "assistant.reasoning" }>): void {
    const sessionId = event.sessionId;
    if (sessionId === undefined) return;
    for (const deviceId of this.streamingDevicesBySession.get(sessionId) ?? []) {
      this.sendEvent({ ...event, deviceId }, deviceId);
    }
  }

  /** Deliver the replacement hint only to clients that received the temporary
   * stream. Everyone receives the same canonical completion without the new
   * field, so strict legacy decoders remain valid. The targeted event is sent
   * before the broadcast completion, allowing a current client to remove its
   * transient bubble before the canonical row is observed. */
  private sendStreamingCompletion(event: Extract<EventEnvelope, { type: "assistant.message.completed" }>): void {
    const sessionId = event.sessionId;
    if (sessionId !== undefined) {
      for (const deviceId of this.streamingDevicesBySession.get(sessionId) ?? []) {
        this.sendEvent({ ...event, deviceId }, deviceId);
      }
    }
    const { replacesMessageId: _replacement, ...canonicalPayload } = event.payload;
    this.sendEvent({ ...event, payload: canonicalPayload });
  }

  private sendEvent(event: EventEnvelope, targetDeviceId?: string, commandRequestId?: string): void {
    const payload = event.type === "connection.ready"
      ? { ...event.payload, machineId: this.config.machineId }
      : event.payload;
    const body = EventEnvelopeSchema.parse({
      ...event,
      machineId: this.config.machineId,
      payload,
      sequence: ++this.sequence,
    });
    this.rememberEvent(body);
    if (commandRequestId !== undefined) {
      this.rememberCommandResult(commandKey(body.machineId, body.deviceId, commandRequestId), body);
    }
    const relay = this.relay;
    if (relay === undefined || relay.readyState !== WebSocket.OPEN) {
      // Cache the canonical event before placing it in the bounded transport
      // queue. A request result must remain replayable even if unrelated
      // offline events later evict their wire copies.
      this.queueEvent(body);
      return;
    }
    // A bridge/command response carries its intended recipient in the event
    // envelope. Preserve that address through offline queueing too; otherwise
    // one phone's folder picker or archive snapshot is broadcast to every
    // paired device when the relay reconnects.
    this.sendRelayEvent(body, targetDeviceId ?? (body.deviceId === "broadcast" ? undefined : body.deviceId));
  }

  private sendRelayEvent(body: EventEnvelope, targetDeviceId?: string): void {
    const relay = this.relay;
    if (relay === undefined || relay.readyState !== WebSocket.OPEN) return;
    if ((relay.bufferedAmount ?? 0) > MAX_RELAY_BUFFERED_BYTES) {
      relay.terminate?.();
      return;
    }
    const message = RelayPayloadMessageSchema.parse({
      type: "relay.payload",
      machineId: this.config.machineId,
      messageId: randomUUID(),
      sender: "machine",
      ...(targetDeviceId === undefined ? {} : { targetDeviceId }),
      body,
    });
    relay.send(JSON.stringify(message));
  }

  private rememberEvent(event: EventEnvelope): void {
    const bytes = eventBytes(event);
    while (this.recentEvents.length > 0 &&
      (this.recentEvents.length >= MAX_REPLAY_EVENTS || this.recentEventBytes + bytes > MAX_REPLAY_BYTES)) {
      this.recentEventBytes -= eventBytes(this.recentEvents.shift()!);
    }
    if (bytes > MAX_REPLAY_BYTES) return;
    this.recentEvents.push(event);
    this.recentEventBytes += bytes;
    if (event.deviceId !== "broadcast") {
      const key = commandKey(event.machineId, event.deviceId, event.messageId);
      if (this.commandExecutions.has(key)) this.rememberCommandResult(key, event);
    }
  }

  private rememberCommandResult(key: string, event: EventEnvelope): void {
    const now = Date.now();
    for (const [entryKey, entry] of this.commandResults) {
      if (entry.expiresAt <= now && !this.commandExecutions.has(entryKey)) this.commandResults.delete(entryKey);
    }
    const execution = this.commandExecutions.get(key);
    if (execution !== undefined && !execution.events.some((candidate) => candidate.messageId === event.messageId)) {
      execution.events.push(event);
    }
    let entry = this.commandResults.get(key);
    if (entry === undefined) {
      if (this.commandResults.size >= MAX_COMMAND_RESULT_ENTRIES) {
        const evictable = [...this.commandResults].find(([entryKey]) => !this.commandExecutions.has(entryKey));
        if (evictable === undefined) return;
        this.commandResults.delete(evictable[0]);
      }
      entry = { events: [], expiresAt: now + COMMAND_DEDUP_TTL_MS };
      this.commandResults.set(key, entry);
    }
    const existingIndex = entry.events.findIndex((candidate) => candidate.messageId === event.messageId);
    if (existingIndex >= 0) entry.events[existingIndex] = event;
    else entry.events.push(event);
    entry.expiresAt = now + COMMAND_DEDUP_TTL_MS;
  }

  private replayAfter(lastSequence: number, targetDeviceId: string): void {
    const oldest = this.recentEvents[0]?.sequence;
    if (lastSequence > 0 && oldest !== undefined && oldest > lastSequence + 1) {
      this.sendEvent({
        version: PROTOCOL_VERSION,
        messageId: randomUUID(),
        machineId: this.config.machineId,
        deviceId: targetDeviceId,
        sequence: this.sequence,
        timestamp: Date.now(),
        type: "protocol.error",
        payload: {
          code: "replay-window-exceeded",
          message: "Some offline events expired; reopen the session to resynchronize.",
          retryable: true,
        },
      }, targetDeviceId);
      return;
    }
    for (const event of this.recentEvents) {
      // Catalogs and snapshots are request-scoped, not durable live events.
      // Replaying another device's old result corrupts an in-flight refresh
      // (and can reintroduce archived rows). The resume path immediately
      // requests a fresh authoritative snapshot instead.
      if (event.type === "session.snapshot" || event.type === "workspace.catalog"
          || event.type === "workspace.created" || event.type === "mode.catalog"
          || event.type === "directory.list") continue;
      if (event.deviceId !== "broadcast" && event.deviceId !== targetDeviceId) continue;
      if (event.sequence > lastSequence) this.sendRelayEvent(event, targetDeviceId);
    }
  }

  private queueEvent(event: EventEnvelope): void {
    const bytes = eventBytes(event);
    while (this.pendingEvents.length > 0 &&
      (this.pendingEvents.length >= MAX_PENDING_EVENTS || this.pendingEventBytes + bytes > MAX_PENDING_BYTES)) {
      this.pendingEventsDropped = true;
      this.pendingEventBytes -= eventBytes(this.pendingEvents.shift()!);
    }
    if (bytes > MAX_PENDING_BYTES) {
      this.pendingEventsDropped = true;
      return;
    }
    this.pendingEvents.push(event);
    this.pendingEventBytes += bytes;
  }

  private flushPendingEvents(): void {
    if (this.relay === undefined || this.relay.readyState !== WebSocket.OPEN) return;
    const pending = this.pendingEvents.splice(0);
    const dropped = this.pendingEventsDropped;
    this.pendingEventBytes = 0;
    this.pendingEventsDropped = false;
    for (const event of pending) {
      this.sendRelayEvent(event, event.deviceId === "broadcast" ? undefined : event.deviceId);
    }
    if (dropped) {
      this.sendEvent({
        version: PROTOCOL_VERSION,
        messageId: randomUUID(),
        machineId: this.config.machineId,
        deviceId: "broadcast",
        sequence: this.sequence,
        timestamp: Date.now(),
        type: "protocol.error",
        payload: {
          code: "offline-queue-exceeded",
          message: "Some offline events expired; reopen active sessions to resynchronize.",
          retryable: true,
        },
      });
    }
  }

  /**
   * Keeps a live single-use code available to the local pairing page, refreshed
   * well inside the relay's code lifetime so the page never shows something
   * already dead.
   *
   * A relay that predates the endpoint, or a transient failure, is logged and
   * ignored: pairing must not depend on this, and the page falls back to the
   * long-lived secret.
   */
  private startPairingCodeRefresh(): void {
    if (this.pairingCodePath === undefined) return;
    void this.refreshPairingCode();
    this.pairingCodeTimer = setInterval(() => void this.refreshPairingCode(), PAIRING_CODE_REFRESH_MS);
  }

  private async refreshPairingCode(): Promise<void> {
    const path = this.pairingCodePath;
    if (path === undefined || !this.running) return;
    try {
      const issued = await requestPairingCode(this.config, this.request);
      await writePairingCodeFile(path, { machineId: this.config.machineId, ...issued });
    } catch (error) {
      this.log("warn", `Could not publish a one-time pairing code: ${safeError(error, this.config)}`);
    }
  }

  private stopPairingCodeRefresh(): void {
    if (this.pairingCodeTimer !== undefined) clearInterval(this.pairingCodeTimer);
    this.pairingCodeTimer = undefined;
  }

  private startHeartbeat(socket: WebSocketLike): void {
    this.stopHeartbeat();
    this.awaitingPong = false;
    this.heartbeatTimer = setInterval(() => {
      if (this.relay !== socket || !this.running) return;
      if (this.awaitingPong) {
        socket.terminate?.();
        return;
      }
      this.awaitingPong = true;
      socket.ping?.();
    }, this.heartbeatMs);
  }

  private stopHeartbeat(): void {
    if (this.heartbeatTimer !== undefined) clearInterval(this.heartbeatTimer);
    this.heartbeatTimer = undefined;
    this.awaitingPong = false;
  }

  private scheduleRelayReconnect(): void {
    if (this.relayTimer !== undefined) return;
    this.state = "reconnecting";
    const delay = backoffDelay(++this.relayAttempts, this.reconnectBaseMs, this.reconnectMaxMs);
    this.log("info", `Relay disconnected; reconnecting in ${delay}ms`);
    this.relayTimer = setTimeout(() => {
      this.relayTimer = undefined;
      this.connectRelay();
    }, delay);
  }

  private scheduleBridgeReconnect(): void {
    if (this.bridgeTimer !== undefined) return;
    const delay = backoffDelay(++this.bridgeAttempts, this.reconnectBaseMs, this.reconnectMaxMs);
    this.log("info", `Local DSH bridge disconnected; reconnecting in ${delay}ms`);
    this.bridgeTimer = setTimeout(() => {
      this.bridgeTimer = undefined;
      this.connectBridge();
    }, delay);
  }

  private clearTimers(): void {
    if (this.relayTimer !== undefined) clearTimeout(this.relayTimer);
    if (this.bridgeTimer !== undefined) clearTimeout(this.bridgeTimer);
    this.relayTimer = undefined;
    this.bridgeTimer = undefined;
    this.stopHeartbeat();
    this.stopPairingCodeRefresh();
  }

  private log(level: keyof Logger, message: string): void {
    this.logger[level](redactSecrets(message, this.config));
  }
}

export function bridgeRequestFor(command: CommandEnvelope): BridgeRequest {
  switch (command.type) {
    case "connection.resume":
      throw new UnsupportedCommandError(command.type);
    case "session.list":
      return {
        method: "GET",
        path: `${command.payload.includeArchived === true ? "/sessions?includeArchived=true&" : "/sessions?"}deviceId=${encodeURIComponent(command.deviceId)}`,
      };
    case "session.open":
      return {
        method: "POST",
        path: `/sessions/${encodeURIComponent(requireSessionId(command))}/open`,
        body: { deviceId: command.deviceId },
      };
    case "session.create":
      return {
        method: "POST",
        path: "/sessions",
        headers: { "x-dsh-origin-device-id": command.deviceId },
        body: {
          deviceId: command.deviceId,
          ...(command.payload.title === undefined ? {} : { title: command.payload.title }),
          ...(command.payload.workingDirectory === undefined ? {} : { cwd: command.payload.workingDirectory }),
          ...(command.payload.workspaceId === undefined ? {} : { workspaceId: command.payload.workspaceId }),
          ...(command.payload.agentPreset === undefined ? {} : { agentPreset: command.payload.agentPreset }),
          ...(command.payload.model === undefined ? {} : { model: command.payload.model }),
          ...(command.payload.branch === undefined ? {} : { branch: command.payload.branch }),
          ...(command.payload.permissionMode === undefined ? {} : { permissionMode: command.payload.permissionMode }),
        },
      };
    case "prompt.send":
      return {
        method: "POST",
        path: `/sessions/${encodeURIComponent(requireSessionId(command))}/prompt`,
        body: {
          ...(command.payload.text === undefined ? {} : { text: command.payload.text }),
          ...(command.payload.content === undefined ? {} : { content: command.payload.content }),
          ...(command.payload.attachments === undefined ? {} : { attachments: command.payload.attachments }),
          ...(command.payload.mode === undefined ? {} : { mode: command.payload.mode }),
          ...(command.payload.clientTimeZone === undefined ? {} : { clientTimeZone: command.payload.clientTimeZone }),
          deviceId: command.deviceId,
          requestId: command.requestId,
        },
      };
    case "turn.cancel":
      return { method: "POST", path: `/sessions/${encodeURIComponent(requireSessionId(command))}/cancel`, body: {} };
    case "approval.decide":
      return {
        method: "POST",
        path: `/approvals/${encodeURIComponent(command.payload.approvalId)}/decision`,
        body: { decision: command.payload.allow ? "allowed-once" : "rejected" },
      };
    case "question.answer":
      return {
        method: "POST",
        path: `/questions/${encodeURIComponent(command.payload.questionId)}/answer`,
        body: { answers: command.payload.answers },
      };
    case "session.archive":
      return {
        method: "POST",
        path: `/sessions/${encodeURIComponent(requireSessionId(command))}/archive`,
        body: { archived: command.payload.archived },
      };
    case "session.model":
      return {
        method: "POST",
        path: `/sessions/${encodeURIComponent(requireSessionId(command))}/model`,
        body: command.payload,
      };
    case "workspace.rename":
      return {
        method: "POST",
        path: `/workspaces/${encodeURIComponent(command.payload.workspaceId)}/rename`,
        body: { title: command.payload.title },
      };
    case "workspace.delete":
      return {
        method: "POST",
        path: `/workspaces/${encodeURIComponent(command.payload.workspaceId)}/delete`,
        body: {},
      };
    case "workspace.catalog":
      return { method: "GET", path: "/workspaces" };
    case "workspace.create":
      return { method: "POST", path: "/workspaces", body: command.payload };
    case "directory.list": {
      const encoded = command.payload.path === undefined ? "" : `?path=${encodeURIComponent(command.payload.path)}`;
      return { method: "GET", path: `/directories${encoded}` };
    }
    case "mode.catalog":
      return { method: "GET", path: "/modes" };
    case "session.rename":
      return {
        method: "POST",
        path: `/sessions/${encodeURIComponent(requireSessionId(command))}/rename`,
        body: command.payload,
      };
    case "model.catalog":
      return { method: "GET", path: "/models" };
    case "command.execute":
      return {
        method: "POST",
        path: `/sessions/${encodeURIComponent(requireSessionId(command))}/command`,
        body: { line: command.payload.line, ...(command.payload.attachments === undefined ? {} : { attachments: command.payload.attachments }) },
      };
    case "permission.set":
      return {
        method: "POST",
        path: `/sessions/${encodeURIComponent(requireSessionId(command))}/permission`,
        body: { mode: command.payload.mode },
      };
    case "attachment.upload":
      return {
        method: "POST",
        path: `/sessions/${encodeURIComponent(requireSessionId(command))}/attachments`,
        body: command.payload,
      };
    default:
      throw new UnsupportedCommandError(command.type);
  }
}

export function bridgeTimeoutFor(command: CommandEnvelope): number {
  switch (command.type) {
    // These Bridge paths may legitimately await Harness work for up to 120s.
    // The Connector stays slightly outside that deadline so a locally accepted
    // operation cannot be reported as failed while it is still executing.
    case "session.create":
    case "session.open":
    case "command.execute":
    case "permission.set":
    case "attachment.upload":
    case "workspace.create":
    case "workspace.delete":
      return LONG_BRIDGE_TIMEOUT_MS;
    default:
      return 15_000;
  }
}

export function relayConnectURL(relayURL: string): string {
  return new URL("v1/connect", trailingSlash(relayURL)).toString();
}

export function bridgeEventsURL(bridgeBaseURL: string, connectorInstanceId?: string,
                                afterSequence = 0): string {
  const url = new URL("events", trailingSlash(bridgeBaseURL));
  url.protocol = url.protocol === "https:" ? "wss:" : "ws:";
  if (connectorInstanceId !== undefined) url.searchParams.set("connectorId", connectorInstanceId);
  if (afterSequence > 0) url.searchParams.set("after", String(afterSequence));
  return url.toString();
}

export function bridgeAPIURL(bridgeBaseURL: string, path: string): string {
  return new URL(path.replace(/^\//, ""), trailingSlash(bridgeBaseURL)).toString();
}

export function backoffDelay(attempt: number, baseMs = 500, maxMs = 30_000): number {
  const capped = Math.min(20, Math.max(1, attempt));
  return Math.min(maxMs, baseMs * 2 ** (capped - 1));
}

class BridgeRequestError extends Error {
  constructor(
    readonly status: number,
    message = `HTTP ${status}`,
    readonly outcome: "retryable" | "unknown" | undefined = undefined,
  ) {
    super(message);
  }
}

class UnsupportedCommandError extends Error {
  constructor(command: string) {
    super(`unsupported command: ${command}`);
  }
}

function defaultWebSocketFactory(url: string, headers: Readonly<Record<string, string>>): WebSocketLike {
  return new WebSocket(url, { headers }) as unknown as WebSocketLike;
}

function authorization(token: string): Readonly<Record<string, string>> {
  return { authorization: `Bearer ${token}` };
}

function parseJson(raw: RawData): unknown {
  try {
    return JSON.parse(Buffer.isBuffer(raw) ? raw.toString("utf8") : String(raw));
  } catch {
    return undefined;
  }
}

function eventBytes(event: EventEnvelope): number {
  return Buffer.byteLength(JSON.stringify(event));
}

function commandKey(machineId: string, deviceId: string, requestId: string): string {
  return `${machineId}\u0000${deviceId}\u0000${requestId}`;
}

function isSessionProjectionMutation(command: CommandEnvelope): boolean {
  return command.type === "session.archive" || command.type === "session.model"
    || command.type === "permission.set" || command.type === "workspace.rename"
    || command.type === "workspace.delete" || command.type === "session.rename";
}

function trailingSlash(value: string): string {
  return value.endsWith("/") ? value : `${value}/`;
}

function requireSessionId(command: CommandEnvelope): string {
  if (command.sessionId === undefined) throw new UnsupportedCommandError(`${command.type} without sessionId`);
  return command.sessionId;
}

function asRecord(value: unknown): Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value) ? value as Record<string, unknown> : {};
}

function isRetryable(error: unknown): boolean {
  if (!(error instanceof BridgeRequestError)) return true;
  if (error.outcome !== undefined) return error.outcome === "retryable";
  return error.status >= 500;
}

function safeError(error: unknown, config: ConnectorConfig): string {
  return redactSecrets(error instanceof Error ? error.message : String(error), config);
}

/** Device IDs are diagnostics, not secrets; still avoid writing full IDs to logs. */
function shortID(value: string): string {
  return value.length <= 8 ? value : `…${value.slice(-8)}`;
}

const consoleLogger: Logger = {
  info: (message) => console.log(`[dsh-anywhere] ${message}`),
  warn: (message) => console.warn(`[dsh-anywhere] ${message}`),
};
