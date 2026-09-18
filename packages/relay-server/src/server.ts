import { randomUUID } from "node:crypto";
import { readFileSync } from "node:fs";
import { createServer, type IncomingMessage, type Server, type ServerResponse } from "node:http";
import { isIP, type AddressInfo } from "node:net";
import {
  PROTOCOL_VERSION,
  RelayErrorMessageSchema,
  RelayMessageSchema,
  type RelayMessage,
  type RelayPayloadMessage,
} from "@dsh-anywhere/protocol";
import { WebSocket, WebSocketServer, type RawData } from "ws";
import { Registry, type RelayPrincipal } from "./registry.js";

const MAX_HTTP_BODY_BYTES = 16 * 1024;
const MAX_RELAY_MESSAGE_BYTES = 16 * 1024 * 1024;
const MAX_SOCKET_BUFFER_BYTES = 2 * MAX_RELAY_MESSAGE_BYTES;
const MAX_INITIALIZATION_BUFFER_BYTES = MAX_RELAY_MESSAGE_BYTES;
const MAX_INITIALIZATION_BUFFER_MESSAGES = 32;
const INITIALIZATION_TIMEOUT_MS = 10_000;
const DEFAULT_PAIR_RATE_BUCKETS = 10_000;
/**
 * Bumped whenever the routed `WireMessage` union changes shape. The Relay
 * validates every forwarded body against that union, so a Relay older than the
 * Connector silently rejects the new event and command types. Deployment must
 * rebuild the Relay whenever this number moves.
 *
 * 3: added `assistant.reasoning`, `question.asked`, `question.resolved` events
 *    and the `question.answer` command.
 * 4: added `history.started`, `history.completed` events so history replays
 *    can bracket one session batch (older Relays reject them as invalid).
 * 5: earlier forwarded-type additions (unrecorded at the time).
 * 6: added optional `thumbnail` to chat attachments so Mac-side images
 *    (web uploads, model-returned images) reach the phone; older Relays
 *    reject thumbnail-bearing messages as invalid, so the Relay must be
 *    redeployed BEFORE any bridge starts sending them.
 * 8: added transient assistant-stream discard events, opt-in session opens,
 *    and the optional completion replacement id used to reconcile a live
 *    bubble with its durable assistant message.
 * 9: added targeted `prompt.accepted` request receipts so a lost prompt
 *    acknowledgement can be replayed without inferring identity from text.
 * 10: added Relay lease generation/epoch metadata for Bridge presence
 *     ownership and Bridge reconnect cursor recovery.
 */
const RELAY_SCHEMA_REVISION = 10;

/**
 * Deployment date shown on /health. The docker image bakes the build day
 * into /app/BUILD_DATE (see deploy/relay/Dockerfile), so every rebuild
 * stamps itself and nobody has to hand-edit a date string ever again.
 * Outside docker (local dev, tests) it falls back to this constant.
 */
function relayBuildStamp(): string {
  try {
    const stamped = readFileSync("/app/BUILD_DATE", "utf8").trim();
    if (/^\d{4}-\d{2}-\d{2}$/.test(stamped)) return stamped;
  } catch {
    // No stamp file: running from source. Fall through to the constant.
  }
  return "2026-09-16";
}

export interface RelayServerOptions {
  readonly bootstrapToken: string;
  readonly registryPath: string;
  readonly host?: string;
  readonly port?: number;
  readonly pairRateLimit?: number;
  readonly pairIpRateLimit?: number;
  readonly pairRateWindowMs?: number;
  readonly pairRateMaxBuckets?: number;
  /** Exact socket addresses of reverse proxies whose X-Forwarded-For header is trusted. */
  readonly trustedProxyAddresses?: readonly string[];
}

export interface RunningRelayServer {
  readonly registry: Registry;
  readonly server: Server;
  readonly url: string;
  close(): Promise<void>;
}

interface RelayConnection {
  readonly id: string;
  readonly ws: WebSocket;
  readonly principal: RelayPrincipal;
}

