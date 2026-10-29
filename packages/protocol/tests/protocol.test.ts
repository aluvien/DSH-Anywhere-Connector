import { describe, expect, it } from "vitest";
import {
  PROTOCOL_VERSION,
  supportsSchemaRevision,
  CommandEnvelopeSchema,
  EventEnvelopeSchema,
  PairingRequestSchema,
  PairingResponseSchema,
  RelayMessageSchema,
  parseCommand,
  pairingLink,
  parsePairingLink,
  relayHTTPSURL,
  validateSequence,
} from "../src/index";

const envelopeFields = {
  version: PROTOCOL_VERSION,
  messageId: "msg-1",
  machineId: "mac-1",
  deviceId: "iphone-1",
  sequence: 1,
  timestamp: 1_735_000_000_000,
};

describe("collaboration controls", () => {
  it("requires an explicit safe schema revision, keeping the main wire version pinned", () => {
    expect(PROTOCOL_VERSION).toBe(1);
    for (const revision of [undefined, null, true, "", "11garbage", "11.5", "1e2", 10, 11.5, Infinity, Number.MAX_SAFE_INTEGER + 1]) expect(supportsSchemaRevision(revision)).toBe(false);
    for (const revision of [11, "11", 12, "12"]) expect(supportsSchemaRevision(revision)).toBe(true);
  });
  it("keeps discovery overrides private to requests and invalidations limited to identifiers", () => {
    const base = { version: 1, requestId: "r", machineId: "m", deviceId: "d", timestamp: 1, type: "configuration.discover" };
    expect(CommandEnvelopeSchema.safeParse({ ...base, payload: { settingsNs: "llm-test", request: { apiKey: "temporary" } } }).success).toBe(true);
    expect(EventEnvelopeSchema.safeParse({ ...envelopeFields, type: "configuration.invalidated", payload: { section: "settings", ns: "llm-test", value: { apiKey: "secret" } } }).success).toBe(false);
    expect(EventEnvelopeSchema.safeParse({ ...envelopeFields, type: "configuration.models", payload: { settingsNs: "llm-test", models: [{ id: "m", apiKey: "secret" }] } }).success).toBe(false);
  });
  it("requires settings CAS, explicit operations and bounded one-way credential values", () => {
    const base = { version: 1, requestId: "r", machineId: "m", deviceId: "d", timestamp: 1, type: "configuration.update" };
    const settings = { kind: "settings", ns: "llm-test", expectedRevision: 0, ops: [{ op: "set", path: ["models"], value: [{ id: "m", futureField: true }] }] };
    expect(CommandEnvelopeSchema.safeParse({ ...base, payload: settings }).success).toBe(true);
    expect(CommandEnvelopeSchema.safeParse({ ...base, payload: { ...settings, expectedRevision: undefined } }).success).toBe(false);
    expect(CommandEnvelopeSchema.safeParse({ ...base, payload: { ...settings, ops: [{ op: "set", path: ["x"] }] } }).success).toBe(false);
    for (const payload of [{ kind: "credential", action: "set", ref: "TEST_KEY" }, { kind: "credential", action: "unset", ref: "TEST_KEY", value: "extra" }, { kind: "credential", action: "set", ref: "bad-ref", value: "x" }]) expect(CommandEnvelopeSchema.safeParse({ ...base, payload }).success).toBe(false);
  });
  it("validates native history/search inputs and keeps zero as a real location", () => {
    const base = { version: 1, requestId: "r", machineId: "m", deviceId: "d", timestamp: 1 };
    expect(CommandEnvelopeSchema.safeParse({ ...base, type: "session.search", payload: { query: "完整对话" } }).success).toBe(true);
    for (const query of ["  ", "x\0y", "x".repeat(501)]) expect(CommandEnvelopeSchema.safeParse({ ...base, type: "session.search", payload: { query } }).success).toBe(false);
    expect(CommandEnvelopeSchema.safeParse({ ...base, sessionId: "child", type: "history.read", payload: { atSeq: 0, throughSeq: 0, parentSessionId: "p", subagentMode: "one-shot" } }).success).toBe(true);
    expect(CommandEnvelopeSchema.safeParse({ ...base, sessionId: "child", type: "history.read", payload: { atSeq: -1 } }).success).toBe(false);
    expect(CommandEnvelopeSchema.safeParse({ ...base, sessionId: "child", type: "conversation.search", payload: { query: "x", parentSessionId: "p" } }).success).toBe(false);
  });
  it("admits image-only continuable prompts but rejects fabricated attachments and aggregate image overflow", () => {
    const command = { version: 1, requestId: "images", machineId: "mac", deviceId: "phone", sessionId: "child", timestamp: 1, type: "subagent.prompt" };
    const payload = { parentSessionId: "parent", mode: "continuable", delivery: "queue", text: "", images: [{ type: "image", mediaType: "image/jpeg", data: "YQ==", name: "photo.jpg" }] };
    expect(CommandEnvelopeSchema.safeParse({ ...command, payload }).success).toBe(true);
    expect(CommandEnvelopeSchema.safeParse({ ...command, payload: { ...payload, images: [] } }).success).toBe(false);
    expect(CommandEnvelopeSchema.safeParse({ ...command, payload: { ...payload, mode: "one-shot" } }).success).toBe(false);
    expect(CommandEnvelopeSchema.safeParse({ ...command, payload: { ...payload, images: [{ type: "image", attachment: { attachmentId: "fabricated" } }] } }).success).toBe(false);
    const image = { type: "image", mediaType: "image/jpeg", data: "A".repeat(4 * 1024 * 1024 + 1) };
    expect(CommandEnvelopeSchema.safeParse({ ...command, payload: { ...payload, images: [image, image] } }).success).toBe(false);
  });
  it("requires an explicit feedback revision and validates categories", () => {
    const command = { version: 1, requestId: "feedback", machineId: "mac", deviceId: "phone", sessionId: "s", timestamp: 1, type: "feedback.update" };
    expect(CommandEnvelopeSchema.safeParse({ ...command, payload: { action: "put", messageId: "a", rating: "positive", ifVersion: null } }).success).toBe(true);
    expect(CommandEnvelopeSchema.safeParse({ ...command, payload: { action: "put", messageId: "a", rating: "positive" } }).success).toBe(false);
    expect(CommandEnvelopeSchema.safeParse({ ...command, payload: { action: "put", messageId: "a", rating: "negative", category: "invented", ifVersion: null } }).success).toBe(false);
    expect(CommandEnvelopeSchema.safeParse({ ...command, payload: { action: "delete", messageId: "a", ifVersion: null } }).success).toBe(false);
  });
  it("keeps exact execution sequence zero and requires complete child addresses", () => {
    const command = { version: PROTOCOL_VERSION, requestId: "trace", machineId: "mac", deviceId: "phone", sessionId: "s", timestamp: 1, type: "execution.list" };
    expect(CommandEnvelopeSchema.safeParse({ ...command, payload: { beforeSeq: 0 } }).success).toBe(true);
    expect(CommandEnvelopeSchema.safeParse({ ...command, payload: { parentSessionId: "p" } }).success).toBe(false);
    expect(CommandEnvelopeSchema.safeParse({ ...command, payload: { parentSessionId: "p", subagentMode: "one-shot" } }).success).toBe(true);
    expect(EventEnvelopeSchema.parse({ ...envelopeFields, type: "execution.recorded", payload: { sessionId: "s", inTranscript: false,
      record: { type: "compaction/start", nativeSequence: 0, data: { compactionId: "c", turn: null } } } }).payload)
      .toMatchObject({ record: { nativeSequence: 0, data: { turn: null } } });
  });
  it("bounds file chunks and keeps empty workspace root distinct from a file path", () => {
    const base = { version: PROTOCOL_VERSION, requestId: "file", machineId: "mac", deviceId: "phone", timestamp: 1, sessionId: "s" };
    expect(CommandEnvelopeSchema.safeParse({ ...base, type: "workspace.files", payload: { path: "" } }).success).toBe(true);
    const read = { ...base, type: "workspace.bytes", payload: { path: "图.png", offset: 0, length: 196608 } };
    expect(CommandEnvelopeSchema.safeParse(read).success).toBe(true);
    for (const payload of [{ ...read.payload, path: "" }, { ...read.payload, path: "a\0b" }, { ...read.payload, length: 196609 }, { ...read.payload, offset: -1 }]) {
      expect(CommandEnvelopeSchema.safeParse({ ...read, payload }).success).toBe(false);
    }
    expect(EventEnvelopeSchema.safeParse({ ...envelopeFields, type: "workspace.files", payload: { sessionId: "s", path: "", truncated: false,
      entries: [{ name: "../bad", type: "file" }] } }).success).toBe(false);
  });
  it("retains workflow member phase identity and a catalog-only update", () => {
    const parsed = EventEnvelopeSchema.parse({ ...envelopeFields, type: "workflow.changed", payload: {
      sessionId: "s", inTranscript: false, run: { id: "r", name: "Review", status: "completed", nativeSequence: 2, updatedNativeSequence: 10,
        members: [{ seq: 1, label: "A", childId: "a", status: "completed" }, { seq: 2, label: "B", childId: "b", phase: "", status: "failed" }] } } });
    expect(parsed.payload).toMatchObject({ inTranscript: false, run: { members: [{ childId: "a" }, { childId: "b", phase: "" }] } });
  });
  it("requires an exact valid goal revision and a nonempty edit", () => {
    const command = { version: PROTOCOL_VERSION, requestId: "goal", machineId: "mac-1", deviceId: "phone-1",
      timestamp: 1, sessionId: "s", type: "goal.update" };
    expect(CommandEnvelopeSchema.safeParse({ ...command, payload: { action: "edit", ref: { id: "g", revision: 2 } } }).success).toBe(false);
    expect(CommandEnvelopeSchema.safeParse({ ...command, payload: { action: "pause", ref: { id: "g", revision: 0 } } }).success).toBe(false);
    expect(CommandEnvelopeSchema.safeParse({ ...command, payload: { action: "edit", ref: { id: "g", revision: 2 }, maxGoalRounds: 0 } }).success).toBe(false);
    expect(CommandEnvelopeSchema.parse({ ...command, payload: { action: "edit", ref: { id: "g", revision: 2 }, objective: "Ship", maxGoalRounds: 18 } }).type).toBe("goal.update");
  });
  it("keeps native pending state and a goal's separate activation", () => {
    const plan = EventEnvelopeSchema.parse({ ...envelopeFields, type: "plan.projection", payload: {
      sessionId: "s", active: false, pending: true, available: true, supported: true, epoch: "control-1", seq: 10 } });
    expect(plan.payload).toMatchObject({ active: false, pending: true, seq: 10 });
    const goal = EventEnvelopeSchema.parse({ ...envelopeFields, type: "goal.state", payload: {
      sessionId: "s", goal: { id: "g", revision: 2, objective: "Ship", phase: "active", maxGoalRounds: 12 },
      roundsStarted: 3, activation: "disarmed" } });
    expect(goal.payload).toMatchObject({ activation: "disarmed" });
  });
});

