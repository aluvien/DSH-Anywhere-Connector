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
  | "directory.list" | "mode.catalog" | "session.rename" | "command.execute") {
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
  if (type === "command.execute") return { ...base, type, sessionId: "session-1", payload: { line: "/slow" } } as const;
  return { ...base, type, payload: { approvalId: "approval-1", allow: true } } as const;
}

describe("bridge command mapping", () => {
  it("keeps configuration path operations and credential references behind the native controller", () => {
    const base = { version: 1 as const, requestId: "r", machineId: "m", deviceId: "d", timestamp: 1 };
    const read = bridgeRequestFor({ ...base, type: "configuration.read", payload: { section: "credentials", refs: ["A_KEY", "B_KEY"] } });
    const url = new URL(read.path, "http://bridge");
    expect(url.pathname).toBe("/configuration"); expect(JSON.parse(url.searchParams.get("refs")!)).toEqual(["A_KEY", "B_KEY"]);
    const payload = { kind: "settings" as const, ns: "llm-test", expectedRevision: 4, ops: [{ op: "set" as const, path: ["providers", "a/b", "models"], value: [{ id: "m", unknown: true }] }] };
    expect(bridgeRequestFor({ ...base, type: "configuration.discover", payload: { settingsNs: "llm-test", request: { apiKey: "temporary-test-key" } } })).toEqual({ method: "POST", path: "/configuration/discover", body: { settingsNs: "llm-test", request: { apiKey: "temporary-test-key" } } });
    expect(bridgeRequestFor({ ...base, type: "configuration.update", payload })).toEqual({ method: "POST", path: "/configuration", headers: { "x-dsh-origin-device-id": "d" }, body: payload });
  });
  it("routes native search and history without rewriting opaque cursors or child identities", () => {
    const base = { version: 1 as const, requestId: "r", machineId: "m", deviceId: "d", timestamp: 1 };
    const global = bridgeRequestFor({ ...base, type: "session.search", payload: { query: "你好 & /", cursor: "a+b/=x" } });
    const url = new URL(global.path, "http://bridge");
    expect(url.pathname).toBe("/search"); expect(url.searchParams.get("query")).toBe("你好 & /"); expect(url.searchParams.get("cursor")).toBe("a+b/=x");
    const scoped = bridgeRequestFor({ ...base, sessionId: "child/a", type: "history.read", payload: { atSeq: 0, parentSessionId: "p/b", subagentMode: "one-shot" } });
    const location = new URL(scoped.path, "http://bridge");
    expect(location.pathname).toBe("/sessions/child%2Fa/history"); expect(location.searchParams.get("atSeq")).toBe("0"); expect(location.searchParams.get("parentSessionId")).toBe("p/b");
    const schedule = bridgeRequestFor({ ...base, sessionId: "child/a", type: "schedule.get", payload: { parentSessionId: "p/b", subagentMode: "one-shot" } });
    expect(new URL(schedule.path, "http://bridge").pathname).toBe("/sessions/child%2Fa/schedules");
  });
  it("encodes native reference queries without changing spaces or source-session IDs", () => {
    const command: CommandEnvelope = { version: PROTOCOL_VERSION, requestId: "refs", machineId: "machine-1", deviceId: "phone-1",
      timestamp: 1, sessionId: "s/a", type: "reference.list", payload: { kind: "file", query: "目录/a & b" } };
    const request = bridgeRequestFor(command), url = new URL(request.path, "http://localhost");
    expect(request.method).toBe("GET"); expect(url.pathname).toBe("/sessions/s%2Fa/references");
    expect(Object.fromEntries(url.searchParams)).toEqual(command.payload);
  });
  it("keeps message feedback CAS tokens and native target identity", () => {
    const command: CommandEnvelope = { version: PROTOCOL_VERSION, requestId: "feedback", machineId: "machine-1", deviceId: "phone-1",
      timestamp: 1, sessionId: "a/b", type: "feedback.update", payload: { action: "put", messageId: "answer", rating: "negative", note: "检查", ifVersion: "v1" } };
    expect(bridgeRequestFor(command)).toEqual({ method: "POST", path: "/sessions/a%2Fb/feedback", headers: { "x-dsh-origin-device-id": "phone-1" }, body: command.payload });
    expect(bridgeRequestFor({ ...command, type: "feedback.list", payload: {} })).toEqual({ method: "GET", path: "/sessions/a%2Fb/feedback" });
  });
  it("keeps exclusive execution cursors and child parent addresses", () => {
    const read: CommandEnvelope = { version: PROTOCOL_VERSION, requestId: "execution", machineId: "machine-1", deviceId: "phone-1",
      timestamp: 1, sessionId: "child/a", type: "execution.list", payload: { beforeSeq: 0, limit: 100, parentSessionId: "parent/b", subagentMode: "one-shot" } };
    const request = bridgeRequestFor(read), url = new URL(request.path, "http://localhost");
    expect(request.method).toBe("GET");
    expect(url.pathname).toBe("/sessions/child%2Fa/execution");
    expect(Object.fromEntries(url.searchParams)).toEqual({ beforeSeq: "0", limit: "100", parentSessionId: "parent/b", subagentMode: "one-shot" });
  });
  it("encodes file paths as query data and preserves the file version across chunks", () => {
    const read: CommandEnvelope = { version: PROTOCOL_VERSION, requestId: "file", machineId: "machine-1",
      deviceId: "phone-1", timestamp: 1, sessionId: "a/b", type: "workspace.bytes",
      payload: { path: "/项目/a & b.pdf", offset: 196608, length: 196608, version: "v?2#x" } };
    const request = bridgeRequestFor(read);
    expect(request.method).toBe("GET");
    const url = new URL(request.path, "http://localhost");
    expect(url.pathname).toBe("/sessions/a%2Fb/workspace/bytes");
    expect(Object.fromEntries(url.searchParams)).toEqual({ path: "/项目/a & b.pdf", offset: "196608", length: "196608", version: "v?2#x" });
    expect(bridgeRequestFor({ ...read, type: "workspace.files", payload: { path: "" } })).toEqual({ method: "GET", path: "/sessions/a%2Fb/workspace/files?path=" });
  });
  it("keeps the goal identity and expected revision at the native boundary", () => {
    const update: CommandEnvelope = { version: PROTOCOL_VERSION, requestId: "goal-update", machineId: "machine-1",
      deviceId: "phone-1", timestamp: 1, sessionId: "s", type: "goal.update", payload: { action: "pause", ref: { id: "g", revision: 2 } } };
    expect(bridgeRequestFor(update)).toEqual({ method: "POST", path: "/sessions/s/goal", headers: { "x-dsh-origin-device-id": "phone-1" }, body: update.payload });
    expect(bridgeRequestFor({ ...update, type: "goal.get", payload: {} })).toEqual({ method: "GET", path: "/sessions/s/goal" });
  });
  it("reads current pending decisions from the authenticated Bridge", () => {
    const list: CommandEnvelope = { version: PROTOCOL_VERSION, requestId: "decisions", machineId: "machine-1",
      deviceId: "phone-1", timestamp: 1, type: "decisions.list", payload: {} };
    expect(bridgeRequestFor(list)).toEqual({ method: "GET", path: "/decisions" });
  });
  it("keeps continuable child delivery and interrupt in their parent scope", () => {
    const base = { version: PROTOCOL_VERSION, requestId: "child-control", machineId: "machine-1", deviceId: "phone-1", timestamp: 1, sessionId: "child/a" };
    const prompt: CommandEnvelope = { ...base, type: "subagent.prompt",
      payload: { parentSessionId: "parent/b", mode: "continuable", delivery: "steer", text: "continue" } };
    expect(bridgeRequestFor(prompt)).toEqual({ method: "POST", path: "/sessions/parent%2Fb/subagents/child%2Fa/prompt",
      headers: { "x-dsh-origin-device-id": "phone-1" }, body: prompt.payload });
    const interrupt: CommandEnvelope = { ...base, type: "subagent.interrupt", payload: { parentSessionId: "parent/b", mode: "continuable" } };
    expect(bridgeRequestFor(interrupt)).toEqual({ method: "POST", path: "/sessions/parent%2Fb/subagents/child%2Fa/interrupt",
      headers: { "x-dsh-origin-device-id": "phone-1" }, body: interrupt.payload });
    expect(bridgeTimeoutFor(prompt)).toBeGreaterThan(15_000);
  });
  it("keeps parent and mode when opening a subagent history", () => {
    const open: CommandEnvelope = { version: PROTOCOL_VERSION, requestId: "child-open", machineId: "machine-1",
      deviceId: "phone-1", timestamp: 1, sessionId: "child", type: "session.open",
      payload: { sessionId: "child", parentSessionId: "parent", subagentMode: "one-shot", streaming: true } };
    expect(bridgeRequestFor(open)).toEqual({ method: "POST", path: "/sessions/child/open",
      body: { deviceId: "phone-1", parentSessionId: "parent", subagentMode: "one-shot" } });
  });
  it("updates queue items through their exact server identity", () => {
    const update: CommandEnvelope = { version: PROTOCOL_VERSION, requestId: "queue-1", machineId: "machine-1",
      deviceId: "phone-1", timestamp: 1, sessionId: "s", type: "queue.update", payload: { itemId: "item-1", action: "remove" } };
    expect(bridgeRequestFor(update)).toEqual({ method: "POST", path: "/sessions/s/queue",
      headers: { "x-dsh-origin-device-id": "phone-1" }, body: { itemId: "item-1", action: "remove" } });
  });
  it("routes question cancellation without inventing an answer", () => {
    const cancel: CommandEnvelope = { version: PROTOCOL_VERSION, requestId: "cancel-1", machineId: "machine-1",
      deviceId: "phone-1", timestamp: 1, sessionId: "s", type: "question.cancel", payload: { questionId: "q/1" } };
    expect(bridgeRequestFor(cancel)).toEqual({ method: "POST", path: "/questions/q%2F1/cancel", body: {} });
  });
  it("reads command catalogs from the selected session", () => {
    const catalog: CommandEnvelope = { version: PROTOCOL_VERSION, requestId: "catalog-1", machineId: "machine-1",
      deviceId: "phone-1", timestamp: 1, sessionId: "a/b", type: "command.catalog", payload: {} };
    expect(bridgeRequestFor(catalog)).toEqual({ method: "GET", path: "/sessions/a%2Fb/commands" });
  });
  it("keeps native fork boundaries and origin device identities", () => {
    const fork: CommandEnvelope = { version: PROTOCOL_VERSION, requestId: "fork-1", machineId: "machine-1",
      deviceId: "phone-1", timestamp: 1, sessionId: "parent", type: "session.fork", payload: { atSeq: 42 } };
    expect(bridgeRequestFor(fork)).toEqual({ method: "POST", path: "/sessions/parent/fork",
      headers: { "x-dsh-origin-device-id": "phone-1" }, body: { atSeq: 42 } });
    expect(bridgeTimeoutFor(fork)).toBeGreaterThan(120_000);
  });
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
      method: "POST", path: "/workspaces",
      headers: { "x-dsh-origin-device-id": "phone-1" },
      body: { path: "/tmp/workspace", title: "Workspace" },
    });
    expect(bridgeRequestFor(command("directory.list"))).toEqual({ method: "GET", path: "/directories?path=%2Ftmp" });
    expect(bridgeRequestFor(command("mode.catalog"))).toEqual({ method: "GET", path: "/modes" });
    expect(bridgeRequestFor(command("session.rename"))).toEqual({
      method: "POST", path: "/sessions/session-1/rename", body: { title: "Renamed session" },
    });
    expect(bridgeRequestFor(command("command.execute"))).toEqual({
      method: "POST", path: "/sessions/session-1/command",
      headers: { "x-dsh-origin-device-id": "phone-1" },
      body: { line: "/slow" },
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
    openRelay(relay);
    bridge.emit("open");
    relay.emit("close", 4001);
    await vi.waitFor(() => expect(connector.status).toBe("stopped"));
    await new Promise((resolve) => setTimeout(resolve, 10));
    expect(sockets).toBe(2);
  });
});

