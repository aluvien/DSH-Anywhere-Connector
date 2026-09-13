import { randomUUID } from "node:crypto";
import {
  CommandEnvelopeSchema,
  AttachmentUploadedPayloadSchema,
  CommandResultPayloadSchema,
  EventEnvelopeSchema,
  ModelCatalogPayloadSchema,
  PROTOCOL_VERSION,
  RelayMessageSchema,
  RelayPayloadMessageSchema,
  SessionSummarySchema,
  type CommandEnvelope,
  type EventEnvelope,
  type SessionSummary,
} from "@dsh-anywhere/protocol";
import WebSocket, { type RawData } from "ws";
import { redactSecrets, type ConnectorConfig } from "./config.js";
import { requestPairingCode, writePairingCodeFile } from "./setup.js";

const MAX_REPLAY_EVENTS = 2_000;
/** Comfortably inside the relay's 10-minute code lifetime. */
const PAIRING_CODE_REFRESH_MS = 5 * 60_000;

export interface Logger {
  info(message: string): void;
  warn(message: string): void;
}

export interface WebSocketLike {
  readonly readyState: number;
  send(data: string): void;
  close(code?: number, reason?: string): void;
  terminate?(): void;
  ping?(): void;
  on(event: "open" | "close" | "pong", listener: () => void): this;
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
}

/**
 * Keeps the public Relay connection and the local DSH bridge deliberately separate.
 * The Connector only ever opens outbound connections; no local port is exposed.
 */
