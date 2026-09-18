import { mkdtemp, readFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { WebSocket } from "ws";
import { afterEach, describe, expect, it } from "vitest";
import { PROTOCOL_VERSION, type RelayMessage } from "@dsh-anywhere/protocol";
import { createRelayServer, type RunningRelayServer } from "../src/server.js";
import { Registry } from "../src/registry.js";

interface Registration {
  readonly machineId: string;
  readonly machineToken: string;
  readonly pairingSecret: string;
}

interface Pairing {
  readonly deviceId: string;
  readonly deviceToken: string;
  readonly machineName: string;
}

const servers: RunningRelayServer[] = [];
const directories: string[] = [];

afterEach(async () => {
  await Promise.all(servers.splice(0).map((server) => server.close()));
  await Promise.all(directories.splice(0).map((directory) => rm(directory, { recursive: true, force: true })));
});

async function relay(pairRateLimit?: number, trustedProxyAddresses?: readonly string[]): Promise<RunningRelayServer> {
  const directory = await mkdtemp(join(tmpdir(), "dsh-anywhere-relay-"));
  directories.push(directory);
  const server = await createRelayServer({
    bootstrapToken: "bootstrap-token",
    registryPath: join(directory, "registry.json"),
    host: "127.0.0.1",
    port: 0,
    ...(pairRateLimit === undefined ? {} : { pairRateLimit }),
    ...(trustedProxyAddresses === undefined ? {} : { trustedProxyAddresses }),
  });
  servers.push(server);
  return server;
}

async function post<T>(base: string, path: string, body: unknown, token?: string): Promise<{ status: number; body: T }> {
  const response = await fetch(`${base}${path}`, {
    method: "POST",
    headers: { "content-type": "application/json", ...(token === undefined ? {} : { authorization: `Bearer ${token}` }) },
    body: JSON.stringify(body),
  });
  return { status: response.status, body: await response.json() as T };
}

async function register(base: string, machineName: string): Promise<Registration> {
  const result = await post<Registration>(base, "/v1/machines/register", { machineName }, "bootstrap-token");
  expect(result.status).toBe(201);
  return result.body;
}

async function pair(base: string, machine: Registration, deviceName = "iPhone"): Promise<Pairing> {
  const result = await post<Pairing>(base, "/v1/pair", {
    machineId: machine.machineId,
    pairingSecret: machine.pairingSecret,
    deviceName,
  });
  expect(result.status).toBe(201);
  return result.body;
}

const wsUrl = (base: string): string => base.replace(/^http/, "ws") + "/v1/connect";

async function connect(base: string, token: string): Promise<WebSocket> {
  const socket = new WebSocket(wsUrl(base), { headers: { authorization: `Bearer ${token}` } });
  await once(socket, "open");
  return socket;
}

function messages(socket: WebSocket): RelayMessage[] {
  const received: RelayMessage[] = [];
  socket.on("message", (raw) => received.push(JSON.parse(raw.toString()) as RelayMessage));
  return received;
}

async function waitForMessage(received: RelayMessage[], type: RelayMessage["type"], timeoutMs = 1_000): Promise<RelayMessage> {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const match = received.find((message) => message.type === type);
    if (match !== undefined) return match;
    await new Promise((resolve) => setTimeout(resolve, 5));
  }
  throw new Error(`Timed out waiting for ${type}; received: ${JSON.stringify(received)}`);
}

function once(socket: WebSocket, event: "open"): Promise<void> {
  return new Promise((resolve, reject) => {
    socket.once(event, () => resolve());
    socket.once("error", reject);
  });
}

function payload(machineId: string, sender: "machine" | "device", deviceId: string, targetDeviceId?: string): Record<string, unknown> {
  return {
    type: "relay.payload",
    machineId,
    messageId: crypto.randomUUID(),
    sender,
    ...(targetDeviceId === undefined ? {} : { targetDeviceId }),
    body: {
      version: PROTOCOL_VERSION,
      requestId: crypto.randomUUID(),
      machineId,
      deviceId,
      timestamp: Date.now(),
      type: "session.list",
      payload: {},
    },
  };
}

