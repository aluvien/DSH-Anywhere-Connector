import { describe, expect, it, vi } from "vitest";
import { PROTOCOL_VERSION, type CommandEnvelope } from "@dsh-anywhere/protocol";
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

function command(type: "session.list" | "session.open" | "session.create" | "prompt.send" | "turn.cancel" | "approval.decide"
  | "workspace.rename" | "workspace.delete" | "workspace.catalog" | "workspace.create"
  | "directory.list" | "mode.catalog" | "session.rename") {
  const base = { version: PROTOCOL_VERSION, requestId: "request-1", machineId: "machine-1", deviceId: "phone-1", timestamp: 1 };
  if (type === "session.list") return { ...base, type, payload: {} } as const;
  if (type === "session.open") return { ...base, type, sessionId: "session-1", payload: { sessionId: "session-1" } } as const;
  if (type === "session.create") return { ...base, type, payload: { workingDirectory: "/tmp", initialPrompt: "hello" } } as const;
  if (type === "prompt.send") return { ...base, type, sessionId: "session-1", payload: { text: "hello" } } as const;
  if (type === "turn.cancel") return { ...base, type, sessionId: "session-1", payload: {} } as const;
  if (type === "workspace.rename") return { ...base, type, payload: { workspaceId: "workspace-1", title: "Renamed" } } as const;
  if (type === "workspace.delete") return { ...base, type, payload: { workspaceId: "workspace-1" } } as const;
  if (type === "workspace.catalog" || type === "mode.catalog") return { ...base, type, payload: {} } as const;
  if (type === "workspace.create") return { ...base, type, payload: { path: "/tmp/workspace", title: "Workspace" } } as const;
  if (type === "directory.list") return { ...base, type, payload: { path: "/tmp" } } as const;
  if (type === "session.rename") return { ...base, type, sessionId: "session-1", payload: { title: "Renamed session" } } as const;
  return { ...base, type, payload: { approvalId: "approval-1", allow: true } } as const;
}

describe("bridge command mapping", () => {
  it("preserves prompt requestId and maps every supported endpoint", () => {
    expect(bridgeRequestFor(command("session.list"))).toEqual({ method: "GET", path: "/sessions" });
    expect(bridgeRequestFor({
      version: PROTOCOL_VERSION, requestId: "archives", machineId: "machine-1", deviceId: "phone-1", timestamp: 1,
      type: "session.list", payload: { includeArchived: true },
    } satisfies CommandEnvelope)).toEqual({ method: "GET", path: "/sessions?includeArchived=true" });
    expect(bridgeRequestFor(command("session.open"))).toEqual({ method: "POST", path: "/sessions/session-1/open", body: {} });
    expect(bridgeRequestFor(command("session.create"))).toEqual({ method: "POST", path: "/sessions", body: { cwd: "/tmp" } });
    expect(bridgeRequestFor({
      version: PROTOCOL_VERSION, requestId: "request-1", machineId: "machine-1", deviceId: "phone-1", timestamp: 1,
      type: "session.create", payload: { workingDirectory: "/tmp", initialPrompt: "hello", permissionMode: "danger-full-access" },
    } satisfies CommandEnvelope)).toEqual({
      method: "POST", path: "/sessions", body: { cwd: "/tmp", permissionMode: "danger-full-access" },
    });
    expect(bridgeRequestFor(command("prompt.send"))).toEqual({
      method: "POST", path: "/sessions/session-1/prompt", body: { text: "hello", requestId: "request-1" },
    });
    expect(bridgeRequestFor(command("turn.cancel"))).toEqual({ method: "POST", path: "/sessions/session-1/cancel", body: {} });
    expect(bridgeRequestFor(command("approval.decide"))).toEqual({
      method: "POST", path: "/approvals/approval-1/decision", body: { decision: "allowed-once" },
    });
    expect(bridgeRequestFor(command("workspace.rename"))).toEqual({
      method: "POST", path: "/workspaces/workspace-1/rename", body: { title: "Renamed" },
    });
    expect(bridgeRequestFor(command("workspace.delete"))).toEqual({
      method: "POST", path: "/workspaces/workspace-1/delete", body: {},
    });
    expect(bridgeRequestFor(command("workspace.catalog"))).toEqual({ method: "GET", path: "/workspaces" });
    expect(bridgeRequestFor(command("workspace.create"))).toEqual({
      method: "POST", path: "/workspaces", body: { path: "/tmp/workspace", title: "Workspace" },
    });
    expect(bridgeRequestFor(command("directory.list"))).toEqual({ method: "GET", path: "/directories?path=%2Ftmp" });
    expect(bridgeRequestFor(command("mode.catalog"))).toEqual({ method: "GET", path: "/modes" });
    expect(bridgeRequestFor(command("session.rename"))).toEqual({
      method: "POST", path: "/sessions/session-1/rename", body: { title: "Renamed session" },
    });
  });

  it("uses capped exponential backoff", () => {
    expect(backoffDelay(1, 10, 100)).toBe(10);
    expect(backoffDelay(4, 10, 100)).toBe(80);
    expect(backoffDelay(8, 10, 100)).toBe(100);
  });
});