describe("Relay and bridge forwarding", () => {
  it('quarantines full parity messages and phone operations until a matching Relay is verified, then resumes without stripping fields', async () => {
    const relay = new FakeSocket(), bridge = new FakeSocket(), upgraded = new FakeSocket(), requests = vi.fn(async () => Response.json({ accepted: true }))
    const urls: string[] = []; let bridgeID = ''
    const connector = new DSHAnywhereConnector(config, { fetch: requests as typeof fetch,
      webSocketFactory: (url, headers) => {
        urls.push(url)
        if (urls.length === 1) { expect(new URL(url).searchParams.get('schemaRevision')).toBe('12'); return relay as unknown as import("../src/connector.js").WebSocketLike }
        if (urls.length === 2) { bridgeID = new URL(url).searchParams.get('connectorId')!; expect(headers['x-dsh-schema-revision']).toBe('12'); return bridge as unknown as import("../src/connector.js").WebSocketLike }
        return upgraded as unknown as import("../src/connector.js").WebSocketLike
      }, logger: { info() {}, warn() {} }, reconnectBaseMs: 1, heartbeatMs: 60000 })
    try {
      connector.start(); relay.emit('open'); bridge.emit('open')
      bridge.emit('message', JSON.stringify({ version: 1, messageId: 'greeting', machineId: 'local', deviceId: 'broadcast', sequence: 1, timestamp: 1,
        type: 'connection.ready', payload: { machineId: 'local', deviceId: 'connector', serverTime: 1, capabilities: [], bridgeConnectionId: bridgeID } }))
      bridge.emit('message', JSON.stringify({ version: 1, messageId: 'answer', machineId: 'local', deviceId: 'broadcast', sessionId: 'session-1', sequence: 2, timestamp: 2,
        type: 'assistant.message.completed', payload: { id: 'answer', role: 'assistant', markdown: '完整回答', nativeSequence: 42 } }))
      bridge.emit('message', JSON.stringify({ version: 1, messageId: 'plan-review', machineId: 'local', deviceId: 'broadcast', sessionId: 'session-1', sequence: 3, timestamp: 3,
        type: 'question.asked', payload: { id: 'review', sessionId: 'session-1', stateVersion: { epoch: 'host', revision: 4 }, questions: [{ id: 'q', question: '执行此计划？', detail: '# 完整计划\n保留详细步骤', intent: { kind: 'plan-review', approve: 'yes' }, options: [{ label: 'yes', description: '实施计划' }] }] } }))
      relay.emit('message', JSON.stringify({ type: 'relay.payload', machineId: 'machine-1', messageId: 'unsafe-early-command', sender: 'device', body: command('prompt.send') }))
      await new Promise(done => setTimeout(done, 10))
      expect(requests).not.toHaveBeenCalled(); expect(relay.sent).toHaveLength(0); expect(connector.status).not.toBe('connected')
      relay.emit('message', JSON.stringify({ type: 'relay.ready', machineId: 'machine-1', role: 'machine', connectionId: 'old', serverTime: 1, schemaRevision: 10 }))
      expect(relay.readyState).toBe(3)
      expect(relay.sent.map(raw => JSON.parse(raw).body)).toEqual([expect.objectContaining({ type: 'protocol.error', payload: expect.objectContaining({ code: 'relay-upgrade-required' }) })])
      relay.emit('close', 4406)
      await vi.waitFor(() => expect(urls).toHaveLength(3))
      upgraded.emit('open')
      expect(upgraded.sent).toHaveLength(0)
      upgraded.emit('message', JSON.stringify({ type: 'relay.ready', machineId: 'machine-1', role: 'machine', connectionId: 'new', serverTime: 2, schemaRevision: 12, leaseGeneration: 2, relayEpoch: 'new' }))
      expect(connector.status).toBe('connected')
      expect(upgraded.sent.map(raw => JSON.parse(raw).body)).toContainEqual(expect.objectContaining({ type: 'assistant.message.completed', payload: expect.objectContaining({ markdown: '完整回答', nativeSequence: 42 }) }))
      expect(upgraded.sent.map(raw => JSON.parse(raw).body)).toContainEqual(expect.objectContaining({ type: 'question.asked', payload: expect.objectContaining({ stateVersion: { epoch: 'host', revision: 4 }, questions: [expect.objectContaining({ detail: '# 完整计划\n保留详细步骤', intent: { kind: 'plan-review', approve: 'yes' } })] }) }))
    } finally { await connector.stop() }
  })
  it.each([undefined, 10, 11])('rejects a Relay greeting with unsupported revision %s before forwarding', async revision => {
    const relay = new FakeSocket(), bridge = new FakeSocket(); let sockets = 0
    const connector = new DSHAnywhereConnector(config, { webSocketFactory: () => (++sockets === 1 ? relay : bridge) as unknown as import("../src/connector.js").WebSocketLike, logger: { info() {}, warn() {} } })
    try {
      connector.start(); relay.emit('open')
      relay.emit('message', JSON.stringify({ type: 'relay.ready', machineId: 'machine-1', role: 'machine', connectionId: 'old', serverTime: 1, ...(revision === undefined ? {} : { schemaRevision: revision }) }))
      expect(relay.readyState).toBe(3); expect(connector.status).not.toBe('connected')
      expect(JSON.parse(relay.sent[0]!).body.payload.code).toBe('relay-upgrade-required')
    } finally { await connector.stop() }
  })
  it('closes a socket which never proves its Relay schema', async () => {
    vi.useFakeTimers()
    const relay = new FakeSocket(); let sockets = 0
    const connector = new DSHAnywhereConnector(config, { webSocketFactory: () => (++sockets === 1 ? relay : new FakeSocket()) as unknown as import("../src/connector.js").WebSocketLike, logger: { info() {}, warn() {} } })
    try { connector.start(); relay.emit('open'); await vi.advanceTimersByTimeAsync(10001); expect(relay.readyState).toBe(3); expect(connector.status).not.toBe('connected') }
    finally { await connector.stop(); vi.useRealTimers() }
  })

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
    connector.start(); openRelay(relay); bridge.emit("open");
    relay.emit("message", JSON.stringify({
      type: "relay.ready", schemaRevision: 12, machineId: "machine-1", role: "machine", connectionId: "connection-1",
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
    connector.start(); openRelay(relay); bridge.emit("open");
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
    connector.start(); openRelay(relay); bridge.emit("open");
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

  it("targets file bytes to their requester and rereads without retaining them for chat replay", async () => {
    const relay = new FakeSocket(), bridge = new FakeSocket();
    const fetchMock = vi.fn(async (input: RequestInfo | URL) => String(input).includes("/workspace/bytes")
      ? Response.json({ sessionId: "s", absolutePath: "/a.txt", version: "v1", bytes: 1, offset: 0, data: "YQ==", eof: true })
      : Response.json({ items: [] }));
    let sockets = 0;
    const connector = new DSHAnywhereConnector(config, {
      fetch: fetchMock as typeof fetch,
      webSocketFactory: () => (++sockets === 1 ? relay : bridge) as unknown as import("../src/connector.js").WebSocketLike,
      logger: { info: () => undefined, warn: () => undefined }, heartbeatMs: 60_000,
    });
    connector.start(); openRelay(relay); bridge.emit("open");
    const read = { version: PROTOCOL_VERSION, requestId: "file", machineId: "machine-1", deviceId: "phone-1", timestamp: 1,
      sessionId: "s", type: "workspace.bytes", payload: { path: "a.txt", offset: 0, length: 3 } };
    const deliver = (body: unknown) => relay.emit("message", JSON.stringify({ type: "relay.payload", machineId: "machine-1", messageId: "copy", sender: "device", body }));
    const bytes = () => relay.sent.map((raw) => JSON.parse(raw)).filter((message) => message.body?.type === "workspace.bytes");
    try {
      deliver(read);
      await vi.waitFor(() => expect(bytes()).toHaveLength(1));
      expect(bytes()[0]).toMatchObject({ targetDeviceId: "phone-1", body: { deviceId: "phone-1", messageId: "file", payload: { data: "YQ==" } } });
      deliver(read);
      await vi.waitFor(() => expect(bytes()).toHaveLength(2));
      expect(fetchMock.mock.calls.filter(([url]) => String(url).includes("/workspace/bytes"))).toHaveLength(2);
      deliver({ version: PROTOCOL_VERSION, requestId: "resume", machineId: "machine-1", deviceId: "phone-1", timestamp: 2,
        type: "connection.resume", payload: { lastSequence: 0 } });
      await vi.waitFor(() => expect(relay.sent.map((raw) => JSON.parse(raw)).some((message) => message.body?.type === "session.snapshot")).toBe(true));
      expect(bytes()).toHaveLength(2);
    } finally { await connector.stop(); }
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
    connector.start(); openRelay(relay); bridge.emit("open");
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
    connector.start(); openRelay(relay); bridge.emit("open");
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
    connector.start(); openRelay(relay); bridge.emit("open");
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
    connector.start(); openRelay(relay); bridge.emit("open");
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
    connector.start(); openRelay(relay); bridge.emit("open");
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
    connector.start(); openRelay(relay); bridge.emit("open");
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
    connector.start(); openRelay(relay); bridge.emit("open");
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
    openRelay(relay);
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
    openRelay(relay);
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

    relay.emit("message", JSON.stringify({ type: "relay.ready", schemaRevision: 12, machineId: "machine-1", role: "machine", connectionId: "connection-1", serverTime: 1 }));
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
    openRelay(relay);
    bridge.emit("open");
    relay.emit("message", JSON.stringify({ type: "relay.ready", schemaRevision: 12, machineId: "machine-1", role: "machine", connectionId: "connection-1", serverTime: 1 }));

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
    openRelay(relay);
    bridge.emit("open");
    relay.emit("message", JSON.stringify({ type: "relay.ready", schemaRevision: 12, machineId: "machine-1", role: "machine", connectionId: "connection-1", serverTime: 1 }));
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
    connector.start(); openRelay(relay); bridge.emit("open");
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

describe("desktop endpoint and failure handling", () => {
  it("re-resolves both HTTP and WebSocket after the desktop port changes", async () => {
    const relay = new FakeSocket();
    const bridges: FakeSocket[] = [];
    const urls: string[] = [];
    const requests: string[] = [];
    let port = 59656;
    const connector = new DSHAnywhereConnector(config, {
      resolveBridgeBaseURL: async () => `http://127.0.0.1:${port}/dsh-anywhere/v1`,
      webSocketFactory: url => {
        urls.push(url);
        if (urls.length === 1) return relay as unknown as import("../src/connector.js").WebSocketLike;
        const bridge = new FakeSocket(); bridges.push(bridge); return bridge as unknown as import("../src/connector.js").WebSocketLike;
      },
      fetch: (async url => { requests.push(String(url)); return Response.json({ modes: [] }); }) as typeof fetch,
      reconnectBaseMs: 1, heartbeatMs: 60_000, logger: { info() {}, warn() {} },
    });
    try {
      connector.start(); openRelay(relay);
      await vi.waitFor(() => expect(bridges.length).toBe(1));
      expect(urls[1]).toContain(':59656/');
      port = 59657;
      bridges[0]!.emit("close");
      await vi.waitFor(() => expect(bridges.length).toBe(2));
      expect(urls[2]).toContain(':59657/');
      relay.emit("message", JSON.stringify({ type: "relay.payload", machineId: "machine-1",
        messageId: "modes", sender: "device", body: command("mode.catalog") }));
      await vi.waitFor(() => expect(requests.some(url => url.includes(':59657/dsh-anywhere/v1/modes'))).toBe(true));
    } finally { await connector.stop(); }
  });

  it("does not open a late resolved socket after stop", async () => {
    let resolve!: (url: string) => void;
    const urls: string[] = [];
    const connector = new DSHAnywhereConnector(config, {
      resolveBridgeBaseURL: () => new Promise<string>(done => { resolve = done; }),
      webSocketFactory: url => { urls.push(url); return new FakeSocket() as unknown as import("../src/connector.js").WebSocketLike; },
      logger: { info() {}, warn() {} },
    });
    connector.start();
    await vi.waitFor(() => expect(resolve).toBeDefined());
    await connector.stop();
    resolve('http://127.0.0.1:59656/dsh-anywhere/v1');
    await new Promise(done => setTimeout(done, 10));
    expect(urls).toHaveLength(1);
  });

  it.each(['http', 'timeout'])("reports a catalog %s failure without unknown mutation wording", async failure => {
    const relay = new FakeSocket();
    let sockets = 0;
    const connector = new DSHAnywhereConnector(config, {
      webSocketFactory: () => (++sockets === 1 ? relay : new FakeSocket()) as unknown as import("../src/connector.js").WebSocketLike,
      fetch: (async () => {
        if (failure === 'timeout') throw new DOMException('deadline', 'TimeoutError');
        return new Response('{}', { status: 500, headers: { 'x-dsh-idempotency-outcome': 'unknown' } });
      }) as typeof fetch,
      logger: { info() {}, warn() {} }, heartbeatMs: 60_000,
    });
    try {
      connector.start(); openRelay(relay);
      relay.emit('message', JSON.stringify({ type: 'relay.payload', machineId: 'machine-1',
        messageId: 'modes', sender: 'device', body: command('mode.catalog') }));
      const error = () => relay.sent.map(raw => JSON.parse(raw).body).find(body => body?.type === 'protocol.error');
      await vi.waitFor(() => expect(error()).toBeDefined());
      expect(error().payload).toMatchObject({ code: 'bridge-request-failed', retryable: true });
      expect(error().payload.message).toContain('mode.catalog');
      expect(error().payload.message).not.toContain('result is unknown');
      expect(error().payload.message).toContain(failure === 'timeout' ? 'timed out' : 'HTTP 500');
    } finally { await connector.stop(); }
  });
});

function openRelay(socket: FakeSocket): void {
  socket.emit("open");
  socket.emit("message", JSON.stringify({ type: "relay.ready", schemaRevision: 12, machineId: "machine-1", role: "machine", connectionId: "schema-test", serverTime: 1 }));
}

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
