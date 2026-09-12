import { homedir } from "node:os";
import { join } from "node:path";
import { readFile } from "node:fs/promises";

export interface ConnectorConfig {
  readonly relayURL: string;
  readonly machineId: string;
  readonly machineToken: string;
  readonly bridgeBaseURL: string;
  readonly bridgeToken: string;
}

export type ConnectorEnvironment = Readonly<Record<string, string | undefined>>;

const REQUIRED_FIELDS: readonly (keyof ConnectorConfig)[] = [
  "relayURL",
  "machineId",
  "machineToken",
  "bridgeBaseURL",
  "bridgeToken",
];

const ENV_FIELDS: Readonly<Record<keyof ConnectorConfig, string>> = {
  relayURL: "DSH_ANYWHERE_RELAY_URL",
  machineId: "DSH_ANYWHERE_MACHINE_ID",
  machineToken: "DSH_ANYWHERE_MACHINE_TOKEN",
  bridgeBaseURL: "DSH_ANYWHERE_BRIDGE_BASE_URL",
  bridgeToken: "DSH_ANYWHERE_BRIDGE_TOKEN",
};

export function defaultConfigPath(
  environment: ConnectorEnvironment = process.env,
  platform = process.platform,
  home = homedir(),
): string {
  if (environment.DSH_ANYWHERE_CONFIG !== undefined) return environment.DSH_ANYWHERE_CONFIG;
  if (platform === "darwin") return join(home, "Library", "Application Support", "DSH Anywhere", "connector.json");
  return join(environment.XDG_CONFIG_HOME ?? join(home, ".config"), "dsh-anywhere", "connector.json");
}

export function parseConfig(value: unknown, environment: ConnectorEnvironment = process.env): ConnectorConfig {
  if (typeof value !== "object" || value === null || Array.isArray(value)) {
    throw new ConfigError("config must be a JSON object");
  }
  const raw = value as Record<string, unknown>;
  const merged: Record<string, string | undefined> = {};
  for (const field of REQUIRED_FIELDS) {
    const candidate = environment[ENV_FIELDS[field]] ?? raw[field];
    merged[field] = typeof candidate === "string" ? candidate.trim() : undefined;
  }
  for (const field of REQUIRED_FIELDS) {
    if (merged[field] === undefined || merged[field] === "") {
      throw new ConfigError(`missing required config field: ${field}`);
    }
  }

  const relayURL = validateUrl("relayURL", merged.relayURL!, ["wss:", "ws:"], true);
  const bridgeBaseURL = validateUrl("bridgeBaseURL", merged.bridgeBaseURL!, ["http:", "https:"], false);
  return {
    relayURL,
    machineId: merged.machineId!,
    machineToken: merged.machineToken!,
    bridgeBaseURL: bridgeBaseURL.replace(/\/+$/, ""),
    bridgeToken: merged.bridgeToken!,
  };
}

export async function loadConfig(
  path: string,
  environment: ConnectorEnvironment = process.env,
): Promise<ConnectorConfig> {
  let value: unknown;
  try {
    value = JSON.parse(await readFile(path, "utf8"));
  } catch (error) {
    if (error instanceof SyntaxError) throw new ConfigError(`invalid JSON in config: ${path}`);
    throw new ConfigError(`unable to read config: ${path}`);
  }
  return parseConfig(value, environment);
}

export function redactSecrets(value: string, config?: Pick<ConnectorConfig, "machineToken" | "bridgeToken">): string {
  let redacted = value;
  for (const secret of [config?.machineToken, config?.bridgeToken]) {
    if (secret !== undefined && secret.length > 0) redacted = redacted.split(secret).join("[REDACTED]");
  }
  return redacted
    .replace(/(authorization\s*[:=]\s*bearer\s+)[^\s,;]+/gi, "$1[REDACTED]")
    .replace(/(token\s*[:=]\s*)[^\s,;]+/gi, "$1[REDACTED]");
}

export class ConfigError extends Error {
  override name = "ConfigError";
}

function validateUrl(
  field: string,
  value: string,
  protocols: readonly string[],
  relay: boolean,
): string {
  let url: URL;
  try {
    url = new URL(value);
  } catch {
    throw new ConfigError(`${field} must be an absolute URL`);
  }
  if (!protocols.includes(url.protocol)) {
    throw new ConfigError(`${field} must use ${protocols.join(" or ")}`);
  }
  if (url.username !== "" || url.password !== "") {
    throw new ConfigError(`${field} must not contain credentials`);
  }
  if (relay && url.protocol === "ws:" && !isLoopback(url.hostname)) {
    throw new ConfigError("relayURL must use wss outside localhost");
  }
  return url.toString();
}

function isLoopback(hostname: string): boolean {
  return hostname === "localhost" || hostname === "127.0.0.1" || hostname === "::1";
}