interface PairAttempt {
  readonly startedAt: number;
  count: number;
}

const RegisterMachineRequestSchema = (value: unknown): { machineName: string } | undefined => {
  if (!isRecord(value) || Object.keys(value).length !== 1 || typeof value.machineName !== "string") return undefined;
  const machineName = value.machineName.trim();
  return machineName.length >= 1 && machineName.length <= 256 ? { machineName } : undefined;
};

/**
 * Accepts either credential shape: the long-lived `pairingSecret` (unchanged,
 * so existing installs keep working) or a single-use `pairingCode` minted by the
 * machine. Exactly one of the two must be present.
 */
const PairDeviceRequestSchema = (
  value: unknown,
): { machineId: string; pairingSecret?: string; pairingCode?: string; deviceName: string } | undefined => {
  if (!isRecord(value)) return undefined;
  const { machineId, pairingSecret, deviceName } = value;
  const pairingCode = value.pairingCode;
  if (typeof machineId !== "string" || machineId.length < 1 || machineId.length > 256) return undefined;
  if (typeof deviceName !== "string") return undefined;
  const name = deviceName.trim();
  if (name.length < 1 || name.length > 256) return undefined;
  const hasSecret = typeof pairingSecret === "string" && pairingSecret.length >= 1 && pairingSecret.length <= 1024;
  const hasCode = typeof pairingCode === "string" && pairingCode.trim().length >= 1 && pairingCode.length <= 64;
  // The credential forms are intentionally mutually exclusive. Accepting both
  // would silently choose the one-time code while making callers believe the
  // long-lived secret was also checked.
  if (hasSecret === hasCode) return undefined;
  return {
    machineId,
    ...(hasSecret ? { pairingSecret } : {}),
    ...(hasCode ? { pairingCode } : {}),
    deviceName: name,
  };
};

