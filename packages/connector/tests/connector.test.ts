import { describe, expect, it, vi } from "vitest";
import { PROTOCOL_VERSION, type CommandEnvelope } from "@dsh-anywhere/protocol";
import { DSHAnywhereConnector, backoffDelay, bridgeRequestFor, bridgeTimeoutFor } from "../src/connector.js";
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
    expect(bridgeRequestFor(command("session.list"))).toEqual({ method: "GET", path: "/sessions?deviceId=phone-1" });
    expect(bridgeRequestFor({
      version: PROTOCOL_VERSION, requestId: "archives", machineId: "machine-1", deviceId: "phone-1", timestamp: 1,
      type: "session.list", payload: { includeArchived: true },
    } satisfies CommandEnvelope)).toEqual({ method: "GET", path: "/sessions?includeArchived=true&deviceId=phone-1" });
    expect(bridgeRequestFor(command("session.open"))).toEqual({ method: "POST", path: "/sessions/session-1/open", body: { deviceId: "phone-1" } });
    expect(bridgeRequestFor(command("session.create"))).toEqual({
      method: "POST", path: "/sessions",
      headers: { "x-dsh-origin-device-id": "phone-1" },
      body: { deviceId: "phone-1", cwd: "/tmp" },
    });
    expect(bridgeRequestFor({
      version: PROTOCOL_VERSION, requestId: "request-1", machineId: "machine-1", deviceId: "phone-1", timestamp: 1,
      type: "session.create", payload: { workingDirectory: "/tmp", initialPrompt: "hello", permissionMode: "danger-full-access" },
    } satisfies CommandEnvelope)).toEqual({
      method: "POST", path: "/sessions",
      headers: { "x-dsh-origin-device-id": "phone-1" },
      body: { deviceId: "phone-1", cwd: "/tmp", permissionMode: "danger-full-access" },
    });
    expect(bridgeRequestFor(command("prompt.send"))).toEqual({
      method: "POST", path: "/sessions/session-1/prompt",
      body: { text: "hello", deviceId: "phone-1", requestId: "request-1" },
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

  it("keeps the Connector deadline outside long-running Harness commands", () => {
    const execute = {
      version: PROTOCOL_VERSION, requestId: "execute", machineId: "machine-1", deviceId: "phone-1", timestamp: 1,
      sessionId: "session-1", type: "command.execute", payload: { line: "/slow" },
    } satisfies CommandEnvelope;
    expect(bridgeTimeoutFor(execute)).toBe(125_000);
    expect(bridgeTimeoutFor(command("session.list"))).toBe(15_000);
  });

  it("stops instead of reclaiming a Relay lease after supersession", async () => {
    const relay = new FakeSocket();
    const bridge = new FakeSocket();
    let sockets = 0;
    const connector = new DSHAnywhereConnector(config, {
      webSocketFactory: () => (++sockets === 1 ? relay : bridge) as unknown as import("../src/connector.js").WebSocketLike,
      logger: { info: () => undefined, warn: () => undefined }, reconnectBaseMs: 1, heartbeatMs: 60_000,
    });
    connector.start();
    relay.emit("open");
    bridge.emit("open");
    relay.emit("close", 4001);
    await vi.waitFor(() => expect(connector.status).toBe("stopped"));
    await new Promise((resolve) => setTimeout(resolve, 10));
    expect(sockets).toBe(2);
  });
});

