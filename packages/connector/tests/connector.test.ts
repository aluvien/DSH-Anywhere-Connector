import { describe, expect, it, vi } from "vitest";
import { PROTOCOL_VERSION } from "@dsh-anywhere/protocol";
import { DSHAnywhereConnector, backoffDelay, bridgeRequestFor } from "../src/connector.js";
import { requestPairingCode } from "../src/setup.js";
import type { ConnectorConfig } from "../src/config.js";

const config: ConnectorConfig = {
  relayURL: "ws://127.0.0.1:4100",
  machineId: "machine-1",
  machineToken: "machine-secret",
  bridgeBaseURL: "http://127.0.0.1:3080/dsh-anywhere/v1",
  bridgeToken: "bridge-secret",
};

function command(type: "session.list" | "session.create" | "prompt.send" | "turn.cancel" | "approval.decide") {
  const base = { version: PROTOCOL_VERSION, requestId: "request-1", machineId: "machine-1", deviceId: "phone-1", timestamp: 1 };
  if (type === "session.list") return { ...base, type, payload: {} } as const;
  if (type === "session.create") return { ...base, type, payload: { workingDirectory: "/tmp", initialPrompt: "hello" } } as const;
  if (type === "prompt.send") return { ...base, type, sessionId: "session-1", payload: { text: "hello" } } as const;
  if (type === "turn.cancel") return { ...base, type, sessionId: "session-1", payload: {} } as const;
  return { ...base, type, payload: { approvalId: "approval-1", allow: true } } as const;
}

describe("bridge command mapping", () => {
  it("preserves prompt requestId and maps every supported endpoint", () => {
    expect(bridgeRequestFor(command("session.list"))).toEqual({ method: "GET", path: "/sessions" });
    expect(bridgeRequestFor(command("session.create"))).toEqual({ method: "POST", path: "/sessions", body: { cwd: "/tmp" } });
    expect(bridgeRequestFor(command("prompt.send"))).toEqual({
      method: "POST", path: "/sessions/session-1/prompt", body: { text: "hello", requestId: "request-1" },
    });
    expect(bridgeRequestFor(command("turn.cancel"))).toEqual({ method: "POST", path: "/sessions/session-1/cancel", body: {} });
    expect(bridgeRequestFor(command("approval.decide"))).toEqual({
      method: "POST", path: "/approvals/approval-1/decision", body: { decision: "allowed-once" },
    });
  });

  it("uses capped exponential backoff", () => {
    expect(backoffDelay(1, 10, 100)).toBe(10);
    expect(backoffDelay(4, 10, 100)).toBe(80);
    expect(backoffDelay(8, 10, 100)).toBe(100);
  });
});