export async function createRelayServer(options: RelayServerOptions): Promise<RunningRelayServer> {
  if (options.bootstrapToken.trim().length === 0) throw new Error("DSH_RELAY_BOOTSTRAP_TOKEN is required");
  const registry = new Registry(options.registryPath);
  await registry.load();
  const connections = new Set<RelayConnection>();
  const relayEpoch = randomUUID();
  const pairAttempts = new Map<string, PairAttempt>();
  const pairIpAttempts = new Map<string, PairAttempt>();
  const pairRateLimit = options.pairRateLimit ?? 5;
  const pairIpRateLimit = options.pairIpRateLimit ?? pairRateLimit * 20;
  const pairRateWindowMs = options.pairRateWindowMs ?? 60_000;
  const httpServer = createServer((request, response) => {
    void handleHttp(request, response).catch((error: unknown) => {
      respondJson(response, 500, { error: "internal_error", message: error instanceof Error ? error.message : "Unexpected error" });
    });
  });
  const pairRateMaxBuckets = options.pairRateMaxBuckets ?? DEFAULT_PAIR_RATE_BUCKETS;
  const trustedProxyAddresses = new Set(options.trustedProxyAddresses ?? []);
  const wss = new WebSocketServer({ noServer: true, maxPayload: MAX_RELAY_MESSAGE_BYTES });

  httpServer.on("upgrade", (request, socket, head) => {
    let url: URL;
    try {
      // Upgrade events bypass the ordinary HTTP handler's promise boundary.
      // Parse untrusted request targets inside this connection's boundary so a
      // malformed URL cannot escape as an uncaught exception and terminate the
      // Relay process before authentication has even run.
      url = new URL(request.url ?? "/", "http://relay.invalid");
    } catch {
      socket.write("HTTP/1.1 400 Bad Request\r\nConnection: close\r\n\r\n");
      socket.destroy();
      return;
    }
    if (url.pathname !== "/v1/connect") {
      socket.write("HTTP/1.1 404 Not Found\r\nConnection: close\r\n\r\n");
      socket.destroy();
      return;
    }
    const principal = authenticateBearer(request, registry);
    if (principal === undefined) {
      socket.write("HTTP/1.1 401 Unauthorized\r\nConnection: close\r\n\r\n");
      socket.destroy();
      return;
    }
    wss.handleUpgrade(request, socket, head, (ws) => {
      void connect(ws, principal);
    });
  });

  const connect = async (ws: WebSocket, principal: RelayPrincipal): Promise<void> => {
    const connection: RelayConnection = { id: randomUUID(), ws, principal };
    const pendingMessages: RawData[] = [];
    let pendingMessageBytes = 0;
    let initialized = false;
    let initializationTimer: NodeJS.Timeout | undefined;
    const clearInitialization = (): void => {
      if (initializationTimer !== undefined) clearTimeout(initializationTimer);
      initializationTimer = undefined;
      pendingMessages.length = 0;
      pendingMessageBytes = 0;
    };
    const rejectInitialization = (code: number, reason: string): void => {
      clearInitialization();
      if (ws.readyState === WebSocket.OPEN || ws.readyState === WebSocket.CONNECTING) {
        ws.close(code, reason);
      }
    };
    // The lease counter is persisted asynchronously. Attach the message and
    // close handlers before waiting for that write, otherwise a client can
    // send its first frame immediately after the WebSocket upgrade and have
    // it disappear before the connection enters the Relay set.
    ws.on("message", (raw) => {
      if (!initialized) {
        const bytes = rawDataBytes(raw);
        if (pendingMessages.length >= MAX_INITIALIZATION_BUFFER_MESSAGES ||
            bytes > MAX_INITIALIZATION_BUFFER_BYTES ||
            pendingMessageBytes + bytes > MAX_INITIALIZATION_BUFFER_BYTES) {
          rejectInitialization(1009, "initialization buffer limit exceeded");
          return;
        }
        pendingMessages.push(raw);
        pendingMessageBytes += bytes;
      }
      else handleSocketMessage(connection, raw);
    });
    ws.once("close", () => {
      clearInitialization();
      // A superseded machine was removed before it was closed. Do not publish
      // a false offline edge after its replacement is already online.
      if (connections.delete(connection)) broadcastPresence(principal, false);
    });
    ws.once("error", () => undefined);
    initializationTimer = setTimeout(() => {
      if (!initialized) rejectInitialization(1013, "connection initialization timed out");
    }, INITIALIZATION_TIMEOUT_MS);
    initializationTimer.unref?.();
    let leaseGeneration: number | undefined;
    if (principal.role === "machine") {
      try {
        leaseGeneration = await registry.nextMachineLeaseGeneration(principal.machineId);
      } catch {
        ws.close(1011, "unable to allocate machine lease");
        return;
      }
      if (ws.readyState !== WebSocket.OPEN) return;
    }
    // Each credential represents one active lease. Replacing the old socket
    // before publishing the new one prevents duplicate local execution and
    // avoids a stale mobile socket later emitting a false offline edge.
    for (const existing of connections) {
      if (!samePrincipal(existing.principal, principal)) continue;
      connections.delete(existing);
      existing.ws.close(4001, "superseded by a newer connection");
    }
    connections.add(connection);
    initialized = true;
    if (initializationTimer !== undefined) clearTimeout(initializationTimer);
    initializationTimer = undefined;
    const bufferedMessages = pendingMessages.splice(0);
    pendingMessageBytes = 0;
    send(connection, {
      type: "relay.ready",
      machineId: principal.machineId,
      role: principal.role,
      connectionId: connection.id,
      serverTime: Date.now(),
      ...(leaseGeneration === undefined ? {} : { leaseGeneration }),
      relayEpoch,
    });
    for (const existing of connections) {
      if (existing === connection || existing.principal.machineId !== principal.machineId) continue;
      send(connection, presence(existing.principal, true));
    }
    broadcastPresence(principal, true);
    for (const raw of bufferedMessages) handleSocketMessage(connection, raw);
  };

  const handleSocketMessage = (source: RelayConnection, raw: RawData): void => {
    // `ws.close()` starts an asynchronous closing handshake.  A peer can still
    // deliver a queued frame during that window, and a superseded connection's
    // message listener remains attached until its close event.  Membership in
    // the live connection set is the Relay's synchronous authorization bit;
    // check it before parsing or routing anything from the old socket.
    if (!connections.has(source) || source.ws.readyState !== WebSocket.OPEN) return;
    let decoded: unknown;
    try {
      decoded = JSON.parse(raw.toString());
    } catch {
      sendError(source, "invalid_json", "Relay messages must be valid JSON.");
      return;
    }
    const parsed = RelayMessageSchema.safeParse(decoded);
    if (!parsed.success) {
      const context = malformedRelayRequestContext(decoded);
      sendError(source, "invalid_message", "Relay message does not match the protocol schema.",
        context.machineId, context.messageId);
      return;
    }
    if (parsed.data.type !== "relay.payload") {
      sendError(source, "unsupported_message", "Clients may only send relay.payload messages.");
      return;
    }
    routePayload(source, parsed.data);
  };

  const routePayload = (source: RelayConnection, payload: RelayPayloadMessage): void => {
    // Keep the guard at the routing boundary as well as the message entry.  This
    // prevents a frame already queued in the event loop from being forwarded if
    // device revocation or lease replacement removed the source in between the
    // two callbacks.
    if (!connections.has(source) || source.ws.readyState !== WebSocket.OPEN) return;
    const { principal } = source;
    if (payload.machineId !== principal.machineId) {
      sendError(source, "machine_mismatch", "The token is not authorized for this machine.", payload.machineId, payload.messageId);
      return;
    }
    if (payload.sender !== principal.role) {
      sendError(source, "sender_mismatch", "The sender role must match the authenticated token.", payload.machineId, payload.messageId);
      return;
    }
    if (principal.role === "device" && payload.targetDeviceId !== undefined) {
      sendError(source, "target_not_allowed", "A device cannot select a Relay target.", payload.machineId, payload.messageId);
      return;
    }
    if (hasMachineId(payload.body) && payload.body.machineId !== principal.machineId) {
      sendError(source, "body_machine_mismatch", "The message body belongs to a different machine.", payload.machineId, payload.messageId);
      return;
    }
    if (principal.role === "device" && hasDeviceId(payload.body) && payload.body.deviceId !== principal.deviceId) {
      sendError(source, "body_device_mismatch", "The message body does not belong to this device.", payload.machineId, payload.messageId);
      return;
    }
    const targetRole = principal.role === "machine" ? "device" : "machine";
    const targets = [...connections].filter((connection) =>
      connection.principal.machineId === principal.machineId && connection.principal.role === targetRole &&
      (payload.targetDeviceId === undefined ||
        (connection.principal.role === "device" && connection.principal.deviceId === payload.targetDeviceId)) &&
      connection.ws.readyState === WebSocket.OPEN,
    );
    if (targets.length === 0) {
      sendError(source, "target_unavailable", `No connected ${targetRole} is available for this machine.`, payload.machineId, payload.messageId);
      return;
    }
    for (const target of targets) send(target, payload);
  };

  const broadcastPresence = (principal: RelayPrincipal, online: boolean): void => {
    const message = presence(principal, online);
    for (const connection of connections) {
      if (connection.principal.machineId === principal.machineId) send(connection, message);
    }
  };

  async function handleHttp(request: IncomingMessage, response: ServerResponse): Promise<void> {
    const url = new URL(request.url ?? "/", "http://relay.invalid");
    if (request.method === "GET" && url.pathname === "/health") {
      respondJson(response, 200, {
        ok: true,
        version: PROTOCOL_VERSION,
        schemaRevision: RELAY_SCHEMA_REVISION,
        build: relayBuildStamp(),
        // Neither device management nor one-time pairing codes changed the
        // routed wire schema, so the revision stays put; these flags are how a
        // caller tells whether the deployed Relay serves those routes yet.
        deviceManagement: true,
        oneTimePairingCodes: true,
      });
      return;
    }
    if (request.method === "POST" && url.pathname === "/v1/machines/register") {
      if (bearerToken(request) !== options.bootstrapToken) {
        respondJson(response, 401, { error: "unauthorized" });
        return;
      }
      const body = RegisterMachineRequestSchema(await readJson(request));
      if (body === undefined) {
        respondJson(response, 400, { error: "invalid_request", message: "machineName is required." });
        return;
      }
      const registration = await registry.registerMachine(body.machineName);
      respondJson(response, 201, registration);
      return;
    }
    if (request.method === "POST" && url.pathname === "/v1/pair") {
      const body = PairDeviceRequestSchema(await readJson(request));
      if (body === undefined) {
        respondJson(response, 400, { error: "invalid_request", message: "machineId, pairingSecret and deviceName are required." });
        return;
      }
      const ip = clientIp(request, trustedProxyAddresses);
      const key = `${ip}:${body.machineId}`;
      const now = Date.now();
      sweepPairAttempts(pairAttempts, now, pairRateWindowMs);
      sweepPairAttempts(pairIpAttempts, now, pairRateWindowMs);
      if ((!pairAttempts.has(key) && pairAttempts.size >= pairRateMaxBuckets) ||
          (!pairIpAttempts.has(ip) && pairIpAttempts.size >= pairRateMaxBuckets)) {
        respondJson(response, 429, { error: "rate_limited", message: "Pairing rate-limit capacity reached. Try again later." });
        return;
      }
      const attempt = pairAttempts.get(key);
      const ipAttempt = pairIpAttempts.get(ip);
      if ((attempt !== undefined && attempt.count >= pairRateLimit) ||
          (ipAttempt !== undefined && ipAttempt.count >= pairIpRateLimit)) {
        respondJson(response, 429, { error: "rate_limited", message: "Too many pairing attempts. Try again later." });
        return;
      }
      recordPairAttempt(pairAttempts, key, now);
      recordPairAttempt(pairIpAttempts, ip, now);
      const pairing = body.pairingCode === undefined
        ? await registry.pairDevice(body.machineId, body.pairingSecret!, body.deviceName)
        : await registry.pairDeviceWithCode(body.machineId, body.pairingCode, body.deviceName);
      if (pairing === undefined) {
        // One message for both shapes: distinguishing "expired" from "wrong"
        // would let a caller probe which codes exist.
        respondJson(response, 401, { error: "invalid_pairing_credential" });
        return;
      }
      respondJson(response, 201, pairing);
      return;
    }
    const pairingCodeMatch = /^\/v1\/machines\/([^/]+)\/pairing-codes$/.exec(url.pathname);
    if (request.method === "POST" && pairingCodeMatch !== null) {
      const machineId = decodeURIComponent(pairingCodeMatch[1]!);
      const principal = authenticateBearer(request, registry);
      // Machine token only. Minting a pairing code is the capability that lets a
      // new device in, so it stays with the machine operator instead of
      // spreading to every already-paired device.
      if (principal === undefined || principal.role !== "machine" || principal.machineId !== machineId) {
        respondJson(response, 401, { error: "unauthorized" });
        return;
      }
      const issued = registry.issuePairingCode(machineId);
      if (issued === undefined) {
        respondJson(response, 404, { error: "unknown_machine" });
        return;
      }
      respondJson(response, 201, issued);
      return;
    }
    const devicesMatch = /^\/v1\/machines\/([^/]+)\/devices$/.exec(url.pathname);
    if (request.method === "GET" && devicesMatch !== null) {
      const principal = authenticateBearer(request, registry);
      const machineId = decodeURIComponent(devicesMatch[1]!);
      // The machine may manage its own devices, and so may one of those
      // devices: the phone is usually the thing that wants to tidy the list.
      if (principal === undefined || principal.machineId !== machineId) {
        respondJson(response, 401, { error: "unauthorized" });
        return;
      }
      respondJson(response, 200, { devices: registry.listDevices(machineId) });
      return;
    }

    const revokeMatch = /^\/v1\/machines\/([^/]+)\/devices\/([^/]+)$/.exec(url.pathname);
    if (request.method === "DELETE" && revokeMatch !== null) {
      const principal = authenticateBearer(request, registry);
      const machineId = decodeURIComponent(revokeMatch[1]!);
      const deviceId = decodeURIComponent(revokeMatch[2]!);
      if (principal === undefined || principal.machineId !== machineId) {
        respondJson(response, 401, { error: "unauthorized" });
        return;
      }
      if (principal.role === "device" && principal.deviceId === deviceId) {
        // Revoking yourself would strand the caller holding a token it can no
        // longer use, with no way back in. Make it an explicit disconnect.
        respondJson(response, 409, {
          error: "self_revoke",
          message: "A device cannot revoke itself. Disconnect instead.",
        });
        return;
      }
      // Invalidate matching sockets before touching disk. Registry persistence
      // may fail; a revoked connection must never remain authorized during the
      // write or its asynchronous close handshake.
      for (const connection of connections) {
        if (connection.principal.role === "device" &&
            connection.principal.machineId === machineId &&
            connection.principal.deviceId === deviceId) {
          if (connections.delete(connection)) broadcastPresence(connection.principal, false);
          connection.ws.close(4401, "device revoked");
        }
      }
      if (!await registry.revokeDevice(machineId, deviceId)) {
        respondJson(response, 404, { error: "unknown_device" });
        return;
      }
      respondJson(response, 200, { revoked: true, deviceId });
      return;
    }

    respondJson(response, 404, { error: "not_found" });
  }

  await new Promise<void>((resolve, reject) => {
    httpServer.once("error", reject);
    httpServer.listen(options.port ?? 8787, options.host ?? "127.0.0.1", () => {
      httpServer.off("error", reject);
      resolve();
    });
  });
  const address = httpServer.address() as AddressInfo;
  return {
    registry,
    server: httpServer,
    url: `http://${address.address.includes(":") ? `[${address.address}]` : address.address}:${address.port}`,
    close: async () => {
      for (const connection of connections) connection.ws.close(1001, "Relay stopping");
      await new Promise<void>((resolve, reject) => httpServer.close((error) => error === undefined ? resolve() : reject(error)));
    },
  };
}