describe("Relay and bridge forwarding", () => {
  it("reports real Relay device presence to the local approval bridge", async () => {
    const relay = new FakeSocket();
    const bridge = new FakeSocket();
    const calls: Array<{ url: string; body?: string }> = [];
    let sockets = 0;
    const connector = new DSHAnywhereConnector(config, {
      fetch: (async (input: RequestInfo | URL, init?: RequestInit) => {
        calls.push({ url: String(input), ...(typeof init?.body === "string" ? { body: init.body } : {}) });
        return new Response(JSON.stringify(new URL(String(input)).pathname.endsWith("/sessions") ? { items: [] } : { accepted: true }), {
          headers: { "content-type": "application/json" },
        });
      }) as unknown as typeof fetch,
      webSocketFactory: () => (++sockets === 1 ? relay : bridge) as unknown as import("../src/connector.js").WebSocketLike,
      logger: { info: () => undefined, warn: () => undefined }, heartbeatMs: 60_000,
    });
    connector.start(); relay.emit("open"); bridge.emit("open");
    relay.emit("message", JSON.stringify({
      type: "relay.ready", machineId: "machine-1", role: "machine", connectionId: "connection-1",
      serverTime: 1, leaseGeneration: 1, relayEpoch: "relay-1",
    }));
    relay.emit("message", JSON.stringify({
      type: "relay.presence", machineId: "machine-1", role: "device", deviceId: "phone-1", online: true, serverTime: 1,
    }));
    await vi.waitFor(() => expect(calls.some((call) => call.url.endsWith("/devices/phone-1/presence")
      && JSON.parse(call.body ?? "{}").online === true)).toBe(true));
    relay.emit("message", JSON.stringify({
      type: "relay.presence", machineId: "machine-1", role: "device", deviceId: "phone-1", online: false, serverTime: 2,
    }));
    await vi.waitFor(() => expect(calls.some((call) => call.url.endsWith("/devices/phone-1/presence")
      && JSON.parse(call.body ?? "{}").online === false)).toBe(true));
    await connector.stop();
  });

  it("coalesces duplicate request ids before a local side effect", async () => {
    const relay = new FakeSocket();
    const bridge = new FakeSocket();
    const fetchMock = vi.fn(async () => new Response(JSON.stringify({
      sessionId: "session-once", summary: { id: "session-once", title: "Once", updatedAt: 1 },
    }), { status: 201, headers: { "content-type": "application/json" } }));
    let calls = 0;
    const connector = new DSHAnywhereConnector(config, {
      fetch: fetchMock as unknown as typeof fetch,
      webSocketFactory: () => (++calls === 1 ? relay : bridge) as unknown as import("../src/connector.js").WebSocketLike,
      logger: { info: () => undefined, warn: () => undefined }, heartbeatMs: 60_000,
    });
    connector.start(); relay.emit("open"); bridge.emit("open");
    const duplicate = JSON.stringify({
      type: "relay.payload", machineId: "machine-1", messageId: "relay-copy", sender: "device",
      body: command("session.create"),
    });
    relay.emit("message", duplicate);
    relay.emit("message", duplicate);

    await vi.waitFor(() => expect(fetchMock).toHaveBeenCalledOnce());
    const requestInit = (fetchMock.mock.calls as unknown as [unknown, RequestInit?][])[0]![1];
    expect(new Headers(requestInit?.headers).get("x-dsh-request-id")).toBe("request-1");
    await vi.waitFor(() => expect(relay.sent.map((raw) => JSON.parse(raw))
      .some((message) => message.body?.type === "session.created")).toBe(true));
    const firstResult = relay.sent.map((raw) => JSON.parse(raw)).find((message) => message.body?.type === "session.created")!;
    for (let index = 0; index < 4; index += 1) {
      bridge.emit("message", JSON.stringify({
        version: PROTOCOL_VERSION, messageId: `later-${index}`, machineId: "mac", deviceId: "broadcast",
        sequence: index + 1, timestamp: index + 1, type: "connection.ready",
        payload: { machineId: "mac", deviceId: "dsh-anywhere-connector", serverTime: index + 1, capabilities: [] },
      }));
    }
    relay.emit("message", duplicate);
    await vi.waitFor(() => expect(relay.sent.filter((raw) => JSON.parse(raw).body?.type === "session.created")).toHaveLength(2));
    const replayedResult = relay.sent.map((raw) => JSON.parse(raw)).filter((message) => message.body?.type === "session.created")[1];
    expect(replayedResult.body.sequence).toBeGreaterThan(firstResult.body.sequence);
    await connector.stop();
  });

  it("retries a failed request with the same idempotency key after a duplicate delivery", async () => {
    const relay = new FakeSocket();
    const bridge = new FakeSocket();
    const requests: RequestInit[] = [];
    let attempt = 0;
    const fetchMock = vi.fn(async (_input: RequestInfo | URL, init?: RequestInit) => {
      requests.push(init ?? {});
      attempt += 1;
      if (attempt === 1) throw new Error("bridge temporarily unavailable");
      return new Response(JSON.stringify({
        sessionId: "session-recovered", summary: { id: "session-recovered", title: "Recovered", updatedAt: 1 },
      }), { status: 201, headers: { "content-type": "application/json" } });
    });
    let sockets = 0;
    const connector = new DSHAnywhereConnector(config, {
      fetch: fetchMock as unknown as typeof fetch,
      webSocketFactory: () => (++sockets === 1 ? relay : bridge) as unknown as import("../src/connector.js").WebSocketLike,
      logger: { info: () => undefined, warn: () => undefined }, heartbeatMs: 60_000,
    });
    connector.start(); relay.emit("open"); bridge.emit("open");
    const duplicate = JSON.stringify({
      type: "relay.payload", machineId: "machine-1", messageId: "retry-copy", sender: "device",
      body: { ...command("session.create"), payload: { workingDirectory: "/tmp" } },
    });
    relay.emit("message", duplicate);
    await vi.waitFor(() => expect(fetchMock).toHaveBeenCalledOnce());
    await vi.waitFor(() => expect(relay.sent.map((raw) => JSON.parse(raw))
      .some((message) => message.body?.type === "protocol.error")).toBe(true));
    // A mobile reconnect can resend the same command after seeing the first
    // protocol error. The Connector must retry the same request id, allowing
    // the Bridge's idempotency store to return an already-accepted result.
    relay.emit("message", duplicate);
    await vi.waitFor(() => expect(fetchMock).toHaveBeenCalledTimes(2));
    expect(requests.map((init) => new Headers(init.headers).get("x-dsh-request-id"))).toEqual([
      "request-1", "request-1",
    ]);
    await vi.waitFor(() => expect(relay.sent.map((raw) => JSON.parse(raw))
      .some((message) => message.body?.type === "session.created"
        && message.body?.sessionId === "session-recovered")).toBe(true));
    await connector.stop();
  });

  it("emits and replays a targeted prompt acceptance receipt", async () => {
    const relay = new FakeSocket();
    const bridge = new FakeSocket();
    const fetchMock = vi.fn(async () => new Response(JSON.stringify({ accepted: true, requestId: "request-1" }), {
      status: 202, headers: { "content-type": "application/json" },
    }));
    let sockets = 0;
    const connector = new DSHAnywhereConnector(config, {
      fetch: fetchMock as unknown as typeof fetch,
      webSocketFactory: () => (++sockets === 1 ? relay : bridge) as unknown as import("../src/connector.js").WebSocketLike,
      logger: { info: () => undefined, warn: () => undefined }, heartbeatMs: 60_000,
    });
    connector.start(); relay.emit("open"); bridge.emit("open");
    const duplicate = JSON.stringify({
      type: "relay.payload", machineId: "machine-1", messageId: "prompt-copy", sender: "device",
      body: command("prompt.send"),
    });
    relay.emit("message", duplicate);
    await vi.waitFor(() => expect(relay.sent.map((raw) => JSON.parse(raw))
      .filter((message) => message.body?.type === "prompt.accepted")).toHaveLength(1));
    const first = relay.sent.map((raw) => JSON.parse(raw)).find((message) => message.body?.type === "prompt.accepted")!;
    expect(first).toMatchObject({ targetDeviceId: "phone-1", body: {
      type: "prompt.accepted", messageId: "request-1", deviceId: "phone-1",
      sessionId: "session-1", payload: { sessionId: "session-1", requestId: "request-1" },
    }});

    // A duplicate delivery is answered from the Connector's request-result
    // cache, with a fresh transport sequence but the same request identity.
    relay.emit("message", duplicate);
    await vi.waitFor(() => expect(relay.sent.map((raw) => JSON.parse(raw))
      .filter((message) => message.body?.type === "prompt.accepted")).toHaveLength(2));
    const receipts = relay.sent.map((raw) => JSON.parse(raw)).filter((message) => message.body?.type === "prompt.accepted");
    expect(receipts[1].body.messageId).toBe(receipts[0].body.messageId);
    expect(receipts[1].body.sequence).toBeGreaterThan(receipts[0].body.sequence);
    expect(fetchMock).toHaveBeenCalledOnce();
    await connector.stop();
  });

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

  it("does not let an older presence refresh overwrite a newer archive query", async () => {
    const relay = new FakeSocket();
    const bridge = new FakeSocket();
    const pending: Array<(response: Response) => void> = [];
    let calls = 0;
    const fetchMock = vi.fn((input: RequestInfo | URL) => {
      const url = String(input);
      if (new URL(url).pathname.endsWith("/sessions")) {
        return new Promise<Response>((resolve) => pending.push(resolve));
      }
      return Promise.resolve(new Response(JSON.stringify({ accepted: true }), { headers: { "content-type": "application/json" } }));
    });
    const connector = new DSHAnywhereConnector(config, {
      fetch: fetchMock as unknown as typeof fetch,
      webSocketFactory: () => (++calls === 1 ? relay : bridge) as unknown as import("../src/connector.js").WebSocketLike,
      logger: { info: () => undefined, warn: () => undefined }, heartbeatMs: 60_000,
    });
    connector.start(); relay.emit("open"); bridge.emit("open");
    relay.emit("message", JSON.stringify({
      type: "relay.presence", machineId: "machine-1", role: "device", deviceId: "phone-1", online: true, serverTime: 1,
    }));
    await vi.waitFor(() => expect(pending).toHaveLength(1));
    const archive = { ...command("session.list"), requestId: "archive-list", payload: { includeArchived: true } };
    relay.emit("message", JSON.stringify({ type: "relay.payload", machineId: "machine-1", messageId: "archive", sender: "device", body: archive }));
    await vi.waitFor(() => expect(pending).toHaveLength(2));
    pending[1]!(new Response(JSON.stringify({ items: [{ id: "archived", title: "Archived", updatedAt: 2 }] }),
      { headers: { "content-type": "application/json" } }));
    await vi.waitFor(() => expect(relay.sent.some((raw) => {
      const message = JSON.parse(raw);
      return message.body?.type === "session.snapshot" && message.body?.messageId === "archive-list";
    })).toBe(true));
    pending[0]!(new Response(JSON.stringify({ items: [{ id: "active", title: "Active", updatedAt: 1 }] }),
      { headers: { "content-type": "application/json" } }));
    await new Promise((resolve) => setTimeout(resolve, 20));
    const snapshots = relay.sent.map((raw) => JSON.parse(raw)).filter((message) => message.body?.type === "session.snapshot");
    expect(snapshots).toHaveLength(1);
    expect(snapshots[0].body.payload[0].id).toBe("archived");
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
    await vi.waitFor(() => expect(urls).toContain("http://127.0.0.1:3080/dsh-anywhere/v1/sessions?includeArchived=true&deviceId=phone-1"));
    relay.emit("message", JSON.stringify({ type: "relay.payload", machineId: "machine-1", messageId: "archive-relay", sender: "device", body: {
      version: PROTOCOL_VERSION, requestId: "archive", machineId: "machine-1", deviceId: "phone-1", timestamp: 1,
      sessionId: "session-1", type: "session.archive", payload: { archived: true },
    } }));
    await vi.waitFor(() => expect(urls.filter((url) => url.includes("/sessions?includeArchived=true&deviceId=phone-1")).length).toBeGreaterThanOrEqual(2));
    await connector.stop();
  });

  it("defers an automatic mutation refresh until an explicit list response settles", async () => {
    const relay = new FakeSocket();
    const bridge = new FakeSocket();
    const pendingLists: Array<(response: Response) => void> = [];
    const fetchMock = vi.fn((input: RequestInfo | URL, init?: RequestInit) => {
      const url = String(input);
      if (new URL(url).pathname.endsWith("/sessions")) {
        return new Promise<Response>((resolve) => pendingLists.push(resolve));
      }
      return Promise.resolve(new Response(JSON.stringify({ accepted: true }), {
        status: 202, headers: { "content-type": "application/json" },
      }));
    });
    let calls = 0;
    const connector = new DSHAnywhereConnector(config, {
      fetch: fetchMock as unknown as typeof fetch,
      webSocketFactory: () => (++calls === 1 ? relay : bridge) as unknown as import("../src/connector.js").WebSocketLike,
      logger: { info: () => undefined, warn: () => undefined }, heartbeatMs: 60_000,
    });
    connector.start(); relay.emit("open"); bridge.emit("open");
    const explicit = { ...command("session.list"), requestId: "explicit-list" };
    relay.emit("message", JSON.stringify({ type: "relay.payload", machineId: "machine-1", messageId: "list", sender: "device", body: explicit }));
    await vi.waitFor(() => expect(pendingLists).toHaveLength(1));
    relay.emit("message", JSON.stringify({ type: "relay.payload", machineId: "machine-1", messageId: "archive", sender: "device", body: {
      version: PROTOCOL_VERSION, requestId: "archive", machineId: "machine-1", deviceId: "phone-1", timestamp: 1,
      sessionId: "session-1", type: "session.archive", payload: { archived: true },
    } }));
    // The mutation completes while the explicit list is still in flight. It
    // must mark a deferred refresh instead of superseding the request.
    await vi.waitFor(() => expect(fetchMock).toHaveBeenCalledTimes(2));
    pendingLists[0]!(new Response(JSON.stringify({ items: [{ id: "before", title: "Before", updatedAt: 1 }] }), {
      headers: { "content-type": "application/json" },
    }));
    await vi.waitFor(() => expect(relay.sent.map((raw) => JSON.parse(raw))
      .some((message) => message.body?.type === "session.snapshot" && message.body?.messageId === "explicit-list")).toBe(true));
    await vi.waitFor(() => expect(pendingLists).toHaveLength(2));
    pendingLists[1]!(new Response(JSON.stringify({ items: [{ id: "after", title: "After", updatedAt: 2 }] }), {
      headers: { "content-type": "application/json" },
    }));
    await vi.waitFor(() => expect(relay.sent.map((raw) => JSON.parse(raw))
      .some((message) => message.body?.type === "session.snapshot"
        && message.body?.messageId?.startsWith("snapshot-push-")
        && message.body?.payload?.[0]?.id === "after")).toBe(true));
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
    let bridgeConnectionId = "";
    const connector = new DSHAnywhereConnector(config, {
      webSocketFactory: (url) => {
        if (++calls === 1) return relay as unknown as import("../src/connector.js").WebSocketLike;
        bridgeConnectionId = new URL(url).searchParams.get("connectorId") ?? "";
        return bridge as unknown as import("../src/connector.js").WebSocketLike;
      },
      logger: { info: () => undefined, warn: () => undefined },
      heartbeatMs: 60_000,
    });
    connector.start();
    relay.emit("open");
    bridge.emit("open");
    bridge.emit("message", JSON.stringify({
      version: PROTOCOL_VERSION, messageId: "event-1", machineId: "local-hostname-machine", deviceId: "broadcast", sequence: 1, timestamp: 1,
      type: "connection.ready", payload: { machineId: "local-hostname-machine", deviceId: "bridge-device", serverTime: 1,
        capabilities: [], bridgeConnectionId },
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
    let bridgeConnectionId = "";
    const connector = new DSHAnywhereConnector(config, {
      fetch: fetchMock as unknown as typeof fetch,
      webSocketFactory: (url) => {
        if (++calls === 1) return relay as unknown as import("../src/connector.js").WebSocketLike;
        bridgeConnectionId = new URL(url).searchParams.get("connectorId") ?? "";
        return bridge as unknown as import("../src/connector.js").WebSocketLike;
      },
      logger: { info: () => undefined, warn: () => undefined },
      heartbeatMs: 60_000,
    });
    connector.start();
    relay.emit("open");
    bridge.emit("open");
    bridge.emit("message", JSON.stringify({
      version: PROTOCOL_VERSION, messageId: "event-1", machineId: "local-hostname-machine", deviceId: "broadcast", sequence: 1, timestamp: 1,
      type: "connection.ready", payload: { machineId: "local-hostname-machine", deviceId: "bridge-device", serverTime: 1,
        capabilities: [], bridgeConnectionId },
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

  it("treats a truncated create response as unknown and keeps the request retryable", async () => {
    const relay = new FakeSocket();
    const bridge = new FakeSocket();
    const fetchMock = vi.fn(async () => new Response("{\"sessionId\":", {
      status: 201,
      headers: { "content-type": "application/json" },
    }));
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
      type: "relay.payload", machineId: "machine-1", messageId: "relay-message-truncated",
      sender: "device", body: command("session.create"),
    }));

    const bodies = () => relay.sent.map((raw) => JSON.parse(raw)).map((message) => message.body);
    await vi.waitFor(() => expect(bodies().some((body) => body?.type === "protocol.error")).toBe(true));
    expect(bodies().find((body) => body?.type === "protocol.error")).toMatchObject({
      messageId: "request-1",
      payload: { code: "bridge-result-unknown", retryable: true },
    });
    await connector.stop();
  });

  it("routes transient streaming only to an opted-in opener and keeps replay safe for legacy devices", async () => {
    const relay = new FakeSocket();
    const bridge = new FakeSocket();
    const fetchMock = vi.fn(async () => new Response(JSON.stringify({ accepted: true }), {
      status: 202, headers: { "content-type": "application/json" },
    }));
    let calls = 0;
    let bridgeConnectionId = "";
    const connector = new DSHAnywhereConnector(config, {
      fetch: fetchMock as unknown as typeof fetch,
      webSocketFactory: (url) => {
        if (++calls === 1) return relay as unknown as import("../src/connector.js").WebSocketLike;
        bridgeConnectionId = new URL(url).searchParams.get("connectorId") ?? "";
        return bridge as unknown as import("../src/connector.js").WebSocketLike;
      },
      logger: { info: () => undefined, warn: () => undefined }, heartbeatMs: 60_000,
    });
    connector.start(); relay.emit("open"); bridge.emit("open");
    bridge.emit("message", JSON.stringify({
      version: PROTOCOL_VERSION, messageId: "ready", machineId: "mac", deviceId: "broadcast", sequence: 1, timestamp: 1,
      type: "connection.ready", payload: { machineId: "mac", deviceId: "bridge-device", serverTime: 1,
        capabilities: [], bridgeConnectionId },
    }));
    relay.sent.length = 0;

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
      version: PROTOCOL_VERSION, messageId: "reasoning", machineId: "mac", deviceId: "broadcast", sequence: 2, timestamp: 2,
      sessionId: "session-1", type: "assistant.reasoning", payload: { messageId: "stream-1", text: "thinking" },
    }));
    bridge.emit("message", JSON.stringify({
      version: PROTOCOL_VERSION, messageId: "final", machineId: "mac", deviceId: "broadcast", sequence: 3, timestamp: 3,
      sessionId: "session-1", type: "assistant.message.completed",
      payload: { id: "assistant-1", role: "assistant", markdown: "hello", replacesMessageId: "stream-1" },
    }));
    await vi.waitFor(() => expect(relay.sent).toHaveLength(4));
    const delivered = relay.sent.map((raw) => JSON.parse(raw));
    expect(delivered[0]).toMatchObject({ targetDeviceId: "phone-stream", body: {
      type: "assistant.message.delta", deviceId: "phone-stream", payload: { messageId: "stream-1" },
    } });
    expect(delivered[1]).toMatchObject({ targetDeviceId: "phone-stream", body: {
      type: "assistant.reasoning", deviceId: "phone-stream", payload: { messageId: "stream-1", text: "thinking" },
    } });
    expect(delivered[2]).toMatchObject({ targetDeviceId: "phone-stream", body: {
      type: "assistant.message.completed", deviceId: "phone-stream", payload: { replacesMessageId: "stream-1" },
    } });
    expect(delivered[3]).toMatchObject({ body: {
      type: "assistant.message.completed", deviceId: "broadcast", payload: { id: "assistant-1", markdown: "hello" },
    } });
    expect(delivered[3].targetDeviceId).toBeUndefined();
    expect(delivered[3].body.payload.replacesMessageId).toBeUndefined();

    relay.emit("message", JSON.stringify({
      type: "relay.payload", machineId: "machine-1", messageId: "legacy-resume", sender: "device",
      body: {
        version: PROTOCOL_VERSION, requestId: "legacy-resume", machineId: "machine-1", deviceId: "phone-legacy",
        timestamp: 3, type: "connection.resume", payload: { lastSequence: 0 },
      },
    }));
    await vi.waitFor(() => expect(relay.sent.length).toBeGreaterThanOrEqual(6));
    const legacy = relay.sent.slice(4).map((raw) => JSON.parse(raw));
    expect(legacy.some((message) => message.body?.type === "assistant.message.delta"
      || message.body?.type === "assistant.reasoning"
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
