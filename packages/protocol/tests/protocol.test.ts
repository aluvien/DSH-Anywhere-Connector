import { describe, expect, it } from "vitest";
import {
  PROTOCOL_VERSION,
  EventEnvelopeSchema,
  PairingRequestSchema,
  PairingResponseSchema,
  RelayMessageSchema,
  parseCommand,
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
});