const presence = (principal: RelayPrincipal, online: boolean): RelayMessage => ({
  type: "relay.presence",
  machineId: principal.machineId,
  role: principal.role,
  online,
  ...(principal.role === "device" ? { deviceId: principal.deviceId } : {}),
  serverTime: Date.now(),
});

const send = (connection: RelayConnection, message: RelayMessage): void => {
  if (connection.ws.readyState !== WebSocket.OPEN) return;
  // A slow peer must not turn the Relay into an unbounded in-memory queue.
  if (connection.ws.bufferedAmount > MAX_SOCKET_BUFFER_BYTES) {
    connection.ws.close(1009, "outbound buffer limit exceeded");
    return;
  }
  connection.ws.send(JSON.stringify(message));
};

const rawDataBytes = (raw: RawData): number => {
  if (typeof raw === "string") return Buffer.byteLength(raw);
  if (raw instanceof ArrayBuffer) return raw.byteLength;
  if (Array.isArray(raw)) return raw.reduce((total, chunk) => total + chunk.byteLength, 0);
  return raw.byteLength;
};

const sendError = (connection: RelayConnection, code: string, message: string, machineId?: string, messageId?: string): void => {
  send(connection, RelayErrorMessageSchema.parse({
    type: "relay.error",
    code,
    message,
    ...(machineId === undefined ? {} : { machineId }),
    ...(messageId === undefined ? {} : { messageId }),
  }));
};

