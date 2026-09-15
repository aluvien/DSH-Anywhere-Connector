#!/usr/bin/env node
/**
 * Mock DSH Anywhere "machine" for client-side end-to-end testing.
 *
 * Connects to a local relay with a machine token (see .relay-local/reg.json
 * after `curl /v1/machines/register`) and answers the device commands the
 * Android client sends, using the exact wire envelopes from the real
 * protocol. Not part of the app build; a test fixture.
 *
 * Usage: node android/tools/mock-machine.mjs \
 *          --relay ws://127.0.0.1:8787/v1/connect \
 *          --machine-id <id> --token <machineToken>
 */
import { randomUUID } from "node:crypto";
// Node >= 22 ships a global (undici) WebSocket client; no dependencies.
const { WebSocket } = globalThis;

const args = {};
for (let i = 2; i < process.argv.length; i += 2) {
  args[process.argv[i].replace(/^--/, "")] = process.argv[i + 1];
}
const relay = args.relay ?? "ws://127.0.0.1:8787/v1/connect";
const machineId = args["machine-id"];
const token = args.token;
if (!machineId || !token) {
  console.error("need --machine-id and --token");
  process.exit(2);
}

let sequence = 0;
const now = () => Date.now();
const ws = new WebSocket(relay, { headers: { Authorization: `Bearer ${token}`, "User-Agent": "dsh-anywhere/mock-machine" } });

function sendEvent(type, sessionId, payload, messageId = randomUUID()) {
  const envelope = {
    version: 1,
    messageId,
    deviceId: machineId,
    machineId,
    ...(sessionId ? { sessionId } : {}),
    sequence: ++sequence,
    timestamp: now(),
    type,
    payload,
  };
  ws.send(JSON.stringify({
    type: "relay.payload",
    machineId,
    messageId: randomUUID(),
    sender: "machine",
    body: envelope,
  }));
}

const sessions = [
  { id: "s-mock-1", title: "Mock session", updatedAt: now() - 60_000, cwd: "/tmp/mock", workspaceId: "ws-mock", workspaceName: "MOCK-WORKSPACE", running: false, provider: "deepseek", model: "deepseek-v4.1-flash", branch: "main", mode: "standard", permissionMode: "workspace-write" },
];

ws.onopen = () => console.log("[mock] connected, waiting for relay.ready");

ws.onmessage = (event) => {
  const msg = JSON.parse(typeof event.data === "string" ? event.data : event.data.toString());
  if (msg.type === "relay.ready") {
    console.log(`[mock] ready as ${msg.role}`);
    return;
  }
  if (msg.type !== "relay.payload") return;
  const command = msg.body;
  console.log(`[mock] command ${command.type} session=${command.sessionId ?? "-"}`);
  switch (command.type) {
    case "connection.resume":
      sendEvent("connection.ready", null, {});
      sendEvent("session.snapshot", null, sessions);
      break;
    case "session.list":
      sendEvent("session.snapshot", null, sessions);
      break;
    case "session.create": {
      const created = {
        ...sessions[0],
        id: `s-${randomUUID().slice(0, 8)}`,
        title: command.payload?.title ?? "新会话",
        updatedAt: now(),
      };
      sessions.unshift(created);
      sendEvent("session.created", created.id, created, command.requestId);
      break;
    }
    case "prompt.send": {
      const sid = command.sessionId;
      const text = command.payload?.text ?? "";
      const userId = randomUUID();
      sendEvent("user.message.accepted", sid, { id: userId, role: "user", markdown: text });
      sendEvent("turn.state.changed", sid, { sessionId: sid, state: "running" });
      const toolId = randomUUID();
      setTimeout(() => sendEvent("tool.started", sid, { id: toolId, name: "bash", status: "running", detail: "echo hello" }), 150);
      const msgId = randomUUID();
      const chunks = ["Mock ", "reply ", "for: ", text.slice(0, 20), "."];
      chunks.forEach((chunk, i) =>
        setTimeout(() => sendEvent("assistant.message.delta", sid, { messageId: msgId, text: chunk }), 400 + i * 200),
      );
      setTimeout(() => sendEvent("assistant.reasoning", sid, { messageId: msgId, text: "I am a mock model thinking." }), 500);
      setTimeout(() => sendEvent("tool.completed", sid, { id: toolId, name: "bash", status: "completed", detail: "exit 0" }), 900);
      setTimeout(() => {
        sendEvent("assistant.message.completed", sid, { id: msgId, role: "assistant", markdown: `Mock reply for: ${text.slice(0, 20)}.` });
        sendEvent("usage.updated", sid, { sessionId: sid, usage: { totalTokens: 123, contextUsed: 12_000, contextWindow: 128_000 } });
        sendEvent("turn.state.changed", sid, { sessionId: sid, state: "idle" });
      }, 1200);
      break;
    }
    case "approval.decide":
      sendEvent("approval.resolved", command.sessionId, { id: command.payload.approvalId, allowed: command.payload.allow });
      break;
    case "question.answer":
      sendEvent("question.resolved", command.sessionId, { id: command.payload.questionId, sessionId: command.sessionId });
      break;
    case "session.model":
      sendEvent("session.model.changed", command.sessionId, { sessionId: command.sessionId, current: { provider: command.payload.provider, model: command.payload.model, reasoningEffort: command.payload.reasoningEffort ?? null } });
      break;
    case "model.catalog":
      sendEvent("model.catalog", null, {
        default: { provider: "deepseek", model: "deepseek-v4.1-flash" },
        routableProviders: ["deepseek"],
        groups: [{ id: "deepseek", name: "DeepSeek", models: [{ id: "deepseek-v4.1-flash", name: "DeepSeek V4.1 Flash", reasoning: { efforts: [{ id: "low", name: "Low" }, { id: "high", name: "High" }], defaultEffort: "low" } }] }],
        failures: [],
      });
      break;
    case "attachment.upload":
      sendEvent("attachment.uploaded", command.sessionId, { sessionId: command.sessionId, requestId: command.requestId, receiptId: `r-${randomUUID().slice(0, 6)}`, name: command.payload.name, mediaType: null, size: (command.payload.data ?? "").length });
      break;
    case "session.archive":
      sessions.forEach((s) => { if (s.id === command.sessionId) s.archived = command.payload.archived; });
      sendEvent("session.snapshot", null, sessions);
      break;
    case "turn.cancel":
      sendEvent("turn.state.changed", command.sessionId, { sessionId: command.sessionId, state: "idle" });
      break;
    default:
      sendEvent("command.result", command.sessionId, { sessionId: command.sessionId, requestId: command.requestId, matched: false, kind: "unknown" });
  }
};

// Demo triggers so approval/question cards can be exercised:
//   node mock-machine.mjs … --demo approval|question  (emits once 3s after ready)
if (args.demo === "approval") {
  setTimeout(() => sendEvent("approval.requested", "s-mock-1", { id: `ap-${Date.now()}`, sessionId: "s-mock-1", toolName: "bash", reason: "rm -rf ./build (mock demo)", expiresAt: now() + 120_000 }), 3000);
}
if (args.demo === "question") {
  setTimeout(() => sendEvent("question.asked", "s-mock-1", { id: `q-${Date.now()}`, sessionId: "s-mock-1", questions: [{ id: "q1", question: "Pick a flavour", header: "Demo", options: [{ label: "Vanilla" }, { label: "Chocolate", description: "rich" }], multiSelect: false }], expiresAt: now() + 120_000 }), 3000);
}