export class DSHAnywhereConnector {
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
    this.pendingEvents.length = 0;
    this.recentEvents.length = 0;
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
    socket.on("close", () => {
      if (this.relay !== socket) return;
      this.stopHeartbeat();
      this.relay = undefined;
      if (this.running) this.scheduleRelayReconnect();
    });
  }

  private connectBridge(): void {
    if (!this.running) return;
    const socket = this.webSocketFactory(bridgeEventsURL(this.config.bridgeBaseURL), authorization(this.config.bridgeToken));
    this.bridge = socket;
    socket.on("open", () => {
      if (this.bridge !== socket || !this.running) return;
      this.bridgeAttempts = 0;
      this.log("info", "Local DSH bridge connected");
    });
    socket.on("message", (raw: RawData) => this.onBridgeMessage(socket, raw));
    socket.on("error", (error: Error) => this.log("warn", `Bridge socket error: ${safeError(error, this.config)}`));
    socket.on("close", () => {
      if (this.bridge !== socket) return;
      this.bridge = undefined;
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
    this.sendEvent(event.data);
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
    if (message.data.type === "relay.presence") {
      if (message.data.role === "device" && message.data.online && message.data.deviceId !== undefined) {
        void this.pushSessionSnapshot(message.data.deviceId);
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
    void this.executeCommand(command.data);
  }

  private async executeCommand(command: CommandEnvelope): Promise<void> {
    try {
      // The Connector owns the Relay-side replay window. This lets a device
      // connect after the bridge has already emitted its initial snapshot.
      if (command.type === "connection.resume") {
        this.replayAfter(command.payload.lastSequence, command.deviceId);
        // Resume is the one command every released iOS build reliably sends.
        // Follow it with an authoritative list so session discovery does not
        // depend on a separate refresh command or Relay presence timing.
        await this.pushSessionSnapshot(command.deviceId);
        return;
      }
      const request = bridgeRequestFor(command);
      const response = await this.callBridge(request);
      await this.emitCommandResult(command, response);
    } catch (error) {
      this.sendProtocolError(command, error);
    }
  }

  private async callBridge(request: BridgeRequest): Promise<unknown> {
    const response = await this.request(bridgeAPIURL(this.config.bridgeBaseURL, request.path), {
      method: request.method,
      headers: {
        ...authorization(this.config.bridgeToken),
        ...(request.body === undefined ? {} : { "content-type": "application/json" }),
      },
      ...(request.body === undefined ? {} : { body: JSON.stringify(request.body) }),
      signal: AbortSignal.timeout(15_000),
    });
    if (!response.ok) throw new BridgeRequestError(response.status);
    const contentType = response.headers.get("content-type") ?? "";
    return contentType.includes("application/json") ? response.json() : undefined;
  }

  private async emitCommandResult(command: CommandEnvelope, response: unknown): Promise<void> {
    if (command.type === "session.list") {
      const data = asRecord(response);
      const items = Array.isArray(data.items) ? data.items.map((item) => SessionSummarySchema.parse(item)) : [];
      this.log("info", `Sending session snapshot (${items.length} sessions) to device ${shortID(command.deviceId)}`);
      this.sendSessionSnapshot(items, command.deviceId, command.requestId);
      return;
    }
    if (command.type === "session.create") {
      const data = asRecord(response);
      const sessionId = typeof data.sessionId === "string" ? data.sessionId : undefined;
      if (sessionId === undefined) throw new BridgeRequestError(502, "bridge response lacks sessionId");
      const summary = asRecord(data.summary);
      const fallbackSummary = {
        id: sessionId,
        title: command.payload.title ?? "New session",
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
        payload: SessionSummarySchema.parse(Object.keys(summary).length > 0 ? summary : fallbackSummary),
      });
      if (command.payload.initialPrompt !== undefined) {
        await this.callBridge({
          method: "POST",
          path: `/sessions/${encodeURIComponent(sessionId)}/prompt`,
          body: { text: command.payload.initialPrompt, requestId: command.requestId },
        });
      }
      return;
    }
    if (command.type === "session.archive" || command.type === "session.model") {
      // These operations mutate native Harness metadata. Refresh the same
      // filtered list used by the live bridge so archived sessions disappear
      // immediately while model/workspace labels update in place.
      const refreshed = asRecord(await this.callBridge({ method: "GET", path: "/sessions" }));
      const items = Array.isArray(refreshed.items)
        ? refreshed.items.map((item) => SessionSummarySchema.parse(item))
        : [];
      this.sendEvent({
        version: PROTOCOL_VERSION,
        messageId: command.requestId,
        machineId: this.config.machineId,
        deviceId: command.deviceId,
        sequence: ++this.sequence,
        timestamp: Date.now(),
        type: "session.snapshot",
        payload: items,
      });
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

  private sendProtocolError(command: CommandEnvelope, error: unknown): void {
    const reason = error instanceof BridgeRequestError
      ? `Local DSH bridge request failed (HTTP ${error.status})`
      : "Local DSH bridge request failed";
    this.log("warn", `${reason} for ${command.type}: ${safeError(error, this.config)}`);
    this.sendEvent({
      version: PROTOCOL_VERSION,
      messageId: command.requestId,
      machineId: this.config.machineId,
      deviceId: command.deviceId,
      ...(command.sessionId === undefined ? {} : { sessionId: command.sessionId }),
      sequence: ++this.sequence,
      timestamp: Date.now(),
      type: "protocol.error",
      payload: { code: "bridge-request-failed", message: reason, retryable: isRetryable(error) },
    });
  }

  private async pushSessionSnapshot(deviceId: string): Promise<void> {
    try {
      const data = asRecord(await this.callBridge({ method: "GET", path: "/sessions" }));
      const items = Array.isArray(data.items) ? data.items.map((item) => SessionSummarySchema.parse(item)) : [];
      this.log("info", `Device ${shortID(deviceId)} online; pushing session snapshot (${items.length} sessions)`);
      this.sendSessionSnapshot(items, deviceId);
    } catch (error) {
      this.log("warn", `Failed to push session snapshot to device ${shortID(deviceId)}: ${safeError(error, this.config)}`);
    }
  }

  private sendSessionSnapshot(items: SessionSummary[], deviceId: string, messageId: string = randomUUID()): void {
    // Protocol v1 originally allowed only id/title/updatedAt in a session
    // summary. Send that compatible snapshot first so an older Relay can
    // still route the list; a current Relay accepts the following full
    // snapshot and leaves the richer workspace/model/usage data in place.
    const compatibleItems = items.map(({ id, title, updatedAt }) => ({ id, title, updatedAt }));
    this.sendEvent({
      version: PROTOCOL_VERSION,
      messageId: randomUUID(),
      machineId: this.config.machineId,
      deviceId,
      sequence: ++this.sequence,
      timestamp: Date.now(),
      type: "session.snapshot",
      payload: compatibleItems,
    }, deviceId);
    this.sendEvent({
      version: PROTOCOL_VERSION,
      messageId,
      machineId: this.config.machineId,
      deviceId,
      sequence: ++this.sequence,
      timestamp: Date.now(),
      type: "session.snapshot",
      payload: items,
    }, deviceId);
  }

  private sendEvent(event: EventEnvelope, targetDeviceId?: string): void {
    const relay = this.relay;
    if (relay === undefined || relay.readyState !== WebSocket.OPEN) {
      this.queueEvent(event);
      return;
    }
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
    this.sendRelayEvent(body, targetDeviceId);
  }

  private sendRelayEvent(body: EventEnvelope, targetDeviceId?: string): void {
    const relay = this.relay;
    if (relay === undefined || relay.readyState !== WebSocket.OPEN) return;
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
    if (this.recentEvents.length >= MAX_REPLAY_EVENTS) this.recentEvents.shift();
    this.recentEvents.push(event);
  }

  private replayAfter(lastSequence: number, targetDeviceId: string): void {
    for (const event of this.recentEvents) {
      if (event.sequence > lastSequence) this.sendRelayEvent(event, targetDeviceId);
    }
  }

  private queueEvent(event: EventEnvelope): void {
    // Keep a short outage from losing interactive output while avoiding unbounded memory use.
    if (this.pendingEvents.length >= 1_000) this.pendingEvents.shift();
    this.pendingEvents.push(event);
  }

  private flushPendingEvents(): void {
    if (this.relay === undefined || this.relay.readyState !== WebSocket.OPEN) return;
    const pending = this.pendingEvents.splice(0);
    for (const event of pending) this.sendEvent(event);
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
        path: command.payload.includeArchived === true ? "/sessions?includeArchived=true" : "/sessions",
      };
    case "session.create":
      return {
        method: "POST",
        path: "/sessions",
        body: {
          ...(command.payload.workingDirectory === undefined ? {} : { cwd: command.payload.workingDirectory }),
          ...(command.payload.workspaceId === undefined ? {} : { workspaceId: command.payload.workspaceId }),
          ...(command.payload.agentPreset === undefined ? {} : { agentPreset: command.payload.agentPreset }),
          ...(command.payload.model === undefined ? {} : { model: command.payload.model }),
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

export function relayConnectURL(relayURL: string): string {
  return new URL("v1/connect", trailingSlash(relayURL)).toString();
}

export function bridgeEventsURL(bridgeBaseURL: string): string {
  const url = new URL("events", trailingSlash(bridgeBaseURL));
  url.protocol = url.protocol === "https:" ? "wss:" : "ws:";
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
  constructor(readonly status: number, message = `HTTP ${status}`) {
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
  return !(error instanceof BridgeRequestError) || error.status >= 500;
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