const bearerToken = (request: IncomingMessage): string | undefined => {
  const header = request.headers.authorization;
  if (typeof header !== "string") return undefined;
  const match = /^Bearer (.+)$/.exec(header);
  return match?.[1];
};

const authenticateBearer = (request: IncomingMessage, registry: Registry): RelayPrincipal | undefined => {
  const token = bearerToken(request);
  return token === undefined ? undefined : registry.authenticate(token);
};

const readJson = async (request: IncomingMessage): Promise<unknown> => {
  const chunks: Buffer[] = [];
  let length = 0;
  for await (const chunk of request) {
    const part = Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk);
    length += part.length;
    if (length > MAX_HTTP_BODY_BYTES) throw new Error("request body too large");
    chunks.push(part);
  }
  try {
    return JSON.parse(Buffer.concat(chunks).toString("utf8"));
  } catch {
    return undefined;
  }
};

const respondJson = (response: ServerResponse, status: number, value: unknown): void => {
  response.writeHead(status, { "content-type": "application/json; charset=utf-8", "cache-control": "no-store" });
  response.end(JSON.stringify(value));
};

const clientIp = (request: IncomingMessage, trustedProxies: ReadonlySet<string>): string => {
  const peer = request.socket.remoteAddress ?? "unknown";
  if (!trustedProxies.has(peer)) return peer;
  const forwarded = request.headers["x-forwarded-for"];
  const value = Array.isArray(forwarded) ? forwarded[0] : forwarded;
  const chain = value?.split(",").map((item) => item.trim()).filter((item) => item.length > 0) ?? [];
  // A trusted proxy must append the address it actually observed. Walk from
  // the right, discard any explicitly trusted proxy hops, and use the first
  // remaining valid IP. Taking the left-most value would preserve a caller's
  // forged prefix when the proxy uses `$proxy_add_x_forwarded_for`.
  for (let index = chain.length - 1; index >= 0; index -= 1) {
    const candidate = chain[index]!;
    if (isIP(candidate) === 0) continue;
    if (trustedProxies.has(candidate)) continue;
    return candidate;
  }
  return peer;
};

