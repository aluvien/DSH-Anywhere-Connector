import { describe, expect, it } from "vitest";
import {
  PROTOCOL_VERSION,
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
