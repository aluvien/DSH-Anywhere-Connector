import { createHash, randomUUID } from "node:crypto";
import { FeedbackStateSchema, FeedbackUpdatedSchema, ReferenceCandidatesSchema, SearchResultsSchema, HistoryPageSchema, ScheduleProjectionSchema, ConfigurationModelsSchema, ConfigurationResultSchema, ConfigurationUpdatedSchema, CommandEnvelopeSchema, AttachmentUploadedPayloadSchema, CommandResultPayloadSchema, CommandCatalogPayloadSchema, SubagentCatalogPayloadSchema, GoalChangedPayloadSchema, GoalUpdatedPayloadSchema, DecisionsSnapshotPayloadSchema, EventEnvelopeSchema, ModelCatalogPayloadSchema, ModeCatalogPayloadSchema, PromptAcceptedPayloadSchema, PROTOCOL_VERSION, SCHEMA_REVISION, supportsSchemaRevision, RelayMessageSchema, RelayPayloadMessageSchema, SessionSummarySchema, WorkspaceCatalogPayloadSchema, WorkspaceSchema, DirectoryListPayloadSchema, WorkspaceFilesPayloadSchema, WorkspaceBytesPayloadSchema, ExecutionPagePayloadSchema, } from "../protocol/index.js";
import WebSocket, {} from "ws";
import { redactSecrets } from "./config.js";
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
/** A durable reasoning record belongs to every client. Only the temporary
 * stream-id form is private to a device that opted into live output. */
function isTransientStreamingEvent(event) {
    return event.type === "assistant.message.delta"
        || event.type === "assistant.message.discarded"
        || (event.type === "assistant.reasoning" && event.payload.messageId.startsWith("stream-"));
}
/**
 * Keeps the public Relay connection and the local DSH bridge deliberately separate.
 * The Connector only ever opens outbound connections; no local port is exposed.
 */