/** A relay.payload carrying an arbitrary body, for schema-carriage tests. */
function relayed(machineId: string, sender: "machine" | "device", deviceId: string,
                 body: unknown, targetDeviceId?: string): Record<string, unknown> {
  return {
    type: "relay.payload",
    machineId,
    messageId: crypto.randomUUID(),
    sender,
    ...(targetDeviceId === undefined ? {} : { targetDeviceId }),
    body,
  };
}

describe("Relay server", () => {
  it("registers machines and writes only credential hashes to its persistent registry", async () => {
    const server = await relay();
    const rejected = await post<{ error: string }>(server.url, "/v1/machines/register", { machineName: "Mac" }, "wrong-token");
    expect(rejected.status).toBe(401);

    const machine = await register(server.url, "MacBook");
    const registryText = await readFile(join(directories[0]!, "registry.json"), "utf8");
    expect(registryText).toContain(machine.machineId);
    expect(registryText).not.toContain(machine.machineToken);
    expect(registryText).not.toContain(machine.pairingSecret);
  });

  it("routes payloads only within the authenticated machine", async () => {
    const server = await relay();
    const machineA = await register(server.url, "Mac A");
    const machineB = await register(server.url, "Mac B");
    const deviceA = await pair(server.url, machineA);
    const deviceB = await pair(server.url, machineB);
    const machineSocketA = await connect(server.url, machineA.machineToken);
    const machineSocketB = await connect(server.url, machineB.machineToken);
    const deviceSocketA = await connect(server.url, deviceA.deviceToken);
    const deviceSocketB = await connect(server.url, deviceB.deviceToken);
    const machineMessagesA = messages(machineSocketA);
    const machineMessagesB = messages(machineSocketB);
    messages(deviceSocketA);
    messages(deviceSocketB);

    deviceSocketA.send(JSON.stringify(payload(machineA.machineId, "device", deviceA.deviceId)));
    const delivered = await waitForMessage(machineMessagesA, "relay.payload");
    expect(delivered.type === "relay.payload" && delivered.machineId).toBe(machineA.machineId);
    await new Promise((resolve) => setTimeout(resolve, 50));
    expect(machineMessagesB.some((message) => message.type === "relay.payload")).toBe(false);

    for (const socket of [machineSocketA, machineSocketB, deviceSocketA, deviceSocketB]) socket.close();
  });

  it("keeps only the newest Connector lease for a machine", async () => {
    const server = await relay();
    const machine = await register(server.url, "Mac");
    const device = await pair(server.url, machine);
    const firstMachineSocket = await connect(server.url, machine.machineToken);
    const firstClosed = new Promise<number>((resolve) => firstMachineSocket.once("close", (code) => resolve(code)));
    const secondMachineSocket = await connect(server.url, machine.machineToken);
    const secondMessages = messages(secondMachineSocket);
    const deviceSocket = await connect(server.url, device.deviceToken);

    await expect(firstClosed).resolves.toBe(4001);
    deviceSocket.send(JSON.stringify(payload(machine.machineId, "device", device.deviceId)));
    await waitForMessage(secondMessages, "relay.payload");

    for (const socket of [secondMachineSocket, deviceSocket]) socket.close();
  });

  // The Relay validates every routed body against the strict WireMessage union
  // before forwarding it: an unknown event or command type is answered with
  // `invalid_message` instead of being routed. A Relay image built before these
  // types existed therefore drops them. This test only proves the current
  // source can carry them — catching a stale deployment is what
  // RELAY_SCHEMA_REVISION on /health is for.
  it("carries the bodies the phone answers questions with", async () => {
    const server = await relay();
    const machine = await register(server.url, "Mac");
    const device = await pair(server.url, machine);
    const machineSocket = await connect(server.url, machine.machineToken);
    const deviceSocket = await connect(server.url, device.deviceToken);
    const machineMessages = messages(machineSocket);
    const deviceMessages = messages(deviceSocket);

    machineSocket.send(JSON.stringify(relayed(machine.machineId, "machine", device.deviceId, {
      version: PROTOCOL_VERSION,
      messageId: crypto.randomUUID(),
      machineId: machine.machineId,
      deviceId: device.deviceId,
      sessionId: "session-1",
      sequence: 1,
      timestamp: Date.now(),
      type: "question.asked",
      payload: {
        id: "question_1",
        sessionId: "session-1",
        questions: [{ id: "mode", question: "Which mode?", options: [{ label: "Fast" }] }],
      },
    }, device.deviceId)));
    const asked = await waitForMessage(deviceMessages, "relay.payload");
    expect(asked.type === "relay.payload" ? asked.body.type : undefined).toBe("question.asked");

    // Drain before the next hop so the assertions read this send, not the
    // buffered one before it.
    deviceMessages.length = 0;
    machineSocket.send(JSON.stringify(relayed(machine.machineId, "machine", device.deviceId, {
      version: PROTOCOL_VERSION,
      messageId: crypto.randomUUID(),
      machineId: machine.machineId,
      deviceId: device.deviceId,
      sessionId: "session-1",
      sequence: 2,
      timestamp: Date.now(),
      type: "assistant.reasoning",
      payload: { messageId: "a1", text: "Thinking about it." },
    }, device.deviceId)));
    const reasoning = await waitForMessage(deviceMessages, "relay.payload");
    expect(reasoning.type === "relay.payload" ? reasoning.body.type : undefined).toBe("assistant.reasoning");

    deviceSocket.send(JSON.stringify(relayed(machine.machineId, "device", device.deviceId, {
      version: PROTOCOL_VERSION,
      requestId: crypto.randomUUID(),
      machineId: machine.machineId,
      deviceId: device.deviceId,
      timestamp: Date.now(),
      type: "question.answer",
      payload: { questionId: "question_1", answers: [{ id: "mode", selected: ["Fast"] }] },
    })));
    const answered = await waitForMessage(machineMessages, "relay.payload");
    expect(answered.type === "relay.payload" ? answered.body.type : undefined).toBe("question.answer");

    for (const socket of [machineSocket, deviceSocket]) socket.close();
  });

  it("can target a replay payload to one of several devices", async () => {
    const server = await relay();
    const machine = await register(server.url, "Mac");
    const deviceA = await pair(server.url, machine, "iPhone A");
    const deviceB = await pair(server.url, machine, "iPhone B");
    const machineSocket = await connect(server.url, machine.machineToken);
    const deviceSocketA = await connect(server.url, deviceA.deviceToken);
    const deviceSocketB = await connect(server.url, deviceB.deviceToken);
    const messagesA = messages(deviceSocketA);
    const messagesB = messages(deviceSocketB);

    machineSocket.send(JSON.stringify(payload(machine.machineId, "machine", deviceA.deviceId, deviceB.deviceId)));
    await waitForMessage(messagesB, "relay.payload");
    await new Promise((resolve) => setTimeout(resolve, 50));
    expect(messagesA.some((message) => message.type === "relay.payload")).toBe(false);

    for (const socket of [machineSocket, deviceSocketA, deviceSocketB]) socket.close();
  });

  it("rejects unauthorized websocket clients and reports unavailable targets", async () => {
    const server = await relay();
    const machine = await register(server.url, "Mac");
    const device = await pair(server.url, machine);
    expect(device.machineName).toBe("Mac");
    const rejected = new WebSocket(wsUrl(server.url), { headers: { authorization: "Bearer bad-token" } });
    await expect(new Promise<void>((resolve, reject) => {
      rejected.once("unexpected-response", () => resolve());
      rejected.once("open", () => reject(new Error("unexpected connection")));
      rejected.once("error", () => resolve());
    })).resolves.toBeUndefined();

    const deviceSocket = await connect(server.url, device.deviceToken);
    const received = messages(deviceSocket);
    deviceSocket.send(JSON.stringify(payload(machine.machineId, "device", device.deviceId)));
    const error = await waitForMessage(received, "relay.error");
    expect(error.type === "relay.error" && error.code).toBe("target_unavailable");
    deviceSocket.close();
  });

  it("limits pairing attempts per address and machine", async () => {
    const server = await relay(1);
    const machine = await register(server.url, "Mac");
    const first = await post<Pairing>(server.url, "/v1/pair", {
      machineId: machine.machineId,
      pairingSecret: "incorrect",
      deviceName: "iPhone",
    });
    expect(first.status).toBe(401);
    const second = await post<{ error: string }>(server.url, "/v1/pair", {
      machineId: machine.machineId,
      pairingSecret: machine.pairingSecret,
      deviceName: "iPhone",
    });
    expect(second.status).toBe(429);
  });

  it("uses forwarded client addresses only from an explicitly trusted proxy", async () => {
    const server = await relay(1, ["127.0.0.1"]);
    const machine = await register(server.url, "Mac");
    const attempt = async (ip: string, pairingSecret: string) => {
      const response = await fetch(`${server.url}/v1/pair`, {
        method: "POST",
        headers: { "content-type": "application/json", "x-forwarded-for": ip },
        body: JSON.stringify({ machineId: machine.machineId, pairingSecret, deviceName: "iPhone" }),
      });
      return response.status;
    };

    expect(await attempt("203.0.113.10", "incorrect")).toBe(401);
    expect(await attempt("203.0.113.11", machine.pairingSecret)).toBe(201);
  });

  it("uses the right-most proxy-appended address instead of a forged XFF prefix", async () => {
    const server = await relay(1, ["127.0.0.1"]);
    const machine = await register(server.url, "Mac");
    const attempt = async (forwarded: string, pairingSecret: string) => {
      const response = await fetch(`${server.url}/v1/pair`, {
        method: "POST",
        headers: { "content-type": "application/json", "x-forwarded-for": forwarded },
        body: JSON.stringify({ machineId: machine.machineId, pairingSecret, deviceName: "iPhone" }),
      });
      return response.status;
    };

    expect(await attempt("198.51.100.1, 203.0.113.10", "incorrect")).toBe(401);
    // Changing a caller-controlled prefix must not create a fresh bucket for
    // the same source address appended by the trusted proxy.
    expect(await attempt("198.51.100.99, 203.0.113.10", machine.pairingSecret)).toBe(429);
  });

  async function devices(base: string, machineId: string, token: string) {
    const response = await fetch(`${base}/v1/machines/${machineId}/devices`, {
      headers: { authorization: `Bearer ${token}` },
    });
    return { status: response.status, body: await response.json() as { devices?: { deviceId: string; name: string }[] } };
  }

  async function revoke(base: string, machineId: string, deviceId: string, token: string) {
    const response = await fetch(`${base}/v1/machines/${machineId}/devices/${deviceId}`, {
      method: "DELETE",
      headers: { authorization: `Bearer ${token}` },
    });
    return { status: response.status, body: await response.json() as { error?: string } };
  }

  it("lists a machine's devices without ever returning credential material", async () => {
    const server = await relay();
    const machine = await register(server.url, "Mac");
    await pair(server.url, machine, "iPhone A");
    await pair(server.url, machine, "iPhone B");

    const listed = await devices(server.url, machine.machineId, machine.machineToken);

    expect(listed.status).toBe(200);
    expect(listed.body.devices?.map((device) => device.name)).toEqual(["iPhone A", "iPhone B"]);
    // Only hashes are stored, and nothing credential-shaped may be echoed back.
    expect(JSON.stringify(listed.body)).not.toContain("token");
  });

  it("lets one device of a machine revoke a sibling, but not itself", async () => {
    const server = await relay();
    const machine = await register(server.url, "Mac");
    const phoneA = await pair(server.url, machine, "iPhone A");
    const phoneB = await pair(server.url, machine, "iPhone B");

    // A device may tidy up its siblings, which is the common case: the phone is
    // what usually manages the list.
    const removed = await revoke(server.url, machine.machineId, phoneB.deviceId, phoneA.deviceToken);
    expect(removed.status).toBe(200);

    // The revoked credential must stop working immediately.
    const rejected = await devices(server.url, machine.machineId, phoneB.deviceToken);
    expect(rejected.status).toBe(401);

    // Revoking yourself would strand the caller with a token it cannot use and
    // no way back in, so it is refused rather than silently locking it out.
    const self = await revoke(server.url, machine.machineId, phoneA.deviceId, phoneA.deviceToken);
    expect(self.status).toBe(409);
    expect(self.body.error).toBe("self_revoke");
  });

  it("keeps device management inside one machine", async () => {
    const server = await relay();
    const machineA = await register(server.url, "Mac A");
    const machineB = await register(server.url, "Mac B");
    const phoneA = await pair(server.url, machineA, "iPhone A");

    // Machine B holds a valid token, but not for machine A's devices.
    expect((await devices(server.url, machineA.machineId, machineB.machineToken)).status).toBe(401);
    expect((await revoke(server.url, machineA.machineId, phoneA.deviceId, machineB.machineToken)).status).toBe(401);
    // Unknown ids are 404, not a cross-machine success.
    expect((await revoke(server.url, machineA.machineId, "device_missing", machineA.machineToken)).status).toBe(404);
    expect((await devices(server.url, machineA.machineId, "nonsense")).status).toBe(401);
  });

  it("mints a one-time code that pairs exactly once and only for its machine", async () => {
    const server = await relay();
    const machineA = await register(server.url, "Mac A");
    const machineB = await register(server.url, "Mac B");

    const minted = await post<{ code: string; expiresAt: number }>(
      server.url, `/v1/machines/${machineA.machineId}/pairing-codes`, {}, machineA.machineToken);
    expect(minted.status).toBe(201);
    // No 0/O/1/I/L: a human reads this off a screen.
    expect(minted.body.code).toMatch(/^[A-HJ-KM-NP-Z2-9]{8}$/);

    const phoneA = await pair(server.url, machineA, "iPhone A");
    // Minting is the capability that lets a new device in, so an already-paired
    // device must not be able to hand out more.
    expect((await post(server.url, `/v1/machines/${machineA.machineId}/pairing-codes`, {}, phoneA.deviceToken)).status).toBe(401);
    // Nor may another machine mint for this one.
    expect((await post(server.url, `/v1/machines/${machineA.machineId}/pairing-codes`, {}, machineB.machineToken)).status).toBe(401);

    const paired = await post<{ deviceToken: string }>(server.url, "/v1/pair",
      { machineId: machineA.machineId, pairingCode: minted.body.code, deviceName: "iPhone B" });
    expect(paired.status).toBe(201);

    // Single use: replaying the same code must not mint a second device.
    expect((await post(server.url, "/v1/pair",
      { machineId: machineA.machineId, pairingCode: minted.body.code, deviceName: "iPhone C" })).status).toBe(401);
    // Nor may it be redirected at a different machine.
    expect((await post(server.url, "/v1/pair",
      { machineId: machineB.machineId, pairingCode: minted.body.code, deviceName: "iPhone D" })).status).toBe(401);
  });

  it("rejects ambiguous pairing requests that contain both credential forms", async () => {
    const server = await relay();
    const machine = await register(server.url, "Mac");
    const minted = await post<{ code: string }>(
      server.url, `/v1/machines/${machine.machineId}/pairing-codes`, {}, machine.machineToken,
    );
    expect(minted.status).toBe(201);
    const result = await post<{ error: string }>(server.url, "/v1/pair", {
      machineId: machine.machineId,
      pairingSecret: machine.pairingSecret,
      pairingCode: minted.body.code,
      deviceName: "iPhone",
    });
    expect(result.status).toBe(400);
    expect(result.body.error).toBe("invalid_request");
  });

  it("keeps the long-lived pairing secret working", async () => {
    const server = await relay();
    const machine = await register(server.url, "Mac");
    const legacy = await post<{ deviceToken: string }>(server.url, "/v1/pair",
      { machineId: machine.machineId, pairingSecret: machine.pairingSecret, deviceName: "Old client" });
    // Adding one-time codes must not force every existing install to re-pair.
    expect(legacy.status).toBe(201);
  });

  it("expires a pairing code instead of honouring it late", async () => {
    const directory = await mkdtemp(join(tmpdir(), "dsh-anywhere-registry-"));
    directories.push(directory);
    const registry = new Registry(join(directory, "registry.json"));
    await registry.load();
    const machine = await registry.registerMachine("Mac");

    const stale = registry.issuePairingCode(machine.machineId, 1_000, 500)!;
    expect(await registry.pairDeviceWithCode(machine.machineId, stale.code, "iPhone", 2_000)).toBeUndefined();

    const fresh = registry.issuePairingCode(machine.machineId, 3_000, 500)!;
    expect(await registry.pairDeviceWithCode(machine.machineId, fresh.code, "iPhone", 3_100)).toBeDefined();
    expect(await registry.pairDeviceWithCode(machine.machineId, fresh.code, "iPhone 2", 3_200)).toBeUndefined();
  });
});