describe("Relay and bridge forwarding", () => {
  it("drops the connector-only bridge snapshot so it cannot overwrite a phone refresh", async () => {
    const relay = new FakeSocket();
    const bridge = new FakeSocket();
    let calls = 0;
    const connector = new DSHAnywhereConnector(config, {
      webSocketFactory: () => (++calls === 1 ? relay : bridge) as unknown as import("../src/connector.js").WebSocketLike,
      logger: { info: () => undefined, warn: () => undefined }, heartbeatMs: 60_000,
    });
    connector.start(); relay.emit("open"); bridge.emit("open");
    bridge.emit("message", JSON.stringify({
      version: PROTOCOL_VERSION, messageId: "bridge-snapshot", machineId: "mac", deviceId: "dsh-anywhere-connector", sequence: 1, timestamp: 1,
      type: "session.snapshot", payload: [{ id: "stale", title: "Stale", updatedAt: 1 }],
    }));
    await new Promise((resolve) => setTimeout(resolve, 0));
    expect(relay.sent).toEqual([]);
    await connector.stop();
  });

  it("publishes one rich snapshot for a refresh instead of a stripped pre-snapshot", async () => {
    const relay = new FakeSocket();
    const bridge = new FakeSocket();
    let calls = 0;
    const connector = new DSHAnywhereConnector(config, {
      fetch: (async () => new Response(JSON.stringify({ items: [{
        id: "session-1", title: "Authoritative", updatedAt: 1, workspaceId: "workspace-1", workspaceName: "Code",
      }] }), { headers: { "content-type": "application/json" } })) as unknown as typeof fetch,
      webSocketFactory: () => (++calls === 1 ? relay : bridge) as unknown as import("../src/connector.js").WebSocketLike,
      logger: { info: () => undefined, warn: () => undefined }, heartbeatMs: 60_000,
    });
    connector.start(); relay.emit("open"); bridge.emit("open");
    relay.emit("message", JSON.stringify({ type: "relay.payload", machineId: "machine-1", messageId: "list-relay", sender: "device", body: command("session.list") }));
    await vi.waitFor(() => expect(relay.sent).toHaveLength(1));
    expect(JSON.parse(relay.sent[0]!).body).toMatchObject({
      type: "session.snapshot", messageId: "request-1",
      payload: [{ id: "session-1", workspaceId: "workspace-1", workspaceName: "Code" }],
    });
    await connector.stop();
  });

  it("keeps an archive-view refresh authoritative after an archive mutation", async () => {
    const relay = new FakeSocket();
    const bridge = new FakeSocket();
    const urls: string[] = [];
    let calls = 0;
    const connector = new DSHAnywhereConnector(config, {
      fetch: (async (input: RequestInfo | URL) => {
        urls.push(String(input));
        return new Response(JSON.stringify({ items: [] }), { headers: { "content-type": "application/json" } });
      }) as unknown as typeof fetch,
      webSocketFactory: () => (++calls === 1 ? relay : bridge) as unknown as import("../src/connector.js").WebSocketLike,
      logger: { info: () => undefined, warn: () => undefined }, heartbeatMs: 60_000,
    });
    connector.start(); relay.emit("open"); bridge.emit("open");
    const archiveList = { ...command("session.list"), requestId: "archives", payload: { includeArchived: true } };
    relay.emit("message", JSON.stringify({ type: "relay.payload", machineId: "machine-1", messageId: "archives-relay", sender: "device", body: archiveList }));
    await vi.waitFor(() => expect(urls).toContain("http://127.0.0.1:3080/dsh-anywhere/v1/sessions?includeArchived=true"));
    relay.emit("message", JSON.stringify({ type: "relay.payload", machineId: "machine-1", messageId: "archive-relay", sender: "device", body: {
      version: PROTOCOL_VERSION, requestId: "archive", machineId: "machine-1", deviceId: "phone-1", timestamp: 1,
      sessionId: "session-1", type: "session.archive", payload: { archived: true },
    } }));
    await vi.waitFor(() => expect(urls.filter((url) => url.endsWith("/sessions?includeArchived=true")).length).toBeGreaterThanOrEqual(2));
    await connector.stop();
  });

  it("routes one phone's directory listing only to that phone", async () => {
    const relay = new FakeSocket();
    const bridge = new FakeSocket();
    let calls = 0;
    const connector = new DSHAnywhereConnector(config, {
      fetch: (async () => new Response(JSON.stringify({
        path: "/Users/me", parentPath: "/Users", directories: [{ name: "Code", path: "/Users/me/Code" }],
      }), { headers: { "content-type": "application/json" } })) as unknown as typeof fetch,
      webSocketFactory: () => (++calls === 1 ? relay : bridge) as unknown as import("../src/connector.js").WebSocketLike,
      logger: { info: () => undefined, warn: () => undefined }, heartbeatMs: 60_000,
    });
    connector.start(); relay.emit("open"); bridge.emit("open");
    const listing = { ...command("directory.list"), deviceId: "phone-folder", requestId: "folder-list" };
    relay.emit("message", JSON.stringify({ type: "relay.payload", machineId: "machine-1", messageId: "folder-relay", sender: "device", body: listing }));
    await vi.waitFor(() => expect(relay.sent).toHaveLength(1));
    expect(JSON.parse(relay.sent[0]!)).toMatchObject({ targetDeviceId: "phone-folder", body: {
      type: "directory.list", messageId: "folder-list", payload: { path: "/Users/me" },
    } });
    await connector.stop();
  });

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

  it("routes transient streaming only to an opted-in opener and keeps replay safe for legacy devices", async () => {
    const relay = new FakeSocket();
    const bridge = new FakeSocket();
    const fetchMock = vi.fn(async () => new Response(JSON.stringify({ accepted: true }), {
      status: 202, headers: { "content-type": "application/json" },
    }));
    let calls = 0;
    const connector = new DSHAnywhereConnector(config, {
      fetch: fetchMock as unknown as typeof fetch,
      webSocketFactory: () => (++calls === 1 ? relay : bridge) as unknown as import("../src/connector.js").WebSocketLike,
      logger: { info: () => undefined, warn: () => undefined }, heartbeatMs: 60_000,
    });
    connector.start(); relay.emit("open"); bridge.emit("open");

    relay.emit("message", JSON.stringify({
      type: "relay.payload", machineId: "machine-1", messageId: "open-stream", sender: "device",
      body: {
        version: PROTOCOL_VERSION, requestId: "open-stream", machineId: "machine-1", deviceId: "phone-stream",
        sessionId: "session-1", timestamp: 1, type: "session.open",
        payload: { sessionId: "session-1", streaming: true },
      },
    }));
    await vi.waitFor(() => expect(fetchMock).toHaveBeenCalledOnce());

    bridge.emit("message", JSON.stringify({
      version: PROTOCOL_VERSION, messageId: "delta", machineId: "mac", deviceId: "broadcast", sequence: 1, timestamp: 1,
      sessionId: "session-1", type: "assistant.message.delta", payload: { messageId: "stream-1", text: "hel" },
    }));
    bridge.emit("message", JSON.stringify({
      version: PROTOCOL_VERSION, messageId: "final", machineId: "mac", deviceId: "broadcast", sequence: 2, timestamp: 2,
      sessionId: "session-1", type: "assistant.message.completed",
      payload: { id: "assistant-1", role: "assistant", markdown: "hello", replacesMessageId: "stream-1" },
    }));
    await vi.waitFor(() => expect(relay.sent).toHaveLength(3));
    const delivered = relay.sent.map((raw) => JSON.parse(raw));
    expect(delivered[0]).toMatchObject({ targetDeviceId: "phone-stream", body: {
      type: "assistant.message.delta", deviceId: "phone-stream", payload: { messageId: "stream-1" },
    } });
    expect(delivered[1]).toMatchObject({ targetDeviceId: "phone-stream", body: {
      type: "assistant.message.completed", deviceId: "phone-stream", payload: { replacesMessageId: "stream-1" },
    } });
    expect(delivered[2]).toMatchObject({ body: {
      type: "assistant.message.completed", deviceId: "broadcast", payload: { id: "assistant-1", markdown: "hello" },
    } });
    expect(delivered[2].targetDeviceId).toBeUndefined();
    expect(delivered[2].body.payload.replacesMessageId).toBeUndefined();

    relay.emit("message", JSON.stringify({
      type: "relay.payload", machineId: "machine-1", messageId: "legacy-resume", sender: "device",
      body: {
        version: PROTOCOL_VERSION, requestId: "legacy-resume", machineId: "machine-1", deviceId: "phone-legacy",
        timestamp: 3, type: "connection.resume", payload: { lastSequence: 0 },
      },
    }));
    await vi.waitFor(() => expect(relay.sent.length).toBeGreaterThanOrEqual(5));
    const legacy = relay.sent.slice(3).map((raw) => JSON.parse(raw));
    expect(legacy.some((message) => message.body?.type === "assistant.message.delta"
      || message.body?.payload?.replacesMessageId !== undefined)).toBe(false);
    expect(legacy.some((message) => message.body?.type === "assistant.message.completed")).toBe(true);
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
