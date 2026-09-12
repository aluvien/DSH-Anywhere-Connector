import { randomUUID } from "node:crypto";
import { createServer, type IncomingMessage, type Server, type ServerResponse } from "node:http";
import type { AddressInfo } from "node:net";
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
/**
 * Bumped whenever the routed `WireMessage` union changes shape. The Relay
 * validates every forwarded body against that union, so a Relay older than the
 * Connector silently rejects the new event and command types. Deployment must
 * rebuild the Relay whenever this number moves.
 *
 * 3: added `assistant.reasoning`, `question.asked`, `question.resolved` events
 *    and the `question.answer` command.
 */
const RELAY_SCHEMA_REVISION = 3;

export interface RelayServerOptions {
  readonly bootstrapToken: string;
  readonly registryPath: string;
  readonly host?: string;
  readonly port?: number;
  readonly pairRateLimit?: number;
  readonly pairRateWindowMs?: number;
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

const PairDeviceRequestSchema = (value: unknown): { machineId: string; pairingSecret: string; deviceName: string } | undefined => {
  if (!isRecord(value) || Object.keys(value).length !== 3) return undefined;
  const { machineId, pairingSecret, deviceName } = value;
  if (typeof machineId !== "string" || machineId.length < 1 || machineId.length > 256) return undefined;
  if (typeof pairingSecret !== "string" || pairingSecret.length < 1 || pairingSecret.length > 1024) return undefined;
  if (typeof deviceName !== "string") return undefined;
  const name = deviceName.trim();
  return name.length >= 1 && name.length <= 256 ? { machineId, pairingSecret, deviceName: name } : undefined;
};

export async function createRelayServer(options: RelayServerOptions): Promise<RunningRelayServer> {
  if (options.bootstrapToken.trim().length === 0) throw new Error("DSH_RELAY_BOOTSTRAP_TOKEN is required");
  const registry = new Registry(options.registryPath);
  await registry.load();
  const connections = new Set<RelayConnection>();
  const pairAttempts = new Map<string, PairAttempt>();
  const pairRateLimit = options.pairRateLimit ?? 5;
  const pairRateWindowMs = options.pairRateWindowMs ?? 60_000;
  const httpServer = createServer((request, response) => {
    void handleHttp(request, response).catch((error: unknown) => {
      respondJson(response, 500, { error: "internal_error", message: error instanceof Error ? error.message : "Unexpected error" });
    });
  });
  const wss = new WebSocketServer({ noServer: true });

  httpServer.on("upgrade", (request, socket, head) => {
    const url = new URL(request.url ?? "/", "http://relay.invalid");
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
    wss.handleUpgrade(request, socket, head, (ws) => connect(ws, principal));
  });

  const connect = (ws: WebSocket, principal: RelayPrincipal): void => {
    const connection: RelayConnection = { id: randomUUID(), ws, principal };
    connections.add(connection);
    send(connection, {
      type: "relay.ready",
      machineId: principal.machineId,
      role: principal.role,
      connectionId: connection.id,
      serverTime: Date.now(),
    });
    for (const existing of connections) {
      if (existing === connection || existing.principal.machineId !== principal.machineId) continue;
      send(connection, presence(existing.principal, true));
    }
    broadcastPresence(principal, true);
    ws.on("message", (raw) => handleSocketMessage(connection, raw));
    ws.once("close", () => {
      connections.delete(connection);
      broadcastPresence(principal, false);
    });
    ws.once("error", () => undefined);
  };

  const handleSocketMessage = (source: RelayConnection, raw: RawData): void => {
    let decoded: unknown;
    try {
      decoded = JSON.parse(raw.toString());
    } catch {
      sendError(source, "invalid_json", "Relay messages must be valid JSON.");
      return;
    }
    const parsed = RelayMessageSchema.safeParse(decoded);
    if (!parsed.success) {
      sendError(source, "invalid_message", "Relay message does not match the protocol schema.");
      return;
    }
    if (parsed.data.type !== "relay.payload") {
      sendError(source, "unsupported_message", "Clients may only send relay.payload messages.");
      return;
    }
    routePayload(source, parsed.data);
  };

  const routePayload = (source: RelayConnection, payload: RelayPayloadMessage): void => {
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
        build: "2026-09-13",
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
      const key = `${clientIp(request)}:${body.machineId}`;
      const now = Date.now();
      const attempt = pairAttempts.get(key);
      if (attempt !== undefined && now - attempt.startedAt < pairRateWindowMs && attempt.count >= pairRateLimit) {
        respondJson(response, 429, { error: "rate_limited", message: "Too many pairing attempts. Try again later." });
        return;
      }
      if (attempt === undefined || now - attempt.startedAt >= pairRateWindowMs) pairAttempts.set(key, { startedAt: now, count: 1 });
      else attempt.count += 1;
      const pairing = await registry.pairDevice(body.machineId, body.pairingSecret, body.deviceName);
      if (pairing === undefined) {
        respondJson(response, 401, { error: "invalid_pairing_secret" });
        return;
      }
      respondJson(response, 201, pairing);
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
  if (connection.ws.readyState === WebSocket.OPEN) connection.ws.send(JSON.stringify(message));
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

const clientIp = (request: IncomingMessage): string => request.socket.remoteAddress ?? "unknown";
const isRecord = (value: unknown): value is Record<string, unknown> => typeof value === "object" && value !== null && !Array.isArray(value);
const hasMachineId = (value: object): value is { readonly machineId: string } => "machineId" in value;
const hasDeviceId = (value: object): value is { readonly deviceId: string } => "deviceId" in value;
