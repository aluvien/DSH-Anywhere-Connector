#!/usr/bin/env node
import { pairingLink } from "@dsh-anywhere/protocol";
import { loadConfig, defaultConfigPath, redactSecrets, type ConnectorConfig } from "./config.js";
import { DSHAnywhereConnector, bridgeAPIURL } from "./connector.js";
import { setupConnector, requestPairingCode } from "./setup.js";

type Command = "start" | "status" | "setup" | "pair";

export async function runCli(
  args: readonly string[],
  dependencies: { readonly fetch?: typeof fetch; readonly stdout?: (line: string) => void; readonly stderr?: (line: string) => void } = {},
): Promise<number> {
  const stdout = dependencies.stdout ?? console.log;
  const stderr = dependencies.stderr ?? console.error;
  const parsed = parseArgs(args);
  if (parsed === undefined) {
    stderr("Usage: dsh-anywhere <start|status|pair> [--config <path>] | setup --relay <https://...> --bootstrap-token <token> --machine-name <name> [--bridge-base-url <url>] [--config <path>]");
    return 64;
  }
  try {
    if (parsed.command === "pair") {
      const config = await loadConfig(parsed.configPath);
      const issued = await requestPairingCode(config, dependencies.fetch ?? fetch);
      stdout(JSON.stringify({
        machineId: config.machineId,
        pairingCode: issued.code,
        expiresAt: issued.expiresAt,
        // Single-use and short-lived, unlike the pairingSecret printed by setup.
        pairingLink: pairingLink({
          relay: config.relayURL,
          machineId: config.machineId,
          pairingCode: issued.code,
        }),
      }));
      return 0;
    }
    if (parsed.command === "setup") {
      const result = await setupConnector({
        relay: parsed.relay,
        bootstrapToken: parsed.bootstrapToken,
        machineName: parsed.machineName,
        configPath: parsed.configPath,
        ...(parsed.bridgeBaseURL === undefined ? {} : { bridgeBaseURL: parsed.bridgeBaseURL }),
      }, dependencies.fetch === undefined ? {} : { fetch: dependencies.fetch });
      stdout(JSON.stringify({
        machineId: result.machineId,
        pairingSecret: result.pairingSecret,
        pairingLink: result.pairingLink,
        // Open this on the Mac to scan the QR with the iPhone instead of
        // retyping machineId + pairing secret. Loopback-only by design.
        pairingPage: `${result.config.bridgeBaseURL}/pairing`,
        configPath: result.configPath,
        nextStep: `Before starting the local DSH bridge, run: . ${shellQuote(result.bridgeEnvPath)}`,
      }));
      return 0;
    }
    const config = await loadConfig(parsed.configPath);
    if (parsed.command === "status") {
      const result = await connectorStatus(config, dependencies.fetch ?? fetch);
      stdout(JSON.stringify(result));
      return result.ok ? 0 : 1;
    }
    const connector = new DSHAnywhereConnector(config);
    connector.start();
    const stop = () => {
      void connector.stop().finally(() => process.exit(0));
    };
    process.once("SIGINT", stop);
    process.once("SIGTERM", stop);
    return await new Promise<number>(() => undefined);
  } catch (error) {
    stderr(redactSecrets(error instanceof Error ? error.message : String(error)));
    return 1;
  }
}

export async function connectorStatus(config: ConnectorConfig, request: typeof fetch): Promise<{
  ok: boolean;
  config: { relayURL: string; machineId: string; bridgeBaseURL: string };
  bridge: { ok: boolean; status?: number; machineId?: string };
}> {
  const summary = {
    config: {
      relayURL: config.relayURL,
      machineId: config.machineId,
      bridgeBaseURL: config.bridgeBaseURL,
    },
  };
  try {
    const response = await request(bridgeAPIURL(config.bridgeBaseURL, "/health"), {
      headers: { authorization: `Bearer ${config.bridgeToken}` },
      signal: AbortSignal.timeout(5_000),
    });
    if (!response.ok) return { ok: false, ...summary, bridge: { ok: false, status: response.status } };
    const body: unknown = await response.json();
    const machineId = typeof body === "object" && body !== null && "machineId" in body && typeof body.machineId === "string"
      ? body.machineId
      : undefined;
    return { ok: true, ...summary, bridge: { ok: true, ...(machineId === undefined ? {} : { machineId }) } };
  } catch {
    return { ok: false, ...summary, bridge: { ok: false } };
  }
}

type ParsedArgs =
  | { readonly command: "start" | "status" | "pair"; readonly configPath: string }
  | {
    readonly command: "setup";
    readonly configPath: string;
    readonly relay: string;
    readonly bootstrapToken: string;
    readonly machineName: string;
    readonly bridgeBaseURL?: string;
  };

function parseArgs(args: readonly string[]): ParsedArgs | undefined {
  const [command, ...rest] = args;
  if (command !== "start" && command !== "status" && command !== "setup" && command !== "pair") return undefined;
  let configPath = defaultConfigPath();
  const options: Record<string, string> = {};
  for (let index = 0; index < rest.length; index += 1) {
    const argument = rest[index];
    const value = rest[index + 1];
    if (value === undefined) return undefined;
    if (argument !== "--config" && argument !== "--relay" && argument !== "--bootstrap-token" && argument !== "--machine-name" && argument !== "--bridge-base-url") return undefined;
    if (options[argument] !== undefined) return undefined;
    options[argument] = value;
    if (argument === "--config") configPath = value;
    index += 1;
  }
  if (command !== "setup") {
    if (Object.keys(options).some((option) => option !== "--config")) return undefined;
    return { command, configPath };
  }
  const relay = options["--relay"];
  const bootstrapToken = options["--bootstrap-token"];
  const machineName = options["--machine-name"];
  if (relay === undefined || bootstrapToken === undefined || machineName === undefined) return undefined;
  return {
    command,
    configPath,
    relay,
    bootstrapToken,
    machineName,
    ...(options["--bridge-base-url"] === undefined ? {} : { bridgeBaseURL: options["--bridge-base-url"] }),
  };
}

function shellQuote(value: string): string {
  return `'${value.replaceAll("'", "'\\''")}'`;
}

if (import.meta.url === `file://${process.argv[1]}`) {
  void runCli(process.argv.slice(2)).then((code) => {
    if (code !== 0) process.exitCode = code;
  });
}