describe("DSH Anywhere wire protocol", () => {
  it("parses a valid streaming chat event", () => {
    const parsed = EventEnvelopeSchema.parse({
      ...envelopeFields,
      sessionId: "session-1",
      type: "assistant.message.delta",
      payload: { messageId: "assistant-1", text: "hello" },
    });

    expect(parsed.type).toBe("assistant.message.delta");
    if (parsed.type === "assistant.message.delta") {
      expect(parsed.payload.text).toBe("hello");
    }
  });

  it("parses a targeted prompt acceptance receipt", () => {
    const parsed = EventEnvelopeSchema.parse({
      ...envelopeFields,
      sessionId: "session-1",
      type: "prompt.accepted",
      payload: { sessionId: "session-1", requestId: "prompt-1" },
    });

    expect(parsed.type).toBe("prompt.accepted");
    if (parsed.type === "prompt.accepted") {
      expect(parsed.payload.requestId).toBe("prompt-1");
    }
  });

  it("accepts a prompt whose content is supplied only in attachments", () => {
    const parsed = CommandEnvelopeSchema.parse({
      version: PROTOCOL_VERSION,
      requestId: "prompt-attachments",
      machineId: "mac-1",
      deviceId: "iphone-1",
      timestamp: 1_735_000_000_000,
      type: "prompt.send",
      payload: { attachments: [{ type: "file", receiptId: "receipt-1" }] },
    });
    expect(parsed.type).toBe("prompt.send");
  });

  it("keeps transient streaming controls explicit and opt-in", () => {
    const open = CommandEnvelopeSchema.parse({
      version: PROTOCOL_VERSION,
      requestId: "open-1",
      machineId: "mac-1",
      deviceId: "iphone-1",
      sessionId: "session-1",
      timestamp: 1,
      type: "session.open",
      payload: { sessionId: "session-1", streaming: true },
    });
    expect(open.type === "session.open" && open.payload.streaming).toBe(true);

    const completed = EventEnvelopeSchema.parse({
      ...envelopeFields,
      sessionId: "session-1",
      type: "assistant.message.completed",
      payload: {
        id: "assistant-final",
        role: "assistant",
        markdown: "done",
        replacesMessageId: "assistant-live",
      },
    });
    expect(completed.type === "assistant.message.completed" && completed.payload.replacesMessageId)
      .toBe("assistant-live");

    const discarded = EventEnvelopeSchema.parse({
      ...envelopeFields,
      sessionId: "session-1",
      type: "assistant.message.discarded",
      payload: { messageId: "assistant-live" },
    });
    expect(discarded.type === "assistant.message.discarded").toBe(true);
  });

  it("parses history replay brackets carrying the same batch id", () => {
    const started = EventEnvelopeSchema.parse({
      ...envelopeFields,
      sessionId: "session-1",
      type: "history.started",
      payload: { sessionId: "session-1", batchId: "batch-1" },
    });
    const completed = EventEnvelopeSchema.parse({
      ...envelopeFields,
      sequence: 99,
      sessionId: "session-1",
      type: "history.completed",
      payload: { sessionId: "session-1", batchId: "batch-1" },
    });

    expect(started.type).toBe("history.started");
    expect(completed.type).toBe("history.completed");
    if (started.type === "history.started" && completed.type === "history.completed") {
      expect(started.payload.batchId).toBe(completed.payload.batchId);
    }
  });

  it("parses pairing request and accepted response", () => {
    const request = PairingRequestSchema.parse({
      version: PROTOCOL_VERSION,
      type: "pairing.request",
      requestId: "pair-1",
      deviceName: "iPhone",
      pairingCode: "123456",
      timestamp: 1_735_000_000_000,
    });
    const response = PairingResponseSchema.parse({
      version: PROTOCOL_VERSION,
      type: "pairing.response",
      requestId: request.requestId,
      machineId: "mac-1",
      deviceId: "iphone-1",
      status: "accepted",
      deviceToken: "opaque-device-token",
      expiresAt: 1_735_086_400_000,
    });

    expect(response.status).toBe("accepted");
  });

  it("rejects an unknown event type", () => {
    expect(() => EventEnvelopeSchema.parse({
      ...envelopeFields,
      type: "chat.message.unknown",
      payload: {},
    })).toThrow();
  });

  it("rejects an unsupported protocol version", () => {
    expect(() => parseCommand({
      ...envelopeFields,
      version: PROTOCOL_VERSION + 1,
      requestId: "req-1",
      type: "session.list",
      payload: {},
    })).toThrow();
  });

  it("accepts increasing sequence values and rejects gaps backwards or invalid values", () => {
    expect(validateSequence(undefined, 1)).toBe(true);
    expect(validateSequence(1, 2)).toBe(true);
    expect(validateSequence(2, 2)).toBe(false);
    expect(validateSequence(2, 1)).toBe(false);
    expect(validateSequence(2, 0)).toBe(false);
    expect(validateSequence(2, 2.5)).toBe(false);
  });

  it("uses a strict discriminated union for relay envelopes", () => {
    const relay = RelayMessageSchema.parse({
      type: "relay.payload",
      machineId: "mac-1",
      messageId: "relay-1",
      sender: "device",
      targetDeviceId: "iphone-2",
      body: {
        version: PROTOCOL_VERSION,
        requestId: "request-1",
        machineId: "mac-1",
        deviceId: "iphone-1",
        timestamp: 1_735_000_000_000,
        type: "session.list",
        payload: {},
      },
    });
    expect(relay.type).toBe("relay.payload");
    expect(() => RelayMessageSchema.parse({ ...relay, unexpected: true })).toThrow();
  });

  it("round-trips a pairing link and normalises the stored wss address", () => {
    const link = pairingLink({
      relay: "wss://relay.example.com",
      machineId: "machine_macmini",
      pairingSecret: "s3cret-value-that-is-long-enough",
    });

    // The client derives both HTTPS and WSS from one base address, so the
    // encoded relay must not keep the connector's wss:// scheme.
    expect(link.startsWith("dshanywhere://pair?")).toBe(true);
    expect(link).not.toContain("wss%3A");

    expect(parsePairingLink(link)).toEqual({
      relay: "https://relay.example.com",
      machineId: "machine_macmini",
      pairingSecret: "s3cret-value-that-is-long-enough",
    });
  });

  it("rejects pairing codes that did not come from the connector", () => {
    expect(parsePairingLink("https://example.com/?machineId=mac-1")).toBeUndefined();
    expect(parsePairingLink("dshanywhere://pair?machineId=mac-1")).toBeUndefined();
    expect(parsePairingLink("dshanywhere://pair?relay=https%3A%2F%2Fr.example&machineId=mac-1&secret=")).toBeUndefined();
    expect(parsePairingLink("not a url")).toBeUndefined();
  });

  it("rejects a relay scheme the iOS client could not dial", () => {
    expect(() => relayHTTPSURL("ftp://relay.example.com")).toThrow();
    expect(relayHTTPSURL("https://relay.example.com/")).toBe("https://relay.example.com");
  });

  it("carries a question and its tappable options to the device", () => {
    const parsed = EventEnvelopeSchema.parse({
      ...envelopeFields,
      sessionId: "session-1",
      type: "question.asked",
      payload: {
        id: "question_1",
        sessionId: "session-1",
        questions: [
          {
            id: "mode",
            question: "Which mode?",
            header: "Choose Mode",
            options: [{ label: "Fast" }, { label: "Careful", description: "Verify each step" }],
            multiSelect: false,
          },
        ],
      },
    });

    expect(parsed.type).toBe("question.asked");
    if (parsed.type === "question.asked") {
      expect(parsed.payload.questions[0]?.options?.map((option) => option.label)).toEqual(["Fast", "Careful"]);
    }
  });

  it("accepts a question answer command and rejects an empty one", () => {
    const commandFields = {
      version: PROTOCOL_VERSION,
      machineId: "mac-1",
      deviceId: "iphone-1",
      timestamp: 1_735_000_000_000,
    };
    const command = parseCommand({
      ...commandFields,
      requestId: "req-1",
      type: "question.answer",
      payload: {
        questionId: "question_1",
        answers: [{ id: "mode", selected: ["Fast"] }, { id: "extra", selected: [], custom: "Add tests" }],
      },
    });
    expect(command.type).toBe("question.answer");

    // The tool awaits one answer per question, so an empty selection list must
    // not be accepted in place of a real answer.
    expect(() => parseCommand({
      ...envelopeFields,
      requestId: "req-2",
      type: "question.answer",
      payload: { questionId: "question_1", answers: [] },
    })).toThrow();
  });

  it("accepts workspace rename and delete commands", () => {
    const fields = {
      version: PROTOCOL_VERSION,
      machineId: "mac-1",
      deviceId: "iphone-1",
      timestamp: 1_735_000_000_000,
    };
    expect(parseCommand({
      ...fields,
      requestId: "rename-1",
      type: "workspace.rename",
      payload: { workspaceId: "workspace-1", title: "Mobile project" },
    }).type).toBe("workspace.rename");
    expect(parseCommand({
      ...fields,
      requestId: "delete-1",
      type: "workspace.delete",
      payload: { workspaceId: "workspace-1" },
    }).type).toBe("workspace.delete");
  });

  it("accepts remote workspace, directory, mode and session-title commands", () => {
    const fields = {
      version: PROTOCOL_VERSION,
      machineId: "mac-1",
      deviceId: "iphone-1",
      timestamp: 1_735_000_000_000,
    };
    expect(parseCommand({ ...fields, requestId: "workspace-create", type: "workspace.create",
      payload: { path: "/Users/me/Code", title: "Code" } }).type).toBe("workspace.create");
    expect(parseCommand({ ...fields, requestId: "workspace-list", type: "workspace.catalog", payload: {} }).type).toBe("workspace.catalog");
    expect(parseCommand({ ...fields, requestId: "directory-list", type: "directory.list", payload: { path: "/Users/me" } }).type).toBe("directory.list");
    expect(parseCommand({ ...fields, requestId: "mode-list", type: "mode.catalog", payload: {} }).type).toBe("mode.catalog");
    expect(parseCommand({ ...fields, requestId: "session-rename", sessionId: "session-1", type: "session.rename",
      payload: { title: "Remote title" } }).type).toBe("session.rename");
  });

  it("carries request-correlated remote catalogs with only host-issued paths", () => {
    const workspace = EventEnvelopeSchema.parse({
      ...envelopeFields, type: "workspace.catalog",
      payload: { workspaces: [{ id: "workspace-1", title: "Code", path: "/Users/me/Code" }] },
    });
    const directory = EventEnvelopeSchema.parse({
      ...envelopeFields, sequence: 2, type: "directory.list",
      payload: { path: "/Users/me", parentPath: "/Users", directories: [{ name: "Code", path: "/Users/me/Code" }] },
    });
    const modes = EventEnvelopeSchema.parse({
      ...envelopeFields, sequence: 3, type: "mode.catalog",
      payload: { defaultMode: "standard", modes: [{ id: "standard", name: "标准模式", description: "Mac preset" }] },
    });
    expect(workspace.type).toBe("workspace.catalog");
    expect(directory.type).toBe("directory.list");
    expect(modes.type).toBe("mode.catalog");
  });
});

