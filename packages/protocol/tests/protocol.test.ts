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
});
