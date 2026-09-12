import { describe, expect, it } from "vitest";
import { ConfigError, defaultConfigPath, parseConfig, redactSecrets } from "../src/config.js";

const complete = {
  relayURL: "wss://relay.example.test",
  machineId: "machine-1",
  machineToken: "machine-secret",
  bridgeBaseURL: "http://127.0.0.1:3080/dsh-anywhere/v1",
  bridgeToken: "bridge-secret",
};

describe("connector config", () => {
  it("merges environment values without leaking them", () => {
    const config = parseConfig({ ...complete, machineToken: "old" }, { DSH_ANYWHERE_MACHINE_TOKEN: "machine-secret" });
    expect(config.machineToken).toBe("machine-secret");
    expect(config.bridgeBaseURL).toBe("http://127.0.0.1:3080/dsh-anywhere/v1");
    expect(redactSecrets("Bearer machine-secret bridge-secret", config)).toBe("Bearer [REDACTED] [REDACTED]");
  });

  it("rejects publicly reachable insecure Relay URLs", () => {
    expect(() => parseConfig({ ...complete, relayURL: "ws://relay.example.test" })).toThrow(ConfigError);
  });

  it("uses a supplied home for deterministic default paths", () => {
    expect(defaultConfigPath({}, "darwin", "/tmp/test-home")).toBe(
      "/tmp/test-home/Library/Application Support/DSH Anywhere/connector.json",
    );
  });
});