export class DSHAnywhereConnector {
    config;
    /** A new Bridge socket gets a new lease identity.  Presence requests from a
     * dead socket must not be mistaken for requests from its replacement. */
    bridgeConnectorId;
    bridgeConnectGeneration = 0;
    resolveBridgeBaseURL;
    /** Server-issued monotonic lease for the current Relay machine socket. */
    relayLeaseGeneration;
    relayEpoch;
    /** Last Bridge event cursor acknowledged by this Connector. */
    bridgeAfterSequence = 0;
    /** Identifies the Bridge process that owns the replay cursor. */
    bridgeEpoch;
    /** Bridge replays events before its ready envelope; hold them until the
     * epoch/cursor contract has been checked. */
    relayVerified = false;
    relayHandshakeTimer;
    bridgeReady = false;
    bridgeBufferedEvents = [];
    relay;
    bridge;
    relayTimer;
    bridgeTimer;
    heartbeatTimer;
    pairingCodeTimer;
    pairingCodePath;
    awaitingPong = false;
    relayAttempts = 0;
    bridgeAttempts = 0;
    // Seeded from the clock, not zero: the counter is what the phone orders its
    // transcript by and what `replayAfter` filters on, and the device remembers
    // the last value it saw. Restarting the connector used to reset it to 1, so
    // every new event sorted as "oldest" *and* fell below the device's remembered
    // sequence — new output arrived out of order, or was dropped entirely.
    sequence = Date.now();
    running = false;
    state = "stopped";
    pendingEvents = [];
    recentEvents = [];
    pendingEventBytes = 0;
    recentEventBytes = 0;
    pendingEventsDropped = false;
    /** Each device's archive view is a query choice, never a global cache. */
    includeArchivedByDevice = new Map();
    /** Monotonic query generations prevent a slow presence refresh from
     * overwriting a newer archive/filter selection on the same device. */
    sessionSnapshotGenerationByDevice = new Map();
    /** Explicit list requests must not be silently superseded by an automatic
     * refresh. Defer that refresh until the caller's pending request settles. */
    pendingSessionListRequests = new Map();
    /** The most recent explicit list identity remains after its response settles
     * so a late duplicate cannot change the device's archive preference. */
    latestSessionListCommands = new Map();
    /** A request superseded by a newer explicit list remains a tombstone for
     * the dedupe window. Without this, the first retry can be rejected and a
     * second delivery of the same request id can re-enter as a fresh query. */
    supersededSessionListRequests = new Map();
    /** Workspace catalogs are an independent projection from session lists.
     * A mutation push or a later explicit request must fence a slower catalog
     * response, without changing the archive-list generation above. */
    workspaceCatalogGenerationByDevice = new Map();
    latestWorkspaceCatalogCommands = new Map();
    supersededWorkspaceCatalogRequests = new Map();
    deferredSessionSnapshotDevices = new Set();
    /** Workspace mutations and session projections are separate resources. A
     * stale session query must not suppress the catalog refresh that follows a
     * successful workspace rename/delete. */
    deferredWorkspaceCatalogDevices = new Set();
    /** Mutation-triggered refreshes remain authoritative until their own
     * post-mutation read has settled. A list request that starts in the middle
     * of that window must receive one more refresh afterwards. */
    inFlightSessionMutations = new Map();
    /** Devices explicitly opted in to transient output for one open session.
     * This state belongs to the Connector (which knows device identity), not the
     * Bridge (which has one trusted Connector socket). */
    streamingDevicesBySession = new Map();
    /** Coalesces duplicate Relay delivery/retry by the caller's stable id. */
    commandExecutions = new Map();
    /** Keeps correlated results for the same lifetime as command dedupe. A
     * replay receives a fresh transport sequence so iOS does not discard it as
     * an old event after a reconnect. */
    commandResults = new Map();
    onlineRelayDevices = new Set();
    presenceUpdates = new Map();
    presenceRefreshRequired = new Set();
    /** Serializes Bridge-side effects for one Relay device. In particular, an
     * offline edge must not overtake a presence-authenticated create/upload that
     * Relay delivered just before it. */
    deviceBridgeOperations = new Map();
    /** Every presence-authenticated operation started for a device must stay
     * fenced until it settles. Keeping only the latest Promise lets an earlier
     * request outlive the map entry and be overtaken by an offline edge. */
    devicePresenceOperations = new Map();
    webSocketFactory;
    request;
    logger;
    reconnectBaseMs;
    reconnectMaxMs;
    heartbeatMs;
    constructor(config, dependencies = {}) {
        this.config = config;
        this.webSocketFactory = dependencies.webSocketFactory ?? defaultWebSocketFactory;
        this.request = dependencies.fetch ?? fetch;
        this.logger = dependencies.logger ?? consoleLogger;
        this.reconnectBaseMs = dependencies.reconnectBaseMs ?? 500;
        this.reconnectMaxMs = dependencies.reconnectMaxMs ?? 30_000;
        this.heartbeatMs = dependencies.heartbeatMs ?? 25_000;
        this.pairingCodePath = dependencies.pairingCodePath;
        this.resolveBridgeBaseURL = dependencies.resolveBridgeBaseURL;
    }
    get status() {
        return this.state;
    }
    get bridgeConnected() {
        return this.relayVerified && this.bridge !== undefined && this.bridgeReady;
    }
    start() {
        if (this.running)
            return;
        this.running = true;
        this.state = "connecting";
        this.connectRelay();
        this.connectBridge();
        this.startPairingCodeRefresh();
    }
    async stop() {
        ++this.bridgeConnectGeneration;
        this.running = false;
        this.state = "stopped";
        this.clearTimers();
        this.relay?.close(1000, "connector stopped");
        this.bridge?.close(1000, "connector stopped");
        this.relay = undefined;
        this.relayVerified = false;
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
        this.presenceRefreshRequired.clear();
        this.deviceBridgeOperations.clear();
        this.devicePresenceOperations.clear();
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
    connectRelay() {
        if (!this.running)
            return;
        this.state = this.relayAttempts === 0 ? "connecting" : "reconnecting";
        this.relayVerified = false;
        const socket = this.webSocketFactory(relayConnectURL(this.config.relayURL), authorization(this.config.machineToken));
        this.relay = socket;
        socket.on("open", () => {
            if (this.relay !== socket || !this.running)
                return;
            this.startHeartbeat(socket);
            this.clearRelayHandshakeTimer();
            this.relayHandshakeTimer = setTimeout(() => {
                if (this.relay === socket && !this.relayVerified)
                    this.rejectRelaySchema(socket);
            }, 10_000);
            this.relayHandshakeTimer.unref?.();
        });
        socket.on("message", (raw) => this.onRelayMessage(socket, raw));
        socket.on("pong", () => {
            if (this.relay === socket)
                this.awaitingPong = false;
        });
        socket.on("error", (error) => this.log("warn", `Relay socket error: ${safeError(error, this.config)}`));
        socket.on("close", (code) => {
            if (this.relay !== socket)
                return;
            this.stopHeartbeat();
            this.clearRelayHandshakeTimer();
            this.relayVerified = false;
            this.relay = undefined;
            const relayGeneration = this.relayLeaseGeneration;
            const relayEpoch = this.relayEpoch;
            const bridgeConnectorId = this.bridgeConnectorId;
            this.relayLeaseGeneration = undefined;
            this.relayEpoch = undefined;
            const disconnectedDevices = [...this.onlineRelayDevices];
            this.onlineRelayDevices.clear();
            this.presenceRefreshRequired.clear();
            for (const deviceId of disconnectedDevices) {
                void this.enqueuePresenceUpdate(deviceId, false, bridgeConnectorId, relayGeneration, relayEpoch);
            }
            if (code === 4001) {
                // Relay uses 4001 when another Connector with the same machine lease
                // takes over. Reconnecting here would make two processes continuously
                // evict one another and would flap every remote-device presence edge.
                this.log("warn", "Relay connection was superseded by another Connector; stopping this instance");
                void this.stop();
                return;
            }
            if (this.running)
                this.scheduleRelayReconnect();
        });
    }
    connectBridge() {
        if (!this.running)
            return;
        const generation = ++this.bridgeConnectGeneration;
        if (this.resolveBridgeBaseURL === undefined) {
            this.openBridge(this.config.bridgeBaseURL);
            return;
        }
        void Promise.resolve().then(() => this.resolveBridgeBaseURL()).then(baseURL => {
            if (this.running && generation === this.bridgeConnectGeneration)
                this.openBridge(baseURL);
        }).catch(error => {
            if (!this.running || generation !== this.bridgeConnectGeneration)
                return;
            this.log("warn", `Could not resolve local Bridge endpoint: ${safeError(error, this.config)}`);
            this.scheduleBridgeReconnect();
        });
    }
    openBridge(baseURL) {
        if (!this.running)
            return;
        const connectorId = randomUUID();
        this.bridgeConnectorId = connectorId;
        this.bridgeReady = false;
        this.bridgeBufferedEvents = [];
        const socket = this.webSocketFactory(bridgeEventsURL(baseURL, connectorId, this.bridgeAfterSequence), { ...authorization(this.config.bridgeToken), "x-dsh-schema-revision": String(SCHEMA_REVISION) });
        this.bridge = socket;
        socket.on("open", () => {
            if (this.bridge !== socket || !this.running)
                return;
            this.bridgeAttempts = 0;
            this.log("info", "Local DSH bridge connected");
            for (const deviceId of this.onlineRelayDevices) {
                void this.enqueuePresenceUpdate(deviceId, true, connectorId, this.relayLeaseGeneration, this.relayEpoch);
                // A Bridge greeting may contain a snapshot from before the Relay or
                // Bridge reconnect. Refresh every currently-online device from the
                // authoritative HTTP list instead of forwarding that stale greeting.
                void this.pushSessionSnapshot(deviceId);
            }
        });
        socket.on("message", (raw) => this.onBridgeMessage(socket, raw));
        socket.on("error", (error) => this.log("warn", `Bridge socket error: ${safeError(error, this.config)}`));
        socket.on("close", () => {
            if (this.bridge !== socket)
                return;
            this.bridge = undefined;
            ++this.bridgeConnectGeneration;
            if (this.bridgeConnectorId === connectorId)
                this.bridgeConnectorId = undefined;
            // Bridge removes every presence lease owned by a disconnected socket.
            // Keep the Relay-online set, but fence all session.create delivery until
            // the replacement socket has installed a fresh lease.  Without this
            // marker a command arriving in the reconnect window is forwarded to
            // HTTP and receives a final origin-device 403.
            for (const deviceId of this.onlineRelayDevices) {
                this.presenceRefreshRequired.add(deviceId);
            }
            if (this.running)
                this.scheduleBridgeReconnect();
        });
    }
    onBridgeMessage(socket, raw) {
        if (socket !== this.bridge || !this.running)
            return;
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
            if (nextEpoch !== undefined)
                this.bridgeEpoch = nextEpoch;
            if (event.data.sequence > this.bridgeAfterSequence)
                this.bridgeAfterSequence = event.data.sequence;
            this.bridgeReady = true;
            const buffered = this.bridgeBufferedEvents;
            this.bridgeBufferedEvents = [];
            for (const bufferedEvent of buffered)
                this.handleBridgeEvent(bufferedEvent);
            // Forward the handshake that authorized this socket after any retained
            // replay entries, preserving the legacy phone-visible ready signal. The
            // Bridge epoch and socket id are local replay-control metadata; strip
            // them before forwarding so an older Relay can still validate the public
            // event schema.
            const { bridgeEpoch: _bridgeEpoch, bridgeConnectionId: _bridgeConnectionId, replayTruncated: _replayTruncated, ...publicReadyPayload } = event.data.payload;
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
    handleBridgeEvent(event) {
        if (event.sequence > this.bridgeAfterSequence)
            this.bridgeAfterSequence = event.sequence;
        if (event.type === "connection.ready")
            return;
        // The bridge socket is owned by the connector, not by one phone. Its
        // connection greeting includes an unfiltered session snapshot which can
        // race a device's current archive/list query and replace the UI with an
        // old projection. Lists travel through correlated HTTP commands below;
        // retain live created/title events but never forward this bridge greeting.
        if (event.type === "session.snapshot")
            return;
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
    onRelayMessage(socket, raw) {
        if (socket !== this.relay || !this.running)
            return;
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
            if (message.data.machineId !== this.config.machineId || message.data.role !== "machine" || !supportsSchemaRevision(message.data.schemaRevision)) {
                this.rejectRelaySchema(socket);
                return;
            }
            this.clearRelayHandshakeTimer();
            this.relayVerified = true;
            this.relayAttempts = 0;
            this.state = "connected";
            this.flushPendingEvents();
            this.log("info", `Relay schema ${message.data.schemaRevision} verified`);
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
                void this.enqueuePresenceUpdate(deviceId, true, this.bridgeConnectorId, this.relayLeaseGeneration, this.relayEpoch);
            }
            return;
        }
        if (!this.relayVerified)
            return;
        if (message.data.type === "relay.presence") {
            if (message.data.role === "device" && message.data.deviceId !== undefined) {
                if (message.data.online)
                    this.onlineRelayDevices.add(message.data.deviceId);
                else
                    this.onlineRelayDevices.delete(message.data.deviceId);
                void this.enqueuePresenceUpdate(message.data.deviceId, message.data.online, this.bridgeConnectorId, this.relayLeaseGeneration, this.relayEpoch);
                if (message.data.online)
                    void this.pushSessionSnapshot(message.data.deviceId);
            }
            return;
        }
        if (message.data.type !== "relay.payload" || message.data.sender !== "device")
            return;
        const command = CommandEnvelopeSchema.safeParse(message.data.body);
        if (!command.success || command.data.machineId !== this.config.machineId) {
            this.log("warn", "Ignored invalid command from Relay");
            return;
        }
        this.log("info", `Received ${command.data.type} from device ${shortID(command.data.deviceId)}`);
        // Session creation and attachment upload are authenticated by the
        // Bridge-local presence lease. Keep both in the same per-device operation
        // chain as presence edges: an offline edge delivered immediately
        // afterwards must wait until the request has reached the Bridge, otherwise
        // the Bridge can delete the lease first and turn a valid request into a
        // final 403.
        if (requiresDevicePresence(command.data)) {
            const start = () => {
                const completion = this.dispatchCommand(command.data);
                const operations = this.devicePresenceOperations.get(command.data.deviceId) ?? new Set();
                operations.add(completion);
                this.devicePresenceOperations.set(command.data.deviceId, operations);
                void completion.finally(() => {
                    const current = this.devicePresenceOperations.get(command.data.deviceId);
                    if (!current)
                        return;
                    current.delete(completion);
                    if (current.size === 0)
                        this.devicePresenceOperations.delete(command.data.deviceId);
                });
            };
            // Preserve the normal synchronous dispatch timing when no presence
            // refresh is pending. The completion is still tracked for a following
            // offline edge, while duplicate deliveries coalesce immediately.
            if (!this.presenceUpdates.has(command.data.deviceId) &&
                !this.presenceRefreshRequired.has(command.data.deviceId)) {
                start();
                return;
            }
            void this.enqueueDeviceBridgeOperation(command.data.deviceId, async () => {
                if (this.relay !== socket || !this.running)
                    return;
                const presenceUpdate = this.presenceUpdates.get(command.data.deviceId)
                    ?? (this.presenceRefreshRequired.has(command.data.deviceId)
                        ? this.reportDevicePresence(command.data.deviceId, true, this.bridgeConnectorId, this.relayLeaseGeneration, this.relayEpoch)
                        : undefined);
                if (presenceUpdate !== undefined && !await presenceUpdate) {
                    this.sendProtocolError(command.data, new BridgeRequestError(503, "Relay device presence is not registered with the local bridge", "retryable"));
                    return;
                }
                start();
            });
            return;
        }
        void this.dispatchCommand(command.data);
    }
    dispatchCommand(command) {
        // File pages are repeatable reads, scoped to an active phone waiter. Do
        // not retain their bytes in mutation/result caches or chat replay history.
        if (command.type === "workspace.files" || command.type === "workspace.bytes" || command.type === "execution.list" || command.type === "feedback.list" || command.type === "reference.list" || command.type === "session.search" || command.type === "conversation.search" || command.type === "history.read" || command.type === "schedule.get" || command.type === "configuration.read" || command.type === "configuration.update" || command.type === "configuration.discover") {
            return this.executeCommand(command).then(() => undefined);
        }
        const now = Date.now();
        for (const [key, execution] of this.commandExecutions) {
            if (execution.expiresAt <= now)
                this.commandExecutions.delete(key);
        }
        for (const [key, result] of this.commandResults) {
            if (result.expiresAt <= now && !this.commandExecutions.has(key))
                this.commandResults.delete(key);
        }
        for (const [key, expiresAt] of this.supersededSessionListRequests) {
            if (expiresAt <= now)
                this.supersededSessionListRequests.delete(key);
        }
        for (const [key, expiresAt] of this.supersededWorkspaceCatalogRequests) {
            if (expiresAt <= now)
                this.supersededWorkspaceCatalogRequests.delete(key);
        }
        // A superseded request id remains a tombstone for the whole dedupe
        // window. This covers the internal retry path and repeated deliveries
        // after the first superseded response has already been sent.
        if (command.type === "session.list" && this.isSupersededSessionList(command)) {
            this.sendSupersededSessionList(command);
            return Promise.resolve();
        }
        if (command.type === "workspace.catalog" && this.isSupersededWorkspaceCatalog(command)) {
            this.sendSupersededWorkspaceCatalog(command);
            return Promise.resolve();
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
            return existing.promise.then((outcome) => {
                if (this.commandExecutions.get(key) !== existing)
                    return;
                if (outcome.state === "failed" && outcome.retryable) {
                    this.commandExecutions.delete(key);
                    this.commandResults.delete(key);
                    return this.dispatchCommand(command);
                }
                else {
                    this.replayCommandResult(command);
                }
            });
        }
        this.commandResults.delete(key);
        const promise = this.executeCommand(command);
        this.commandExecutions.set(key, { promise, expiresAt: now + COMMAND_DEDUP_TTL_MS, events: [] });
        void promise;
        return promise.then(() => undefined);
    }
    async executeCommand(command) {
        let sessionSnapshotGeneration;
        let workspaceCatalogGeneration;
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
                this.rememberLatestSessionListCommand(command.deviceId, command.requestId, sessionSnapshotGeneration, includeArchived);
                if (this.inFlightSessionMutations.has(command.deviceId)) {
                    this.deferredSessionSnapshotDevices.add(command.deviceId);
                }
                this.pendingSessionListRequests.set(command.deviceId, {
                    requestId: command.requestId,
                    generation: sessionSnapshotGeneration,
                });
            }
            if (command.type === "session.open") {
                this.setStreamingPreference(command.sessionId ?? command.payload.sessionId, command.deviceId, command.payload.streaming === true);
            }
            const request = bridgeRequestFor(command);
            // A photo can be several megabytes after base64 encoding. Keep normal
            // commands snappy, but give the local Harness upload service enough time
            // to download, decode, and persist a large attachment.
            const response = await this.callBridge(request, bridgeTimeoutFor(command), command.requestId);
            await this.emitCommandResult(command, response, sessionSnapshotGeneration, workspaceCatalogGeneration);
            return { state: "completed" };
        }
        catch (error) {
            if (command.type === "decisions.list" && error instanceof BridgeRequestError &&
                (error.status === 404 || error.status === 501))
                return { state: "completed" };
            if (command.type === "subagent.catalog" && error instanceof BridgeRequestError &&
                (error.status === 404 || error.status === 501)) {
                await this.emitCommandResult(command, { parentSessionId: requireSessionId(command), parentAvailable: false, supported: false, entries: [] });
                return { state: "completed" };
            }
            if (command.type === "command.catalog" && error instanceof BridgeRequestError &&
                (error.status === 404 || error.status === 501)) {
                await this.emitCommandResult(command, { sessionId: requireSessionId(command), supported: false, commands: [] });
                return { state: "completed" };
            }
            const staleSessionList = command.type === "session.list" &&
                sessionSnapshotGeneration !== undefined &&
                !this.isCurrentSessionSnapshotQuery(command.deviceId, sessionSnapshotGeneration);
            const staleWorkspaceCatalog = command.type === "workspace.catalog" &&
                workspaceCatalogGeneration !== undefined &&
                !this.isCurrentWorkspaceCatalogQuery(command.deviceId, workspaceCatalogGeneration);
            if (command.type === "session.list")
                this.finishSessionListRequest(command, undefined);
            // A newer request (or an automatic authoritative push) owns the current
            // projection. Do not surface the older timeout as a user error or retry
            // it into an outdated archive/catalog response.
            if (staleSessionList || staleWorkspaceCatalog)
                return { state: "completed" };
            const retryable = this.sendProtocolError(command, error);
            if (command.type === "session.list")
                this.flushDeferredSessionSnapshot(command.deviceId);
            return { state: "failed", retryable };
        }
    }
    async callBridge(request, timeoutMs = 15_000, idempotencyKey) {
        const encodedBody = request.body === undefined ? undefined : JSON.stringify(request.body);
        const bodyHash = encodedBody === undefined
            ? undefined
            : createHash("sha256").update(encodedBody).digest("hex");
        const signal = AbortSignal.timeout(timeoutMs);
        const generation = this.bridgeConnectGeneration;
        const baseURL = this.resolveBridgeBaseURL === undefined
            ? this.config.bridgeBaseURL : await this.resolveBridgeBaseURL();
        signal.throwIfAborted();
        if (!this.running || generation !== this.bridgeConnectGeneration)
            throw new Error("Bridge connection changed before request dispatch");
        const response = await this.request(bridgeAPIURL(baseURL, request.path), {
            method: request.method,
            headers: {
                ...authorization(this.config.bridgeToken),
                "x-dsh-schema-revision": String(SCHEMA_REVISION),
                ...request.headers,
                ...(idempotencyKey === undefined ? {} : { "x-dsh-request-id": idempotencyKey }),
                ...(encodedBody === undefined ? {} : {
                    "content-type": "application/json",
                    "x-dsh-request-hash": bodyHash,
                }),
            },
            ...(encodedBody === undefined ? {} : { body: encodedBody }),
            signal,
        });
        if (!response.ok) {
            const outcomeHeader = response.headers.get("x-dsh-idempotency-outcome");
            const outcome = request.method === "GET" ? undefined : outcomeHeader === "retryable" || outcomeHeader === "retryable-committed"
                || outcomeHeader === "retryable-durable" || outcomeHeader === "unknown"
                ? outcomeHeader : undefined;
            throw new BridgeRequestError(response.status, `HTTP ${response.status}`, outcome);
        }
        const contentType = response.headers.get("content-type") ?? "";
        return contentType.includes("application/json") ? response.json() : undefined;
    }
    enqueueDeviceBridgeOperation(deviceId, operation) {
        const previous = this.deviceBridgeOperations.get(deviceId) ?? Promise.resolve();
        const next = previous.catch(() => undefined).then(operation);
        const settled = next.then(() => undefined, () => undefined);
        this.deviceBridgeOperations.set(deviceId, settled);
        void settled.finally(() => {
            if (this.deviceBridgeOperations.get(deviceId) === settled) {
                this.deviceBridgeOperations.delete(deviceId);
            }
        });
        return next;
    }
    enqueuePresenceUpdate(deviceId, online, connectorId = this.bridgeConnectorId, relayGeneration = this.relayLeaseGeneration, relayEpoch = this.relayEpoch) {
        return this.enqueueDeviceBridgeOperation(deviceId, async () => {
            // Relay sends the device-offline edge after any payload already routed
            // to the machine socket. Wait for a preceding create to finish its
            // Bridge request before deleting the origin lease.
            if (!online) {
                const activeOperations = [...(this.devicePresenceOperations.get(deviceId) ?? [])];
                await Promise.all(activeOperations.map((operation) => operation.catch(() => undefined)));
            }
            return this.reportDevicePresence(deviceId, online, connectorId, relayGeneration, relayEpoch);
        });
    }
    reportDevicePresence(deviceId, online, connectorId = this.bridgeConnectorId, relayGeneration = this.relayLeaseGeneration, relayEpoch = this.relayEpoch) {
        if (connectorId === undefined || relayGeneration === undefined || relayEpoch === undefined) {
            if (online)
                this.presenceRefreshRequired.add(deviceId);
            return Promise.resolve(false);
        }
        const previous = this.presenceUpdates.get(deviceId) ?? Promise.resolve(true);
        const update = previous.catch(() => false).then(async () => {
            for (let attempt = 0; attempt < 3; attempt += 1) {
                try {
                    await this.callBridge({
                        method: "POST",
                        path: `/devices/${encodeURIComponent(deviceId)}/presence`,
                        body: { online, connectorId, relayGeneration, relayEpoch },
                    });
                    // The HTTP request may have completed just as this Bridge socket
                    // closed.  Its lease is no longer authoritative in that case; keep
                    // the refresh fence set so a session.create cannot race the
                    // replacement socket's registration.
                    if (online && (this.bridge === undefined || this.bridgeConnectorId !== connectorId)) {
                        this.presenceRefreshRequired.add(deviceId);
                        return false;
                    }
                    this.presenceRefreshRequired.delete(deviceId);
                    return true;
                }
                catch (error) {
                    this.log("warn", `Could not report device presence to local bridge: ${safeError(error, this.config)}`);
                    if (attempt < 2)
                        await new Promise((resolve) => setTimeout(resolve, 100 * (attempt + 1)));
                }
            }
            // A command waiting on this lease must receive a retryable protocol
            // error.  Do not let a swallowed 409/5xx turn into a final 403 from the
            // Bridge's origin-device check or a ten-minute idempotency tombstone.
            if (online)
                this.presenceRefreshRequired.add(deviceId);
            return false;
        });
        this.presenceUpdates.set(deviceId, update);
        void update.finally(() => {
            if (this.presenceUpdates.get(deviceId) === update)
                this.presenceUpdates.delete(deviceId);
        });
        return update;
    }
    async emitCommandResult(command, response, sessionSnapshotGeneration, workspaceCatalogGeneration) {
        if (command.type === "configuration.read" || command.type === "configuration.update" || command.type === "configuration.discover") {
            const event = command.type === "configuration.read" ? { type: "configuration.result", payload: ConfigurationResultSchema.parse(response) }
                : command.type === "configuration.discover" ? { type: "configuration.models", payload: ConfigurationModelsSchema.parse(response) }
                    : { type: "configuration.updated", payload: ConfigurationUpdatedSchema.parse(response) };
            this.sendEvent({ version: PROTOCOL_VERSION, messageId: command.requestId, machineId: this.config.machineId, deviceId: command.deviceId,
                sequence: ++this.sequence, timestamp: Date.now(), ...event });
            return;
        }
        if (command.type === "schedule.get") {
            this.sendEvent({ version: PROTOCOL_VERSION, messageId: command.requestId, machineId: this.config.machineId, deviceId: command.deviceId,
                sessionId: requireSessionId(command), sequence: ++this.sequence, timestamp: Date.now(), type: "schedule.projection", payload: ScheduleProjectionSchema.parse(response) });
            return;
        }
        if (command.type === "session.search" || command.type === "conversation.search" || command.type === "history.read") {
            const event = command.type === "history.read" ? { type: "history.page", payload: HistoryPageSchema.parse(response) }
                : { type: "search.results", payload: SearchResultsSchema.parse(response) };
            this.sendEvent({ version: PROTOCOL_VERSION, messageId: command.requestId, machineId: this.config.machineId, deviceId: command.deviceId,
                ...(command.sessionId === undefined ? {} : { sessionId: command.sessionId }), sequence: ++this.sequence, timestamp: Date.now(), ...event });
            return;
        }
        if (command.type === "reference.list") {
            this.sendEvent({ version: PROTOCOL_VERSION, messageId: command.requestId, machineId: this.config.machineId, deviceId: command.deviceId,
                sessionId: requireSessionId(command), sequence: ++this.sequence, timestamp: Date.now(), type: "reference.candidates", payload: ReferenceCandidatesSchema.parse(response) });
            return;
        }
        if (command.type === "feedback.list" || command.type === "feedback.update") {
            const event = command.type === "feedback.list"
                ? { type: "feedback.state", payload: FeedbackStateSchema.parse(response) }
                : { type: "feedback.updated", payload: FeedbackUpdatedSchema.parse(response) };
            this.sendEvent({ version: PROTOCOL_VERSION, messageId: command.requestId, machineId: this.config.machineId,
                deviceId: command.deviceId, sessionId: requireSessionId(command), sequence: ++this.sequence, timestamp: Date.now(), ...event });
            return;
        }
        if (command.type === "execution.list") {
            this.sendEvent({ version: PROTOCOL_VERSION, messageId: command.requestId,
                machineId: this.config.machineId, deviceId: command.deviceId, sessionId: requireSessionId(command),
                sequence: ++this.sequence, timestamp: Date.now(), type: "execution.page", payload: ExecutionPagePayloadSchema.parse(response) });
            return;
        }
        if (command.type === "workspace.files" || command.type === "workspace.bytes") {
            const event = command.type === "workspace.files"
                ? { type: "workspace.files", payload: WorkspaceFilesPayloadSchema.parse(response) }
                : { type: "workspace.bytes", payload: WorkspaceBytesPayloadSchema.parse(response) };
            this.sendEvent({ version: PROTOCOL_VERSION, messageId: command.requestId,
                machineId: this.config.machineId, deviceId: command.deviceId, sessionId: requireSessionId(command),
                sequence: ++this.sequence, timestamp: Date.now(), ...event });
            return;
        }
        if (command.type === "goal.get" || command.type === "goal.update") {
            const event = command.type === "goal.get"
                ? { type: "goal.state", payload: GoalChangedPayloadSchema.parse(response) }
                : { type: "goal.updated", payload: GoalUpdatedPayloadSchema.parse(response) };
            this.sendEvent({ version: PROTOCOL_VERSION, messageId: command.requestId,
                machineId: this.config.machineId, deviceId: command.deviceId, sessionId: requireSessionId(command),
                sequence: ++this.sequence, timestamp: Date.now(), ...event });
            return;
        }
        if (command.type === "decisions.list") {
            this.sendEvent({ version: PROTOCOL_VERSION, messageId: command.requestId,
                machineId: this.config.machineId, deviceId: command.deviceId,
                sequence: ++this.sequence, timestamp: Date.now(), type: "decisions.snapshot",
                payload: DecisionsSnapshotPayloadSchema.parse(response) });
            return;
        }
        if (command.type === "session.open") {
            // The bridge publishes the requested historical events over its existing
            // event socket. There is no extra command-result card for opening a
            // conversation; the phone only needs the transcript events themselves.
            return;
        }
        if (command.type === "command.catalog") {
            this.sendEvent({ version: PROTOCOL_VERSION, messageId: command.requestId,
                machineId: this.config.machineId, deviceId: command.deviceId,
                sessionId: requireSessionId(command), sequence: ++this.sequence, timestamp: Date.now(),
                type: "command.catalog", payload: CommandCatalogPayloadSchema.parse(response) });
            return;
        }
        if (command.type === "subagent.catalog") {
            this.sendEvent({ version: PROTOCOL_VERSION, messageId: command.requestId,
                machineId: this.config.machineId, deviceId: command.deviceId,
                sessionId: requireSessionId(command), sequence: ++this.sequence, timestamp: Date.now(),
                type: "subagent.catalog", payload: SubagentCatalogPayloadSchema.parse(response) });
            return;
        }
        if (command.type === "subagent.prompt" || command.type === "subagent.interrupt") {
            const data = asRecord(response);
            if (data.accepted !== true || (command.type === "subagent.prompt" &&
                (typeof data.messageId !== "string" || data.messageId.length === 0))) {
                throw new BridgeRequestError(502, "subagent control was not acknowledged");
            }
            this.sendEvent({ version: PROTOCOL_VERSION, messageId: command.requestId,
                machineId: this.config.machineId, deviceId: command.deviceId,
                sessionId: requireSessionId(command), sequence: ++this.sequence, timestamp: Date.now(),
                type: "subagent.receipt", payload: { parentSessionId: command.payload.parentSessionId,
                    childSessionId: requireSessionId(command), requestId: command.requestId,
                    action: command.type === "subagent.prompt" ? "prompt" : "interrupt",
                    ...(command.type === "subagent.prompt" ? { messageId: data.messageId } : {}) } });
            return;
        }
        if (command.type === "queue.update") {
            if (asRecord(response).accepted !== true)
                throw new BridgeRequestError(502, "queue update was not acknowledged");
            this.sendEvent({ version: PROTOCOL_VERSION, messageId: command.requestId,
                machineId: this.config.machineId, deviceId: command.deviceId,
                sessionId: requireSessionId(command), sequence: ++this.sequence, timestamp: Date.now(),
                type: "queue.updated", payload: { sessionId: requireSessionId(command), itemId: command.payload.itemId, requestId: command.requestId } });
            return;
        }
        if (command.type === "session.fork") {
            const data = asRecord(response);
            if (typeof data.sessionId !== "string" || data.sessionId.length === 0) {
                throw new BridgeRequestError(502, "bridge fork response lacks sessionId");
            }
            this.sendEvent({ version: PROTOCOL_VERSION, messageId: command.requestId,
                machineId: this.config.machineId, deviceId: command.deviceId,
                sessionId: data.sessionId, sequence: ++this.sequence, timestamp: Date.now(),
                type: "session.forked", payload: { sessionId: data.sessionId,
                    parentSessionId: requireSessionId(command), requestId: command.requestId } });
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
                !this.isCurrentSessionSnapshotQuery(command.deviceId, sessionSnapshotGeneration))
                return;
            const pending = this.pendingSessionListRequests.get(command.deviceId);
            if (pending?.requestId !== command.requestId || pending.generation !== sessionSnapshotGeneration)
                return;
            this.pendingSessionListRequests.delete(command.deviceId);
            this.log("info", `Sending session snapshot (${items.length} sessions) to device ${shortID(command.deviceId)}`);
            this.sendSessionSnapshot(items, command.deviceId, command.requestId);
            this.flushDeferredSessionSnapshot(command.deviceId);
            return;
        }
        if (command.type === "session.create") {
            const data = asRecord(response);
            const sessionId = typeof data.sessionId === "string" ? data.sessionId : undefined;
            if (sessionId === undefined)
                throw new BridgeRequestError(502, "bridge response lacks sessionId");
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
                if (workspaceMutation)
                    void this.pushWorkspaceCatalog(command.deviceId);
                return;
            }
            const generation = this.beginSessionSnapshotQuery(command.deviceId);
            this.inFlightSessionMutations.set(command.deviceId, (this.inFlightSessionMutations.get(command.deviceId) ?? 0) + 1);
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
                    if (workspaceMutation)
                        this.deferredWorkspaceCatalogDevices.add(command.deviceId);
                    return;
                }
                // A list is a mutable projection, not an immutable command result.
                // Do not associate this snapshot with the mutation's idempotency cache;
                // a duplicate mutation will query the current list instead of replaying
                // an old snapshot with a fresh transport sequence.
                this.sendSessionSnapshot(items, command.deviceId);
                if (workspaceMutation)
                    await this.pushWorkspaceCatalog(command.deviceId);
            }
            finally {
                const remaining = (this.inFlightSessionMutations.get(command.deviceId) ?? 1) - 1;
                if (remaining <= 0)
                    this.inFlightSessionMutations.delete(command.deviceId);
                else
                    this.inFlightSessionMutations.set(command.deviceId, remaining);
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
                !this.isCurrentWorkspaceCatalogQuery(command.deviceId, workspaceCatalogGeneration))
                return;
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
    replayCommandResult(command) {
        const key = commandKey(command.machineId, command.deviceId, command.requestId);
        const cached = this.commandResults.get(key);
        const execution = this.commandExecutions.get(key);
        const events = cached?.events ?? execution?.events ?? this.recentEvents.filter((event) => event.messageId === command.requestId && event.deviceId === command.deviceId);
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
    async replaySessionList(command) {
        const latest = this.latestSessionListCommands.get(command.deviceId);
        if (latest !== undefined && latest.requestId !== command.requestId) {
            this.sendSupersededSessionList(command);
            return;
        }
        const generation = this.beginSessionSnapshotQuery(command.deviceId, command.payload.includeArchived === true);
        this.rememberLatestSessionListCommand(command.deviceId, command.requestId, generation, command.payload.includeArchived === true);
        this.pendingSessionListRequests.set(command.deviceId, {
            requestId: command.requestId,
            generation,
        });
        try {
            const data = asRecord(await this.callBridge({ method: "GET", path: this.sessionListPath(command.deviceId) }));
            const items = Array.isArray(data.items) ? data.items.map((item) => SessionSummarySchema.parse(item)) : [];
            const pending = this.pendingSessionListRequests.get(command.deviceId);
            if (!this.isCurrentSessionSnapshotQuery(command.deviceId, generation) ||
                pending?.requestId !== command.requestId || pending.generation !== generation)
                return;
            this.pendingSessionListRequests.delete(command.deviceId);
            this.sendSessionSnapshot(items, command.deviceId, command.requestId, command.requestId);
            this.flushDeferredSessionSnapshot(command.deviceId);
        }
        catch (error) {
            this.log("warn", `Failed to replay session list for device ${shortID(command.deviceId)}: ${safeError(error, this.config)}`);
            this.finishSessionListRequest(command, generation);
            if (!this.isCurrentSessionSnapshotQuery(command.deviceId, generation))
                return;
            this.sendProtocolError(command, error);
            this.flushDeferredSessionSnapshot(command.deviceId);
        }
    }
    async replayWorkspaceCatalog(command) {
        const latest = this.latestWorkspaceCatalogCommands.get(command.deviceId);
        if (latest !== undefined && latest.requestId !== command.requestId) {
            this.sendSupersededWorkspaceCatalog(command);
            return;
        }
        const generation = this.beginWorkspaceCatalogQuery(command.deviceId, command.requestId);
        try {
            const data = asRecord(await this.callBridge({ method: "GET", path: "/workspaces" }));
            if (!this.isCurrentWorkspaceCatalogQuery(command.deviceId, generation))
                return;
            const current = this.latestWorkspaceCatalogCommands.get(command.deviceId);
            if (current?.requestId !== command.requestId || current.generation !== generation)
                return;
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
        }
        catch (error) {
            this.log("warn", `Failed to replay workspace catalog for device ${shortID(command.deviceId)}: ${safeError(error, this.config)}`);
            if (!this.isCurrentWorkspaceCatalogQuery(command.deviceId, generation))
                return;
            this.sendProtocolError(command, error);
        }
    }
    sendSupersededSessionList(command) {
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
    sendSupersededWorkspaceCatalog(command) {
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
    sendProtocolError(command, error) {
        // A successful native mutation can still be followed by a broken HTTP
        // response (for example a truncated JSON body).  Only an explicit
        // client-error response proves that session creation was rejected before
        // it reached the Harness; every other create failure keeps the original
        // request id in the recoverable "result unknown" state.
        const definitelyRejected = error instanceof BridgeRequestError && (
        // An explicit committed-recovery outcome wins over the HTTP status:
        // optional session setup can surface a native 4xx after create already
        // committed, and must not be treated as a definitely rejected create.
        (error.outcome !== "retryable-committed" &&
            error.status >= 400 && error.status < 500 && error.outcome !== "unknown") ||
            // The Bridge marks a retryable 5xx only when it knows the handler
            // accepted no side effect. Presence preflight uses this path before
            // dispatchCommand, so session.create is definitely unaccepted too.
            (error.status >= 500 && error.outcome === "retryable"));
        const readOnly = ["session.list", "workspace.catalog", "directory.list", "mode.catalog", "model.catalog",
            "command.catalog", "subagent.catalog", "decisions.list", "goal.get", "workspace.files", "workspace.bytes", "execution.list", "feedback.list", "reference.list", "session.search", "conversation.search", "history.read", "schedule.get", "configuration.read", "configuration.discover"].includes(command.type);
        const timedOut = error instanceof Error && error.name === "TimeoutError";
        const resultUnknown = !readOnly && !definitelyRejected && ((error instanceof Error && error.name === "TimeoutError")
            || (error instanceof BridgeRequestError && error.outcome === "unknown")
            || (error instanceof BridgeRequestError && error.outcome === "retryable-committed")
            || (error instanceof BridgeRequestError && error.outcome === "retryable-durable")
            || command.type === "session.create");
        const configuration = command.type === "configuration.read" || command.type === "configuration.update" || command.type === "configuration.discover";
        const reason = configuration ? resultUnknown ? "保存结果尚未确认，请保留原请求，检查电脑状态后重试"
            : command.type === "configuration.discover" && error instanceof BridgeRequestError && error.status === 501 ? "此服务暂不提供模型发现，可返回配置手动编辑模型列表"
                : error instanceof BridgeRequestError && error.status === 426 ? "电脑端组件版本不匹配，请一并更新 Connector 与 Bridge"
                    : error instanceof BridgeRequestError && error.status === 409 ? "配置已在其他端更新，请刷新并合并；你的修改已保留"
                        : error instanceof BridgeRequestError && error.status === 403 ? "当前配置或凭据来源只读，无法从手机保存"
                            : error instanceof BridgeRequestError && (error.status === 501 || error.status === 404) ? "当前电脑尚未提供此配置能力，请更新 Harness 与 Bridge"
                                : "电脑配置请求失败，请检查字段格式、隐藏凭据和电脑端状态"
            : resultUnknown
                ? "Local operation did not confirm completion before the deadline; its result is unknown"
                : readOnly && timedOut
                    ? `Local DSH bridge read timed out (${command.type}); please retry`
                    : error instanceof BridgeRequestError
                        ? `Local DSH bridge request failed (${command.type}, HTTP ${error.status})`
                        : "Local DSH bridge request failed";
        this.log("warn", `${reason} for ${command.type}: ${safeError(error, this.config)}`);
        // A Connector-side timeout is safe to retry with the same id: the Bridge
        // idempotency entry either is still running or can return its stored result.
        // An explicit Bridge `unknown` outcome remains non-retryable because the
        // native side may already have committed a partial effect.
        const retryable = resultUnknown
            ? command.type === "session.create"
                || (error instanceof BridgeRequestError && error.outcome === "retryable-durable")
                || (error instanceof Error && error.name === "TimeoutError")
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
                ...(configuration && error instanceof BridgeRequestError ? { httpStatus: error.status } : {}),
                // A retry keeps this request id. The Bridge's idempotency layer then
                // either starts an unaccepted request after recovery or returns the
                // result of a side effect that was already accepted.
                retryable,
            },
        }, command.deviceId, command.requestId);
        return retryable;
    }
    async pushSessionSnapshot(deviceId) {
        if (this.pendingSessionListRequests.has(deviceId) || this.inFlightSessionMutations.has(deviceId)) {
            this.deferredSessionSnapshotDevices.add(deviceId);
            return;
        }
        const generation = this.beginSessionSnapshotQuery(deviceId);
        try {
            const data = asRecord(await this.callBridge({ method: "GET", path: this.sessionListPath(deviceId) }));
            const items = Array.isArray(data.items) ? data.items.map((item) => SessionSummarySchema.parse(item)) : [];
            if (!this.isCurrentSessionSnapshotQuery(deviceId, generation))
                return;
            this.log("info", `Device ${shortID(deviceId)} online; pushing session snapshot (${items.length} sessions)`);
            this.sendSessionSnapshot(items, deviceId);
        }
        catch (error) {
            this.log("warn", `Failed to push session snapshot to device ${shortID(deviceId)}: ${safeError(error, this.config)}`);
        }
    }
    async pushWorkspaceCatalog(deviceId) {
        const generation = this.beginWorkspaceCatalogQuery(deviceId);
        try {
            const data = asRecord(await this.callBridge({ method: "GET", path: "/workspaces" }));
            if (!this.isCurrentWorkspaceCatalogQuery(deviceId, generation))
                return;
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
        }
        catch (error) {
            this.log("warn", `Failed to push workspace catalog to device ${shortID(deviceId)}: ${safeError(error, this.config)}`);
        }
    }
    sendSessionSnapshot(items, deviceId, messageId = `${UNSOLICITED_SESSION_SNAPSHOT_PREFIX}${randomUUID()}`, commandRequestId) {
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
    sessionListPath(deviceId) {
        const query = this.includeArchivedByDevice.get(deviceId) === true ? "includeArchived=true&" : "";
        return `/sessions?${query}deviceId=${encodeURIComponent(deviceId)}`;
    }
    beginSessionSnapshotQuery(deviceId, includeArchived) {
        if (includeArchived !== undefined)
            this.includeArchivedByDevice.set(deviceId, includeArchived);
        const generation = (this.sessionSnapshotGenerationByDevice.get(deviceId) ?? 0) + 1;
        this.sessionSnapshotGenerationByDevice.set(deviceId, generation);
        return generation;
    }
    isCurrentSessionSnapshotQuery(deviceId, generation) {
        return this.sessionSnapshotGenerationByDevice.get(deviceId) === generation;
    }
    isSupersededSessionList(command) {
        return this.supersededSessionListRequests.has(this.queryTombstoneKey(command.deviceId, command.requestId));
    }
    rememberLatestSessionListCommand(deviceId, requestId, generation, includeArchived) {
        const previous = this.latestSessionListCommands.get(deviceId);
        if (previous !== undefined && previous.requestId !== requestId) {
            this.supersededSessionListRequests.set(this.queryTombstoneKey(deviceId, previous.requestId), Date.now() + COMMAND_DEDUP_TTL_MS);
        }
        this.latestSessionListCommands.set(deviceId, { requestId, generation, includeArchived });
    }
    beginWorkspaceCatalogQuery(deviceId, requestId) {
        const generation = (this.workspaceCatalogGenerationByDevice.get(deviceId) ?? 0) + 1;
        this.workspaceCatalogGenerationByDevice.set(deviceId, generation);
        if (requestId !== undefined) {
            const previous = this.latestWorkspaceCatalogCommands.get(deviceId);
            if (previous !== undefined && previous.requestId !== requestId) {
                this.supersededWorkspaceCatalogRequests.set(this.queryTombstoneKey(deviceId, previous.requestId), Date.now() + COMMAND_DEDUP_TTL_MS);
            }
            this.latestWorkspaceCatalogCommands.set(deviceId, { requestId, generation });
        }
        return generation;
    }
    isCurrentWorkspaceCatalogQuery(deviceId, generation) {
        return this.workspaceCatalogGenerationByDevice.get(deviceId) === generation;
    }
    isSupersededWorkspaceCatalog(command) {
        return this.supersededWorkspaceCatalogRequests.has(this.queryTombstoneKey(command.deviceId, command.requestId));
    }
    queryTombstoneKey(deviceId, requestId) {
        return `${deviceId}\0${requestId}`;
    }
    finishSessionListRequest(command, generation) {
        const pending = this.pendingSessionListRequests.get(command.deviceId);
        if (pending === undefined || pending.requestId !== command.requestId ||
            (generation !== undefined && pending.generation !== generation))
            return;
        this.pendingSessionListRequests.delete(command.deviceId);
    }
    flushDeferredSessionSnapshot(deviceId) {
        if (this.pendingSessionListRequests.has(deviceId) || this.inFlightSessionMutations.has(deviceId))
            return;
        if (!this.deferredSessionSnapshotDevices.delete(deviceId))
            return;
        void this.pushSessionSnapshot(deviceId);
    }
    flushDeferredWorkspaceCatalog(deviceId) {
        if (!this.deferredWorkspaceCatalogDevices.delete(deviceId))
            return;
        void this.pushWorkspaceCatalog(deviceId);
    }
    setStreamingPreference(sessionId, deviceId, enabled) {
        const devices = this.streamingDevicesBySession.get(sessionId) ?? new Set();
        if (enabled)
            devices.add(deviceId);
        else
            devices.delete(deviceId);
        if (devices.size === 0)
            this.streamingDevicesBySession.delete(sessionId);
        else
            this.streamingDevicesBySession.set(sessionId, devices);
    }
    /** Live deltas, reasoning snapshots, and abandoned-attempt cleanups are
     * never broadcast: legacy clients do not know that their temporary ids must
     * be removed. Readdressing the body itself, rather than only Relay's target,
     * also keeps replay scoped to the opted-in device. */
    sendStreamingEvent(event) {
        const sessionId = event.sessionId;
        if (sessionId === undefined)
            return;
        for (const deviceId of this.streamingDevicesBySession.get(sessionId) ?? []) {
            this.sendEvent({ ...event, deviceId }, deviceId);
        }
    }
    /** Deliver the replacement hint only to clients that received the temporary
     * stream. Everyone receives the same canonical completion without the new
     * field, so strict legacy decoders remain valid. The targeted event is sent
     * before the broadcast completion, allowing a current client to remove its
     * transient bubble before the canonical row is observed. */
    sendStreamingCompletion(event) {
        const sessionId = event.sessionId;
        if (sessionId !== undefined) {
            for (const deviceId of this.streamingDevicesBySession.get(sessionId) ?? []) {
                this.sendEvent({ ...event, deviceId }, deviceId);
            }
        }
        const { replacesMessageId: _replacement, ...canonicalPayload } = event.payload;
        this.sendEvent({ ...event, payload: canonicalPayload });
    }
    sendEvent(event, targetDeviceId, commandRequestId) {
        const payload = event.type === "connection.ready"
            ? { ...event.payload, machineId: this.config.machineId }
            : event.payload;
        const body = EventEnvelopeSchema.parse({
            ...event,
            machineId: this.config.machineId,
            payload,
            sequence: ++this.sequence,
        });
        const ephemeralFile = body.type === "workspace.files" || body.type === "workspace.bytes" || body.type === "execution.page" || body.type === "feedback.state" || body.type === "reference.candidates" || body.type === "search.results" || body.type === "history.page" || body.type === "configuration.result" || body.type === "configuration.updated" || body.type === "configuration.models" || body.type === "configuration.invalidated";
        if (!ephemeralFile)
            this.rememberEvent(body);
        if (commandRequestId !== undefined) {
            this.rememberCommandResult(commandKey(body.machineId, body.deviceId, commandRequestId), body);
        }
        const relay = this.relay;
        if (relay === undefined || relay.readyState !== WebSocket.OPEN || !this.relayVerified) {
            // Cache the canonical event before placing it in the bounded transport
            // queue. A request result must remain replayable even if unrelated
            // offline events later evict their wire copies.
            if (!ephemeralFile)
                this.queueEvent(body);
            return;
        }
        // A bridge/command response carries its intended recipient in the event
        // envelope. Preserve that address through offline queueing too; otherwise
        // one phone's folder picker or archive snapshot is broadcast to every
        // paired device when the relay reconnects.
        this.sendRelayEvent(body, targetDeviceId ?? (body.deviceId === "broadcast" ? undefined : body.deviceId));
    }
    sendRelayEvent(body, targetDeviceId, compatibilityDiagnostic = false) {
        const relay = this.relay;
        if (relay === undefined || relay.readyState !== WebSocket.OPEN || (!this.relayVerified && !compatibilityDiagnostic))
            return;
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
    rememberEvent(event) {
        const bytes = eventBytes(event);
        while (this.recentEvents.length > 0 &&
            (this.recentEvents.length >= MAX_REPLAY_EVENTS || this.recentEventBytes + bytes > MAX_REPLAY_BYTES)) {
            this.recentEventBytes -= eventBytes(this.recentEvents.shift());
        }
        if (bytes > MAX_REPLAY_BYTES)
            return;
        this.recentEvents.push(event);
        this.recentEventBytes += bytes;
        if (event.deviceId !== "broadcast") {
            const key = commandKey(event.machineId, event.deviceId, event.messageId);
            if (this.commandExecutions.has(key))
                this.rememberCommandResult(key, event);
        }
    }
    rememberCommandResult(key, event) {
        const now = Date.now();
        for (const [entryKey, entry] of this.commandResults) {
            if (entry.expiresAt <= now && !this.commandExecutions.has(entryKey))
                this.commandResults.delete(entryKey);
        }
        const execution = this.commandExecutions.get(key);
        if (execution !== undefined && !execution.events.some((candidate) => candidate.messageId === event.messageId)) {
            execution.events.push(event);
        }
        let entry = this.commandResults.get(key);
        if (entry === undefined) {
            if (this.commandResults.size >= MAX_COMMAND_RESULT_ENTRIES) {
                const evictable = [...this.commandResults].find(([entryKey]) => !this.commandExecutions.has(entryKey));
                if (evictable === undefined)
                    return;
                this.commandResults.delete(evictable[0]);
            }
            entry = { events: [], expiresAt: now + COMMAND_DEDUP_TTL_MS };
            this.commandResults.set(key, entry);
        }
        const existingIndex = entry.events.findIndex((candidate) => candidate.messageId === event.messageId);
        if (existingIndex >= 0)
            entry.events[existingIndex] = event;
        else
            entry.events.push(event);
        entry.expiresAt = now + COMMAND_DEDUP_TTL_MS;
    }
    replayAfter(lastSequence, targetDeviceId) {
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
                || event.type === "directory.list" || event.type === "decisions.snapshot"
                || event.type === "workspace.files" || event.type === "workspace.bytes" || event.type === "execution.page" || event.type === "feedback.state" || event.type === "reference.candidates" || event.type === "search.results" || event.type === "history.page" || event.type === "configuration.result" || event.type === "configuration.updated" || event.type === "configuration.models" || event.type === "configuration.invalidated")
                continue;
            if (event.deviceId !== "broadcast" && event.deviceId !== targetDeviceId)
                continue;
            if (event.sequence > lastSequence)
                this.sendRelayEvent(event, targetDeviceId);
        }
    }
    queueEvent(event) {
        const bytes = eventBytes(event);
        while (this.pendingEvents.length > 0 &&
            (this.pendingEvents.length >= MAX_PENDING_EVENTS || this.pendingEventBytes + bytes > MAX_PENDING_BYTES)) {
            this.pendingEventsDropped = true;
            this.pendingEventBytes -= eventBytes(this.pendingEvents.shift());
        }
        if (bytes > MAX_PENDING_BYTES) {
            this.pendingEventsDropped = true;
            return;
        }
        this.pendingEvents.push(event);
        this.pendingEventBytes += bytes;
    }
    flushPendingEvents() {
        if (this.relay === undefined || this.relay.readyState !== WebSocket.OPEN || !this.relayVerified)
            return;
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
    startPairingCodeRefresh() {
        if (this.pairingCodePath === undefined)
            return;
        void this.refreshPairingCode();
        this.pairingCodeTimer = setInterval(() => void this.refreshPairingCode(), PAIRING_CODE_REFRESH_MS);
    }
    async refreshPairingCode() {
        const path = this.pairingCodePath;
        if (path === undefined || !this.running)
            return;
        try {
            const issued = await requestPairingCode(this.config, this.request);
            await writePairingCodeFile(path, { machineId: this.config.machineId, ...issued });
        }
        catch (error) {
            this.log("warn", `Could not publish a one-time pairing code: ${safeError(error, this.config)}`);
        }
    }
    stopPairingCodeRefresh() {
        if (this.pairingCodeTimer !== undefined)
            clearInterval(this.pairingCodeTimer);
        this.pairingCodeTimer = undefined;
    }
    clearRelayHandshakeTimer() {
        if (this.relayHandshakeTimer !== undefined)
            clearTimeout(this.relayHandshakeTimer);
        this.relayHandshakeTimer = undefined;
    }
    rejectRelaySchema(socket) {
        this.relayVerified = false;
        this.clearRelayHandshakeTimer();
        const message = `Relay 协议版本过旧或未完成协商，请先升级 Relay 至 schemaRevision ${SCHEMA_REVISION} 或以上，再更新 Connector、Bridge 和 iOS App。此次连接尚未转发聊天与配置操作。`;
        this.log("warn", message);
        // The pinned v1 error shape is understood by old Relays. It contains no
        // parity fields, allowing paired phones to see the upgrade requirement.
        this.sendRelayEvent({ version: PROTOCOL_VERSION, messageId: randomUUID(), machineId: this.config.machineId, deviceId: "broadcast",
            sequence: ++this.sequence, timestamp: Date.now(), type: "protocol.error", payload: { code: "relay-upgrade-required", message, retryable: false } }, undefined, true);
        socket.close(4406, "Relay schema upgrade required");
    }
    startHeartbeat(socket) {
        this.stopHeartbeat();
        this.awaitingPong = false;
        this.heartbeatTimer = setInterval(() => {
            if (this.relay !== socket || !this.running)
                return;
            if (this.awaitingPong) {
                socket.terminate?.();
                return;
            }
            this.awaitingPong = true;
            socket.ping?.();
        }, this.heartbeatMs);
    }
    stopHeartbeat() {
        if (this.heartbeatTimer !== undefined)
            clearInterval(this.heartbeatTimer);
        this.heartbeatTimer = undefined;
        this.awaitingPong = false;
    }
    scheduleRelayReconnect() {
        if (this.relayTimer !== undefined)
            return;
        this.state = "reconnecting";
        const delay = backoffDelay(++this.relayAttempts, this.reconnectBaseMs, this.reconnectMaxMs);
        this.log("info", `Relay disconnected; reconnecting in ${delay}ms`);
        this.relayTimer = setTimeout(() => {
            this.relayTimer = undefined;
            this.connectRelay();
        }, delay);
    }
    scheduleBridgeReconnect() {
        if (this.bridgeTimer !== undefined)
            return;
        const delay = backoffDelay(++this.bridgeAttempts, this.reconnectBaseMs, this.reconnectMaxMs);
        this.log("info", `Local DSH bridge disconnected; reconnecting in ${delay}ms`);
        this.bridgeTimer = setTimeout(() => {
            this.bridgeTimer = undefined;
            this.connectBridge();
        }, delay);
    }
    clearTimers() {
        this.clearRelayHandshakeTimer();
        if (this.relayTimer !== undefined)
            clearTimeout(this.relayTimer);
        if (this.bridgeTimer !== undefined)
            clearTimeout(this.bridgeTimer);
        this.relayTimer = undefined;
        this.bridgeTimer = undefined;
        this.stopHeartbeat();
        this.stopPairingCodeRefresh();
    }
    log(level, message) {
        this.logger[level](redactSecrets(message, this.config));
    }
}
export function bridgeRequestFor(command) {
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
                body: { deviceId: command.deviceId,
                    ...(command.payload.parentSessionId === undefined ? {} : { parentSessionId: command.payload.parentSessionId }),
                    ...(command.payload.subagentMode === undefined ? {} : { subagentMode: command.payload.subagentMode }),
                    ...(command.payload.historyFingerprint === undefined ? {} : { historyFingerprint: command.payload.historyFingerprint }) },
            };
        case "session.fork":
            return { method: "POST", path: `/sessions/${encodeURIComponent(requireSessionId(command))}/fork`,
                headers: { "x-dsh-origin-device-id": command.deviceId }, body: command.payload };
        case "command.catalog":
            return { method: "GET", path: `/sessions/${encodeURIComponent(requireSessionId(command))}/commands` };
        case "subagent.catalog":
            return { method: "GET", path: `/sessions/${encodeURIComponent(requireSessionId(command))}/subagents` };
        case "decisions.list":
            return { method: "GET", path: "/decisions" };
        case "subagent.prompt":
        case "subagent.interrupt":
            return { method: "POST", path: `/sessions/${encodeURIComponent(command.payload.parentSessionId)}/subagents/${encodeURIComponent(requireSessionId(command))}/${command.type === "subagent.prompt" ? "prompt" : "interrupt"}`,
                headers: { "x-dsh-origin-device-id": command.deviceId }, body: command.payload };
        case "queue.update":
            return { method: "POST", path: `/sessions/${encodeURIComponent(requireSessionId(command))}/queue`,
                headers: { "x-dsh-origin-device-id": command.deviceId }, body: command.payload };
        case "goal.get":
            return { method: "GET", path: `/sessions/${encodeURIComponent(requireSessionId(command))}/goal` };
        case "feedback.list":
            return { method: "GET", path: `/sessions/${encodeURIComponent(requireSessionId(command))}/feedback` };
        case "reference.list": {
            const query = new URLSearchParams(command.payload);
            return { method: "GET", path: `/sessions/${encodeURIComponent(requireSessionId(command))}/references?${query.toString()}` };
        }
        case "session.search":
        case "conversation.search":
        case "history.read": {
            const query = new URLSearchParams();
            for (const [key, value] of Object.entries(command.payload))
                query.set(key, String(value));
            const path = command.type === "session.search" ? "/search" : `/sessions/${encodeURIComponent(requireSessionId(command))}/${command.type === "history.read" ? "history" : "search"}`;
            return { method: "GET", path: `${path}?${query.toString()}` };
        }
        case "schedule.get": {
            const query = new URLSearchParams();
            for (const [key, value] of Object.entries(command.payload))
                query.set(key, String(value));
            return { method: "GET", path: `/sessions/${encodeURIComponent(requireSessionId(command))}/schedules?${query.toString()}` };
        }
        case "configuration.read": {
            const query = new URLSearchParams({ section: command.payload.section });
            if (command.payload.section === "credentials")
                query.set("refs", JSON.stringify(command.payload.refs));
            return { method: "GET", path: `/configuration?${query.toString()}` };
        }
        case "configuration.discover":
            return { method: "POST", path: "/configuration/discover", body: command.payload };
        case "configuration.update":
            return { method: "POST", path: "/configuration", headers: { "x-dsh-origin-device-id": command.deviceId }, body: command.payload };
        case "feedback.update":
            return { method: "POST", path: `/sessions/${encodeURIComponent(requireSessionId(command))}/feedback`,
                headers: { "x-dsh-origin-device-id": command.deviceId }, body: command.payload };
        case "execution.list": {
            const query = new URLSearchParams();
            for (const [key, value] of Object.entries(command.payload))
                query.set(key, String(value));
            return { method: "GET", path: `/sessions/${encodeURIComponent(requireSessionId(command))}/execution?${query.toString()}` };
        }
        case "workspace.files":
        case "workspace.bytes": {
            const query = new URLSearchParams();
            for (const [key, value] of Object.entries(command.payload))
                query.set(key, String(value));
            return { method: "GET", path: `/sessions/${encodeURIComponent(requireSessionId(command))}/workspace/${command.type === "workspace.files" ? "files" : "bytes"}?${query.toString()}` };
        }
        case "goal.update":
            return { method: "POST", path: `/sessions/${encodeURIComponent(requireSessionId(command))}/goal`,
                headers: { "x-dsh-origin-device-id": command.deviceId }, body: command.payload };
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
        case "question.cancel":
            return { method: "POST", path: `/questions/${encodeURIComponent(command.payload.questionId)}/cancel`, body: {} };
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
            return {
                method: "POST", path: "/workspaces",
                headers: { "x-dsh-origin-device-id": command.deviceId },
                body: command.payload,
            };
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
                headers: { "x-dsh-origin-device-id": command.deviceId },
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
                headers: { "x-dsh-origin-device-id": command.deviceId },
                body: command.payload,
            };
        default:
            throw new UnsupportedCommandError(command.type);
    }
}
export function bridgeTimeoutFor(command) {
    switch (command.type) {
        // These Bridge paths may legitimately await Harness work for up to 120s.
        // The Connector stays slightly outside that deadline so a locally accepted
        // operation cannot be reported as failed while it is still executing.
        case "session.create":
        case "session.open":
        case "session.fork":
        case "command.execute":
        case "subagent.prompt":
        case "subagent.interrupt":
        case "goal.update":
        case "permission.set":
        case "feedback.update":
        case "attachment.upload":
        case "workspace.create":
        case "workspace.delete":
            return LONG_BRIDGE_TIMEOUT_MS;
        default:
            return 15_000;
    }
}
export function relayConnectURL(relayURL) {
    const url = new URL("v1/connect", trailingSlash(relayURL));
    url.searchParams.set("schemaRevision", String(SCHEMA_REVISION));
    return url.toString();
}
export function bridgeEventsURL(bridgeBaseURL, connectorInstanceId, afterSequence = 0) {
    const url = new URL("events", trailingSlash(bridgeBaseURL));
    url.protocol = url.protocol === "https:" ? "wss:" : "ws:";
    if (connectorInstanceId !== undefined)
        url.searchParams.set("connectorId", connectorInstanceId);
    if (afterSequence > 0)
        url.searchParams.set("after", String(afterSequence));
    return url.toString();
}
export function bridgeAPIURL(bridgeBaseURL, path) {
    return new URL(path.replace(/^\//, ""), trailingSlash(bridgeBaseURL)).toString();
}
export function backoffDelay(attempt, baseMs = 500, maxMs = 30_000) {
    const capped = Math.min(20, Math.max(1, attempt));
    return Math.min(maxMs, baseMs * 2 ** (capped - 1));
}
class BridgeRequestError extends Error {
    status;
    outcome;
    constructor(status, message = `HTTP ${status}`, outcome = undefined) {
        super(message);
        this.status = status;
        this.outcome = outcome;
    }
}
class UnsupportedCommandError extends Error {
    constructor(command) {
        super(`unsupported command: ${command}`);
    }
}
function defaultWebSocketFactory(url, headers) {
    return new WebSocket(url, { headers });
}
function authorization(token) {
    return { authorization: `Bearer ${token}` };
}
function parseJson(raw) {
    try {
        return JSON.parse(Buffer.isBuffer(raw) ? raw.toString("utf8") : String(raw));
    }
    catch {
        return undefined;
    }
}
function eventBytes(event) {
    return Buffer.byteLength(JSON.stringify(event));
}
function commandKey(machineId, deviceId, requestId) {
    return `${machineId}\u0000${deviceId}\u0000${requestId}`;
}
function isSessionProjectionMutation(command) {
    return command.type === "session.archive" || command.type === "session.model"
        || command.type === "permission.set" || command.type === "workspace.rename"
        || command.type === "workspace.delete" || command.type === "session.rename";
}
function requiresDevicePresence(command) {
    return command.type === "session.create" || command.type === "session.fork" || command.type === "attachment.upload"
        || command.type === "command.execute" || command.type === "workspace.create" || command.type === "queue.update"
        || command.type === "subagent.prompt" || command.type === "subagent.interrupt" || command.type === "goal.update" || command.type === "feedback.update" || command.type === "configuration.update" || command.type === "configuration.discover";
}
function trailingSlash(value) {
    return value.endsWith("/") ? value : `${value}/`;
}
function requireSessionId(command) {
    if (command.sessionId === undefined)
        throw new UnsupportedCommandError(`${command.type} without sessionId`);
    return command.sessionId;
}
function asRecord(value) {
    return typeof value === "object" && value !== null && !Array.isArray(value) ? value : {};
}
function isRetryable(error) {
    if (!(error instanceof BridgeRequestError))
        return true;
    if (error.outcome !== undefined) {
        return error.outcome === "retryable" || error.outcome === "retryable-durable";
    }
    return error.status >= 500;
}
function safeError(error, config) {
    return redactSecrets(error instanceof Error ? error.message : String(error), config);
}
/** Device IDs are diagnostics, not secrets; still avoid writing full IDs to logs. */
function shortID(value) {
    return value.length <= 8 ? value : `…${value.slice(-8)}`;
}
const consoleLogger = {
    info: (message) => console.log(`[dsh-anywhere] ${message}`),
    warn: (message) => console.warn(`[dsh-anywhere] ${message}`),
};