describe("Relay and bridge forwarding", () => {
  it("replays buffered bridge events after a device resume", async () => {
    const relay = new FakeSocket();
    const bridge = new FakeSocket();
    let calls = 0;
    const connector = new DSHAnywhereConnector(config, {
      webSocketFactory: () => (++calls === 1 ? relay : bridge) as unknown as import("../src/connector.js").WebSocketLike,
      logger: { info: () => undefined, warn: () => undefined },
      heartbeatMs: 60_000,
    });
    connector.start();
    relay.emit("open");
    bridge.emit("open");
    bridge.emit("message", JSON.stringify({
      version: PROTOCOL_VERSION, messageId: "event-1", machineId: "local-hostname-machine", deviceId: "broadcast", sequence: 1, timestamp: 1,
      type: "connection.ready", payload: { machineId: "local-hostname-machine", deviceId: "bridge-device", serverTime: 1, capabilities: [] },
    }));

    relay.emit("message", JSON.stringify({
      type: "relay.payload", machineId: "machine-1", messageId: "resume-1", sender: "device",
      body: { version: PROTOCOL_VERSION, requestId: "resume-1", machineId: "machine-1", deviceId: "phone-1",
        timestamp: 2, type: "connection.resume", payload: { lastSequence: 0 } },
    }));
    await vi.waitFor(() => expect(relay.sent).toHaveLength(2));
    const replayed = JSON.parse(relay.sent[1]!) as { body: { type: string; sequence: number } };
    expect(replayed).toMatchObject({
      type: "relay.payload", sender: "machine", targetDeviceId: "phone-1",
      body: { type: "connection.ready" },
    });
    // The sequence must be a clock-seeded value, not the old process-local
    // counter that restarted at 1: the phone orders its transcript by it and
    // drops anything below the last value it saw, so a reset silently loses
    // every event after a connector restart.
    expect(replayed.body.sequence).toBeGreaterThan(1_000_000_000_000);
    await connector.stop();
  });

  it("forwards events and returns a redacted protocol error for failed commands", async () => {
    const relay = new FakeSocket();
    const bridge = new FakeSocket();
    const fetchMock = vi.fn(async (_input: RequestInfo | URL) => new Response("forbidden bridge-secret", { status: 401 }));
    let calls = 0;
    const connector = new DSHAnywhereConnector(config, {
      fetch: fetchMock as unknown as typeof fetch,
      webSocketFactory: () => (++calls === 1 ? relay : bridge) as unknown as import("../src/connector.js").WebSocketLike,
      logger: { info: () => undefined, warn: () => undefined },
      heartbeatMs: 60_000,
    });
    connector.start();
    relay.emit("open");
    bridge.emit("open");
    bridge.emit("message", JSON.stringify({
      version: PROTOCOL_VERSION, messageId: "event-1", machineId: "local-hostname-machine", deviceId: "broadcast", sequence: 1, timestamp: 1,
      type: "connection.ready", payload: { machineId: "local-hostname-machine", deviceId: "bridge-device", serverTime: 1, capabilities: [] },
    }));
    expect(JSON.parse(relay.sent[0]!)).toMatchObject({
      type: "relay.payload",
      sender: "machine",
      machineId: "machine-1",
      body: { type: "connection.ready", machineId: "machine-1", payload: { machineId: "machine-1" } },
    });

    relay.emit("message", JSON.stringify({ type: "relay.ready", machineId: "machine-1", role: "machine", connectionId: "connection-1", serverTime: 1 }));
    expect(fetchMock).not.toHaveBeenCalled();
    relay.emit("message", JSON.stringify({ type: "relay.payload", machineId: "machine-1", messageId: "relay-message-1", sender: "device", body: command("prompt.send") }));
    await vi.waitFor(() => expect(fetchMock).toHaveBeenCalledOnce());
    expect(String(fetchMock.mock.calls[0]![0])).toContain("/sessions/session-1/prompt");
    await vi.waitFor(() => expect(relay.sent).toHaveLength(2));
    expect(JSON.parse(relay.sent[1]!)).toMatchObject({
      type: "relay.payload", body: { type: "protocol.error", messageId: "request-1", payload: { code: "bridge-request-failed" } },
    });
    expect(relay.sent.join(" ")).not.toContain("bridge-secret");
    await connector.stop();
  });

  it("echoes the create request id so the phone can match the reply to its tap", async () => {
    const relay = new FakeSocket();
    const bridge = new FakeSocket();
    const fetchMock = vi.fn(async () => new Response(JSON.stringify({
      sessionId: "session-9",
      summary: { id: "session-9", title: "From the phone", updatedAt: 1, cwd: "/tmp/work" },
    }), { status: 201, headers: { "content-type": "application/json" } }));
    let calls = 0;
    const connector = new DSHAnywhereConnector(config, {
      fetch: fetchMock as unknown as typeof fetch,
      webSocketFactory: () => (++calls === 1 ? relay : bridge) as unknown as import("../src/connector.js").WebSocketLike,
      logger: { info: () => undefined, warn: () => undefined },
      heartbeatMs: 60_000,
    });
    connector.start();
    relay.emit("open");
    bridge.emit("open");
    relay.emit("message", JSON.stringify({ type: "relay.ready", machineId: "machine-1", role: "machine", connectionId: "connection-1", serverTime: 1 }));

    relay.emit("message", JSON.stringify({
      type: "relay.payload", machineId: "machine-1", messageId: "relay-message-2",
      sender: "device", body: command("session.create"),
    }));

    const bodies = () => relay.sent.map((raw) => JSON.parse(raw)).map((message) => message.body);
    await vi.waitFor(() => expect(bodies().some((body) => body?.type === "session.created")).toBe(true));
    const created = bodies().find((body) => body?.type === "session.created");

    // The phone opens a new session only when this id matches the request it
    // sent. Losing it silently breaks "New session" with no error anywhere.
    expect(created.messageId).toBe("request-1");
    expect(created.sessionId).toBe("session-9");
    expect(created.payload.title).toBe("From the phone");
    await connector.stop();
  });
});

class FakeSocket {
  readyState = 1;
  readonly sent: string[] = [];
  private readonly listeners = new Map<string, Array<(...args: unknown[]) => void>>();

  send(data: string): void { this.sent.push(data); }
  close(): void { this.readyState = 3; }
  terminate(): void { this.readyState = 3; }
  ping(): void { this.emit("pong"); }
  on(event: string, listener: (...args: unknown[]) => void): this {
    const existing = this.listeners.get(event) ?? [];
    existing.push(listener);
    this.listeners.set(event, existing);
    return this;
  }
  emit(event: string, ...args: unknown[]): void {
    for (const listener of this.listeners.get(event) ?? []) listener(...args);
  }
}

describe("one-time pairing codes", () => {
  it("requests a code from the relay with the machine token", async () => {
    const calls: { url: string; method?: string | undefined; authorization?: string | undefined }[] = [];
    const fetchMock = (async (input: RequestInfo | URL, init?: RequestInit) => {
      const headers = new Headers(init?.headers);
      calls.push({ url: String(input), method: init?.method, authorization: headers.get("authorization") ?? undefined });
      return new Response(JSON.stringify({ code: "ABCD2345", expiresAt: 1_700_000_000_000 }),
        { status: 201, headers: { "content-type": "application/json" } });
    }) as unknown as typeof fetch;

    const issued = await requestPairingCode(config, fetchMock);

    expect(issued).toEqual({ code: "ABCD2345", expiresAt: 1_700_000_000_000 });
    // The stored relay URL is wss://; device management is an HTTPS API.
    expect(calls[0]!.url).toBe("http://127.0.0.1:4100/v1/machines/machine-1/pairing-codes");
    expect(calls[0]!.method).toBe("POST");
    expect(calls[0]!.authorization).toBe("Bearer machine-secret");
  });

  it("surfaces a relay refusal instead of returning a broken code", async () => {
    const fetchMock = (async () => new Response(JSON.stringify({ error: "unauthorized" }), { status: 401 })) as unknown as typeof fetch;
    // An older relay answers 404 for this route; either way the caller must not
    // be handed an empty code to display.
    await expect(requestPairingCode(config, fetchMock)).rejects.toThrow(/HTTP 401/);
  });
});
