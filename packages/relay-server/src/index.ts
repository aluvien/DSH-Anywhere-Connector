import { createRelayServer } from "./server.js";
import { readFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

export { createRelayServer } from "./server.js";
export { Registry } from "./registry.js";
export type { RelayServerOptions, RunningRelayServer } from "./server.js";
export type { RelayPrincipal, MachineRegistration, DevicePairing } from "./registry.js";

const isEntrypoint = process.argv[1] !== undefined && import.meta.url === pathToFileURL(process.argv[1]).href;

if (isEntrypoint) {
  const bootstrapToken = process.env.DSH_RELAY_BOOTSTRAP_TOKEN;
  if (bootstrapToken === undefined || bootstrapToken.trim().length === 0) {
    throw new Error("DSH_RELAY_BOOTSTRAP_TOKEN is required");
  }

  const parsedPort = process.env.PORT === undefined ? undefined : Number.parseInt(process.env.PORT, 10);
  if (parsedPort !== undefined && (!Number.isInteger(parsedPort) || parsedPort < 1 || parsedPort > 65_535)) {
    throw new Error("PORT must be a valid TCP port");
  }

  const publicBaseURL = process.env.DSH_RELAY_PUBLIC_URL?.trim();
  const publicInstallSourceURL = process.env.DSH_RELAY_INSTALL_SOURCE_URL?.trim();
  const publicInstallScriptPath = process.env.DSH_RELAY_INSTALL_SCRIPT?.trim();
  const publicInstallerConfigured = publicBaseURL !== undefined && publicBaseURL !== "" &&
    publicInstallSourceURL !== undefined && publicInstallSourceURL !== "";
  const publicInstallScript = !publicInstallerConfigured || publicInstallScriptPath === undefined || publicInstallScriptPath === ""
    ? undefined : readFileSync(publicInstallScriptPath, "utf8");

  const relay = await createRelayServer({
    bootstrapToken,
    registryPath: process.env.DSH_RELAY_REGISTRY_PATH ?? "./dsh-anywhere-relay.json",
    ...(parsedPort === undefined ? {} : { port: parsedPort }),
    ...(process.env.HOST === undefined ? {} : { host: process.env.HOST }),
    ...(process.env.DSH_RELAY_TRUSTED_PROXIES === undefined ? {} : {
      trustedProxyAddresses: process.env.DSH_RELAY_TRUSTED_PROXIES.split(",").map((value) => value.trim()).filter(Boolean),
    }),
    ...(publicBaseURL === undefined || publicBaseURL === "" ? {} : { publicBaseURL }),
    ...(publicInstallSourceURL === undefined || publicInstallSourceURL === "" ? {} : { publicInstallSourceURL }),
    ...(publicInstallScript === undefined ? {} : { publicInstallScript }),
  });
  console.log(`DSH Anywhere Relay listening at ${relay.url}`);
}
