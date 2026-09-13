import { randomBytes, randomUUID } from "node:crypto";
import { chmod, mkdir, rename, writeFile } from "node:fs/promises";
import { basename, dirname, join } from "node:path";
import { pairingLink, relayHTTPSURL } from "@dsh-anywhere/protocol";
import { ConfigError, parseConfig, type ConnectorConfig } from "./config.js";

export interface SetupOptions {
  readonly relay: string;
  readonly bootstrapToken: string;
  readonly machineName: string;
  readonly configPath: string;
  readonly bridgeBaseURL?: string;
}

export interface SetupResult {
  readonly machineId: string;
  readonly pairingSecret: string;
  readonly pairingLink: string;
  readonly configPath: string;
  readonly bridgeEnvPath: string;
  readonly config: ConnectorConfig;
}

export interface SetupDependencies {
  readonly fetch?: typeof fetch;
  readonly randomToken?: () => string;
}

interface Registration {
  readonly machineId: string;
  readonly machineToken: string;
  readonly pairingSecret: string;
}

const DEFAULT_BRIDGE_BASE_URL = "http://127.0.0.1:3080/dsh-anywhere/v1";

/** Register a machine once, then keep all long-lived secrets on its local disk. */
export async function setupConnector(options: SetupOptions, dependencies: SetupDependencies = {}): Promise<SetupResult> {
  const relayURL = relayWebSocketURL(options.relay);
  const machineName = options.machineName.trim();
  if (machineName.length === 0 || machineName.length > 256) throw new ConfigError("machine-name must be between 1 and 256 characters");
  if (options.bootstrapToken.trim().length === 0) throw new ConfigError("bootstrap-token is required");

  const registration = await registerMachine(
    options.relay,
    options.bootstrapToken,
    machineName,
    dependencies.fetch ?? fetch,
  );
  const bridgeToken = dependencies.randomToken?.() ?? randomBytes(32).toString("base64url");
  if (Buffer.byteLength(bridgeToken, "utf8") < 32) throw new SetupError("generated bridge token is unexpectedly short");
  const config = parseConfig({
    relayURL,
    machineId: registration.machineId,
    machineToken: registration.machineToken,
    bridgeBaseURL: options.bridgeBaseURL ?? DEFAULT_BRIDGE_BASE_URL,
    bridgeToken,
    pairingSecret: registration.pairingSecret,
  }, {});
  const bridgeEnvPath = join(dirname(options.configPath), "bridge.env");
  await writeSetupFiles(options.configPath, bridgeEnvPath, config);
  return {
    machineId: registration.machineId,
    pairingSecret: registration.pairingSecret,
    pairingLink: pairingLink({
      relay: options.relay,
      machineId: registration.machineId,
      pairingSecret: registration.pairingSecret,
    }),
    configPath: options.configPath,
    bridgeEnvPath,
    config,
  };
}

export function relayWebSocketURL(value: string): string {
  let url: URL;
  try {
    url = new URL(value);
  } catch {
    throw new ConfigError("relay must be an absolute HTTPS URL");
  }
  if (url.protocol !== "https:") throw new ConfigError("relay must use https");
  if (url.username !== "" || url.password !== "") throw new ConfigError("relay must not contain credentials");
  url.protocol = "wss:";
  return url.toString();
}

export async function registerMachine(
  relay: string,
  bootstrapToken: string,
  machineName: string,
  request: typeof fetch,
): Promise<Registration> {
  const response = await request(relayRegistrationURL(relay), {
    method: "POST",
    headers: {
      authorization: `Bearer ${bootstrapToken}`,
      "content-type": "application/json",
    },
    body: JSON.stringify({ machineName }),
    signal: AbortSignal.timeout(15_000),
  });
  if (!response.ok) throw new SetupError(`Relay registration failed (HTTP ${response.status})`);
  let body: unknown;
  try {
    body = await response.json();
  } catch {
    throw new SetupError("Relay registration returned invalid JSON");
  }
  const registration = asRegistration(body);
  if (registration === undefined) throw new SetupError("Relay registration returned an invalid response");
  return registration;
}

