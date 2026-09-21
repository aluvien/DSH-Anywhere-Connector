import { mkdtemp, readFile, rm, stat } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { afterEach, describe, expect, it, vi } from "vitest";
import { runCli } from "../src/cli.js";
import { enrollConnector, relayEnrollmentURL, relayRegistrationURL, relayWebSocketURL, setupConnector } from "../src/setup.js";

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

  it("enrolls with a short-lived installer token instead of the admin secret", async () => {
    const configPath = await temporaryConfigPath();
    const request = vi.fn(async (_input: RequestInfo | URL, init?: RequestInit) => {
      expect(String(_input)).toBe("https://relay.example.test/v1/machines/enroll");
      expect(init?.headers).toMatchObject({ authorization: "Bearer one-use-install-token" });
      expect(init?.body).toBe(JSON.stringify({ machineName: "New Mac" }));
      return Response.json(registration, { status: 201 });
    });
    const result = await enrollConnector({
      relay: "https://relay.example.test",
      enrollmentToken: "one-use-install-token",
      machineName: "New Mac",
      configPath,
    }, { fetch: request as unknown as typeof fetch, randomToken: () => "bridge-token-secret-012345678901234567890123" });

    expect(result.machineId).toBe("machine-registered");
    expect(relayEnrollmentURL("https://relay.example.test/base"))
      .toBe("https://relay.example.test/base/v1/machines/enroll");
    expect(await readFile(configPath, "utf8")).not.toContain("one-use-install-token");
  });

  it("accepts the public installer token through the environment", async () => {
    const configPath = await temporaryConfigPath();
    const output: string[] = [];
    const status = await runCli([
      "enroll", "--relay", "https://relay.example.test", "--machine-name", "New Mac", "--config", configPath,
    ], {
      environment: { DSH_ANYWHERE_ENROLLMENT_TOKEN: "environment-install-token" },
      fetch: vi.fn(async (_input, init) => {
        expect(init?.headers).toMatchObject({ authorization: "Bearer environment-install-token" });
        return Response.json(registration, { status: 201 });
      }) as unknown as typeof fetch,
      stdout: (line) => output.push(line),
    });
    expect(status).toBe(0);
    expect(output.join("\n")).not.toContain("environment-install-token");
  });

  it("prints a terminal QR and publishes the same one-time code for the local page", async () => {
    const configPath = await temporaryConfigPath();
    await setupConnector({
      relay: "https://relay.example.test",
      bootstrapToken: "bootstrap-secret",
      machineName: "My Mac",
      configPath,
    }, {
      fetch: vi.fn(async () => Response.json(registration, { status: 201 })) as unknown as typeof fetch,
      randomToken: () => "bridge-token-secret-012345678901234567890123",
    });
    const output: string[] = [];
    const status = await runCli(["pair-qr", "--config", configPath], {
      fetch: vi.fn(async () => Response.json({ code: "ABCD2345", expiresAt: Date.now() + 600_000 },
        { status: 201 })) as unknown as typeof fetch,
      stdout: (line) => output.push(line),
    });

    expect(status).toBe(0);
    expect(output.join("\n")).toContain("█");
    expect(output.join("\n")).toContain("Pairing code: ABCD2345");
    expect(output.join("\n")).not.toContain("machine-token-secret");
    const published = JSON.parse(await readFile(join(dirname(configPath), "pairing-code.json"), "utf8")) as Record<string, unknown>;
    expect(published).toMatchObject({ machineId: "machine-registered", code: "ABCD2345" });
  });
});