const sweepPairAttempts = (attempts: Map<string, PairAttempt>, now: number, windowMs: number): void => {
  for (const [key, attempt] of attempts) {
    if (now - attempt.startedAt >= windowMs) attempts.delete(key);
  }
};
const recordPairAttempt = (attempts: Map<string, PairAttempt>, key: string, now: number): void => {
  const attempt = attempts.get(key);
  if (attempt === undefined) attempts.set(key, { startedAt: now, count: 1 });
  else attempt.count += 1;
};
const isRecord = (value: unknown): value is Record<string, unknown> => typeof value === "object" && value !== null && !Array.isArray(value);
const malformedRelayRequestContext = (value: unknown): {
  machineId?: string;
  messageId?: string;
} => {
  if (!isRecord(value)) return {};
  const body = isRecord(value.body) ? value.body : undefined;
  const identifier = (candidate: unknown): string | undefined =>
    typeof candidate === "string" && candidate.length > 0 && candidate.length <= 256 ? candidate : undefined;
  // A malformed relay.payload can still carry the application request id in
  // its body. Preserve it so a client can settle the matching spinner rather
  // than waiting for a generic timeout. The wrapper id is only a fallback:
  // Relay's own `messageId` is not necessarily the app command id.
  const messageId = identifier(body?.requestId) ?? identifier(value.messageId);
  const machineId = identifier(value.machineId);
  return { ...(machineId === undefined ? {} : { machineId }), ...(messageId === undefined ? {} : { messageId }) };
};
const hasMachineId = (value: object): value is { readonly machineId: string } => "machineId" in value;
const hasDeviceId = (value: object): value is { readonly deviceId: string } => "deviceId" in value;
const samePrincipal = (left: RelayPrincipal, right: RelayPrincipal): boolean =>
  left.role === right.role && left.machineId === right.machineId &&
  (left.role === "machine" || (right.role === "device" && left.deviceId === right.deviceId));
