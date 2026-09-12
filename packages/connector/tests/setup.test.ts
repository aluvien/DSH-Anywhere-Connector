import { mkdtemp, readFile, rm, stat } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { afterEach, describe, expect, it, vi } from "vitest";
import { runCli } from "../src/cli.js";
import { relayRegistrationURL, relayWebSocketURL, setupConnector } from "../src/setup.js";

const temporaryDirectories: string[] = [];

afterEach(async () => {
  await Promise.all(temporaryDirectories.splice(0).map(async (directory) => rm(directory, { recursive: true, force: true })));
});

async function temporaryConfigPath(): Promise<string> {
  const directory = await mkdtemp(join(tmpdir(), "dsh-anywhere-connector-test-"));
  temporaryDirectories.push(directory);
  return join(directory, "nested", "connector.json");
}

const registration = { machineId: "machine-registered", machineToken: "machine-token-secret", pairingSecret: "pairing-secret" };

describe("Connector setup", () => {
  it("registers over HTTPS, converts to WSS, and atomically writes private files", async () => {
    const configPath = await temporaryConfigPath();
    const request = vi.fn(async (_input: RequestInfo | URL, init?: RequestInit) => {
      expect(String(_input)).toBe("https://relay.example.test/v1/machines/register");
      expect(init?.headers).toMatchObject({ authorization: "Bearer bootstrap-secret" });
      expect(init?.body).toBe(JSON.stringify({ machineName: "My Mac" }));
      return Response.json(registration, { status: 201 });
    });
    const result = await setupConnector({
      relay: "https://relay.example.test",
      bootstrapToken: "bootstrap-secret",
      machineName: "My Mac",
      configPath,
    }, { fetch: request as unknown as typeof fetch, randomToken: () => "bridge-token-secret-012345678901234567890123" });

    expect(result.config.relayURL).toBe("wss://relay.example.test/");
    expect(result.config.bridgeBaseURL).toBe("http://127.0.0.1:3080/dsh-anywhere/v1");
    const configContents = await readFile(configPath, "utf8");
    const bridgeEnvPath = join(dirname(configPath), "bridge.env");
    const bridgeEnvContents = await readFile(bridgeEnvPath, "utf8");
    expect(configContents).toContain('"machineToken": "machine-token-secret"');
    expect(bridgeEnvContents).toBe("DSH_ANYWHERE_CONNECTOR_TOKEN=bridge-token-secret-012345678901234567890123\n");
    expect((await stat(configPath)).mode & 0o777).toBe(0o600);
    expect((await stat(bridgeEnvPath)).mode & 0o777).toBe(0o600);
    expect((await stat(dirname(configPath))).mode & 0o777).toBe(0o700);
  });

  it("never prints bootstrap, machine, or bridge tokens in setup output", async () => {
    const configPath = await temporaryConfigPath();
    const output: string[] = [];
    const errors: string[] = [];
    const status = await runCli([
      "setup", "--relay", "https://relay.example.test", "--bootstrap-token", "bootstrap-secret", "--machine-name", "My Mac", "--config", configPath,
    ], {
      fetch: vi.fn(async () => Response.json(registration, { status: 201 })) as unknown as typeof fetch,
      stdout: (line) => output.push(line),
      stderr: (line) => errors.push(line),
    });
    expect(status).toBe(0);
    expect(errors).toEqual([]);
    expect(output).toHaveLength(1);
    expect(output[0]).toContain("machine-registered");
    expect(output[0]).toContain("pairing-secret");
    expect(output[0]).not.toContain("bootstrap-secret");
    expect(output[0]).not.toContain("machine-token-secret");
    expect(output[0]).not.toContain("DSH_ANYWHERE_CONNECTOR_TOKEN");
  });

  it("rejects unsafe relay URLs and keeps upstream error bodies out of failures", async () => {
    expect(() => relayWebSocketURL("http://relay.example.test")).toThrow("relay must use https");
    expect(relayRegistrationURL("https://relay.example.test/base")).toBe("https://relay.example.test/base/v1/machines/register");
    const configPath = await temporaryConfigPath();
    await expect(setupConnector({
      relay: "https://relay.example.test",
      bootstrapToken: "bootstrap-secret",
      machineName: "My Mac",
      configPath,
    }, { fetch: vi.fn(async () => new Response("bootstrap-secret", { status: 401 })) as unknown as typeof fetch }))
      .rejects.toThrow("Relay registration failed (HTTP 401)");
  });
});
