#!/usr/bin/env node
import { createRequire } from "node:module";
import { dirname, join } from "node:path";
import { pairingLink } from "@dsh-anywhere/protocol";
import { loadConfig, defaultConfigPath, redactSecrets, type ConnectorConfig } from "./config.js";
import { DSHAnywhereConnector, bridgeAPIURL } from "./connector.js";
import { enrollConnector, setupConnector, requestPairingCode, writePairingCodeFile } from "./setup.js";

type Command = "start" | "status" | "setup" | "enroll" | "pair" | "pair-qr";

export async function runCli(
  args: readonly string[],
  dependencies: { readonly fetch?: typeof fetch; readonly stdout?: (line: string) => void;
    readonly stderr?: (line: string) => void; readonly environment?: NodeJS.ProcessEnv } = {},
): Promise<number> {
  const stdout = dependencies.stdout ?? console.log;
  const stderr = dependencies.stderr ?? console.error;
  const parsed = parseArgs(args, dependencies.environment ?? process.env);
  if (parsed === undefined) {
    stderr("Usage: dsh-anywhere <start|status|pair|pair-qr> [--config <path>] | setup --relay <https://...> --bootstrap-token <token> --machine-name <name> [--bridge-base-url <url>] [--config <path>] | enroll --relay <https://...> --enrollment-token <token> --machine-name <name> [--bridge-base-url <url>] [--config <path>]");
    return 64;
  }
  try {
    if (parsed.command === "pair" || parsed.command === "pair-qr") {
      const config = await loadConfig(parsed.configPath);
      const issued = await requestPairingCode(config, dependencies.fetch ?? fetch);
      await writePairingCodeFile(join(dirname(parsed.configPath), "pairing-code.json"), {
        machineId: config.machineId,
        code: issued.code,
        expiresAt: issued.expiresAt,
      });
      const link = pairingLink({
        relay: config.relayURL,
        machineId: config.machineId,
        pairingCode: issued.code,
      });
      if (parsed.command === "pair-qr") {
        stdout(renderTerminalQRCode(link));
        stdout(`Pairing code: ${issued.code}`);
        stdout("This QR code can be used once and expires in 10 minutes.");
      } else stdout(JSON.stringify({
        machineId: config.machineId,
        pairingCode: issued.code,
        expiresAt: issued.expiresAt,
        // Single-use and short-lived, unlike the pairingSecret printed by setup.
        pairingLink: link,
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
    if (parsed.command === "enroll") {
      const result = await enrollConnector({
        relay: parsed.relay,
        enrollmentToken: parsed.enrollmentToken,
        machineName: parsed.machineName,
        configPath: parsed.configPath,
        ...(parsed.bridgeBaseURL === undefined ? {} : { bridgeBaseURL: parsed.bridgeBaseURL }),
      }, dependencies.fetch === undefined ? {} : { fetch: dependencies.fetch });
      stdout(JSON.stringify({
        machineId: result.machineId,
        pairingPage: `${result.config.bridgeBaseURL}/pairing`,
        configPath: result.configPath,
      }));
      return 0;
    }
    const config = await loadConfig(parsed.configPath);
    if (parsed.command === "status") {
      const result = await connectorStatus(config, dependencies.fetch ?? fetch);
      stdout(JSON.stringify(result));
      return result.ok ? 0 : 1;
    }
    const connector = new DSHAnywhereConnector(config, {
      // Publish a fresh single-use code beside the config so the local pairing
      // page shows a code instead of the long-lived secret.
      pairingCodePath: join(dirname(parsed.configPath), "pairing-code.json"),
    });
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
  | { readonly command: "start" | "status" | "pair" | "pair-qr"; readonly configPath: string }
  | {
    readonly command: "setup";
    readonly configPath: string;
    readonly relay: string;
    readonly bootstrapToken: string;
    readonly machineName: string;
    readonly bridgeBaseURL?: string;
  }
  | {
    readonly command: "enroll";
    readonly configPath: string;
    readonly relay: string;
    readonly enrollmentToken: string;
    readonly machineName: string;
    readonly bridgeBaseURL?: string;
  };

function parseArgs(args: readonly string[], environment: NodeJS.ProcessEnv): ParsedArgs | undefined {
  const [command, ...rest] = args;
  if (command !== "start" && command !== "status" && command !== "setup" && command !== "enroll" &&
      command !== "pair" && command !== "pair-qr") return undefined;
  let configPath = defaultConfigPath();
  const options: Record<string, string> = {};
  for (let index = 0; index < rest.length; index += 1) {
    const argument = rest[index];
    const value = rest[index + 1];
    if (value === undefined) return undefined;
    if (argument !== "--config" && argument !== "--relay" && argument !== "--bootstrap-token" &&
        argument !== "--enrollment-token" && argument !== "--machine-name" && argument !== "--bridge-base-url") return undefined;
    if (options[argument] !== undefined) return undefined;
    options[argument] = value;
    if (argument === "--config") configPath = value;
    index += 1;
  }
  if (command !== "setup" && command !== "enroll") {
    if (Object.keys(options).some((option) => option !== "--config")) return undefined;
    return { command, configPath };
  }
  const relay = options["--relay"];
  const machineName = options["--machine-name"];
  if (relay === undefined || machineName === undefined) return undefined;
  const bridgeBaseURL = options["--bridge-base-url"];
  if (command === "setup") {
    const bootstrapToken = options["--bootstrap-token"];
    if (bootstrapToken === undefined || options["--enrollment-token"] !== undefined) return undefined;
    return { command, configPath, relay, bootstrapToken, machineName,
      ...(bridgeBaseURL === undefined ? {} : { bridgeBaseURL }) };
  }
  const enrollmentToken = options["--enrollment-token"] ?? environment.DSH_ANYWHERE_ENROLLMENT_TOKEN;
  if (enrollmentToken === undefined || options["--bootstrap-token"] !== undefined) return undefined;
  return { command, configPath, relay, enrollmentToken, machineName,
    ...(bridgeBaseURL === undefined ? {} : { bridgeBaseURL }) };
}

interface QRCode {
  addData(value: string): void;
  make(): void;
  getModuleCount(): number;
  isDark(row: number, column: number): boolean;
}

type QRCodeFactory = (typeNumber: number, errorCorrectionLevel: "M") => QRCode;
let qrCodeFactory: QRCodeFactory | undefined;

function renderTerminalQRCode(value: string): string {
  qrCodeFactory ??= createRequire(import.meta.url)("qrcode-generator") as QRCodeFactory;
  const code = qrCodeFactory(0, "M");
  code.addData(value);
  code.make();
  const size = code.getModuleCount();
  const margin = 2;
  const lines: string[] = [];
  const dark = (row: number, column: number): boolean =>
    row >= 0 && row < size && column >= 0 && column < size && code.isDark(row, column);
  for (let row = -margin; row < size + margin; row += 2) {
    let line = "";
    for (let column = -margin; column < size + margin; column += 1) {
      const top = dark(row, column);
      const bottom = dark(row + 1, column);
      line += top ? (bottom ? "█" : "▀") : (bottom ? "▄" : " ");
    }
    lines.push(line);
  }
  return lines.join("\n");
}

function shellQuote(value: string): string {
  return `'${value.replaceAll("'", "'\\''")}'`;
}

if (import.meta.url === `file://${process.argv[1]}`) {
  void runCli(process.argv.slice(2)).then((code) => {
    if (code !== 0) process.exitCode = code;
  });
}