describe("prompt attachments", () => {
  const base = { version: PROTOCOL_VERSION, timestamp: 1, machineId: "machine_1",
                 deviceId: "device_1", sessionId: "session_1" };

  it("accepts a prompt that carries attachments", () => {
    // The regression this locks in: `attachments` was not declared, the payload
    // schema is strict, so the Relay rejected the whole prompt — the file had
    // already been uploaded separately, so it appeared while the text did not.
    const message = {
      type: "prompt.send",
      requestId: "req_1",
      ...base,
      payload: { text: "look at this", attachments: [{ type: "file", receiptId: "receipt_1" }] },
    };
    expect(CommandEnvelopeSchema.safeParse(message).success).toBe(true);
  });

  it("accepts a file reference inside content, which is where the Harness looks", () => {
    const message = {
      type: "prompt.send",
      requestId: "req_2",
      ...base,
      payload: { content: [{ type: "file", receiptId: "receipt_1" }, { type: "text", text: "hi" }] },
    };
    expect(CommandEnvelopeSchema.safeParse(message).success).toBe(true);
  });

  it("counts legacy attachments together with canonical content", () => {
    const message = {
      type: "prompt.send",
      requestId: "req-combined-files",
      ...base,
      payload: {
        content: Array.from({ length: 8 }, (_, index) => ({
          type: "file" as const,
          receiptId: `content-${index}`,
        })),
        attachments: Array.from({ length: 9 }, (_, index) => ({
          type: "file" as const,
          receiptId: `legacy-${index}`,
        })),
      },
    };
    expect(CommandEnvelopeSchema.safeParse(message).success).toBe(false);
  });

  it("rejects more than sixteen file or image parts in content", () => {
    const message = {
      type: "prompt.send",
      requestId: "req-many-files",
      ...base,
      payload: {
        content: Array.from({ length: 17 }, (_, index) => ({
          type: "file" as const,
          receiptId: `receipt-${index}`,
        })),
      },
    };
    expect(CommandEnvelopeSchema.safeParse(message).success).toBe(false);
  });

  it("rejects inline image data that exceeds the shared prompt transport budget", () => {
    const message = {
      type: "prompt.send",
      requestId: "req-inline-image-budget",
      ...base,
      payload: {
        content: [{
          type: "image" as const,
          mediaType: "image/jpeg" as const,
          data: "A".repeat(8 * 1024 * 1024 + 1),
        }],
      },
    };
    expect(CommandEnvelopeSchema.safeParse(message).success).toBe(false);
  });

  it("still rejects an undeclared field", () => {
    const message = {
      type: "prompt.send",
      requestId: "req_3",
      ...base,
      payload: { text: "hi", receipts: ["receipt_1"] },
    };
    expect(CommandEnvelopeSchema.safeParse(message).success).toBe(false);
  });

  it("accepts a thumbnail on chat attachments but caps its length", () => {
    const attachment = {
      id: "sha256:abc",
      name: "shot.png",
      mediaType: "image/png",
      thumbnail: "data:image/png;base64,iVBORw0KGgo=",
    };
    const parsed = EventEnvelopeSchema.parse({
      ...envelopeFields,
      sessionId: "session-1",
      type: "user.message.accepted",
      payload: { id: "u1", role: "user", markdown: "see?", attachments: [attachment] },
    });
    expect(parsed.type).toBe("user.message.accepted");
    if (parsed.type === "user.message.accepted") {
      expect(parsed.payload.attachments?.[0]).toMatchObject({ id: "sha256:abc" });
    }
    const oversized = { ...attachment, thumbnail: `data:image/png;base64,${"A".repeat(400_000)}` };
    expect(EventEnvelopeSchema.safeParse({
      ...envelopeFields,
      sessionId: "session-1",
      type: "user.message.accepted",
      payload: { id: "u1", role: "user", markdown: "see?", attachments: [oversized] },
    }).success).toBe(false);
  });
});