export function relayRegistrationURL(relay: string): string {
  let url: URL;
  try {
    url = new URL(relay);
  } catch {
    throw new ConfigError("relay must be an absolute HTTPS URL");
  }
  if (url.protocol !== "https:") throw new ConfigError("relay must use https");
  return new URL("v1/machines/register", trailingSlash(url.toString())).toString();
}

export async function writeSetupFiles(configPath: string, bridgeEnvPath: string, config: ConnectorConfig): Promise<void> {
  const directory = dirname(configPath);
  if (dirname(bridgeEnvPath) !== directory) throw new ConfigError("bridge.env must be in the config directory");
  await mkdir(directory, { recursive: true, mode: 0o700 });
  await chmod(directory, 0o700);
  await atomicWrite(configPath, `${JSON.stringify(config, null, 2)}\n`);
  await atomicWrite(bridgeEnvPath, `DSH_ANYWHERE_CONNECTOR_TOKEN=${config.bridgeToken}\n`);
}

export class SetupError extends Error {
  override name = "SetupError";
}

async function atomicWrite(path: string, contents: string): Promise<void> {
  const temporary = join(dirname(path), `.${basename(path)}.${randomUUID()}.tmp`);
  await writeFile(temporary, contents, { encoding: "utf8", mode: 0o600, flag: "wx" });
  await chmod(temporary, 0o600);
  await rename(temporary, path);
  await chmod(path, 0o600);
}

function asRegistration(value: unknown): Registration | undefined {
  if (typeof value !== "object" || value === null || Array.isArray(value)) return undefined;
  const body = value as Record<string, unknown>;
  if (typeof body.machineId !== "string" || body.machineId.length === 0) return undefined;
  if (typeof body.machineToken !== "string" || body.machineToken.length === 0) return undefined;
  if (typeof body.pairingSecret !== "string" || body.pairingSecret.length === 0) return undefined;
  return { machineId: body.machineId, machineToken: body.machineToken, pairingSecret: body.pairingSecret };
}

/**
 * Asks the Relay to mint a single-use pairing code for this machine.
 *
 * Only the machine token can do this: issuing a code is the capability that
 * lets a new device in, so it stays with the machine operator. The code is
 * short-lived and consumed on use, replacing the long-lived pairing secret for
 * anything paired from now on.
 */
export async function requestPairingCode(
  config: ConnectorConfig,
  request: typeof fetch = fetch,
): Promise<{ code: string; expiresAt: number }> {
  const base = trailingSlash(relayHTTPSURL(config.relayURL));
  const url = new URL(`v1/machines/${encodeURIComponent(config.machineId)}/pairing-codes`, base);
  const response = await request(url.toString(), {
    method: "POST",
    headers: { authorization: `Bearer ${config.machineToken}`, "content-type": "application/json" },
    body: "{}",
    signal: AbortSignal.timeout(15_000),
  });
  if (!response.ok) throw new SetupError(`Relay refused to issue a pairing code (HTTP ${response.status})`);
  let body: unknown;
  try {
    body = await response.json();
  } catch {
    throw new SetupError("Relay returned an invalid pairing code response");
  }
  const record = typeof body === "object" && body !== null ? body as Record<string, unknown> : {};
  if (typeof record.code !== "string" || record.code.length === 0 || typeof record.expiresAt !== "number") {
    throw new SetupError("Relay returned an invalid pairing code response");
  }
  return { code: record.code, expiresAt: record.expiresAt };
}

/**
 * Publishes the current one-time code where the local bridge's pairing page can
 * read it. Written 0600 in the same directory as the connector config, which
 * already holds the machine token and pairing secret.
 */
export async function writePairingCodeFile(
  path: string,
  payload: { readonly machineId: string; readonly code: string; readonly expiresAt: number },
): Promise<void> {
  await atomicWrite(path, `${JSON.stringify(payload, null, 2)}\n`);
}

function trailingSlash(value: string): string {
  return value.endsWith("/") ? value : `${value}/`;
}
