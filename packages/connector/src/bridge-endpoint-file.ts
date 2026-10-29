import { open } from "node:fs/promises";

/** Discovery is only allowed on loopback. It never supplies credentials. A
 * missing descriptor retains CLI compatibility; a corrupt one fails closed. */
export function endpointFileResolver(filePath: string, fallback: string): () => Promise<string> {
  return async () => {
    const configured = new URL(fallback);
    if (!["127.0.0.1", "localhost", "[::1]"].includes(configured.hostname)) return fallback;
    let file;
    try {
      file = await open(filePath, "r");
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code === "ENOENT") return fallback;
      throw new Error("Cannot read bridge endpoint descriptor");
    }
    let value: unknown;
    try {
      if (!(await file.stat()).isFile()) throw new Error("Not a file");
      const buffer = Buffer.alloc(4097);
      const { bytesRead } = await file.read(buffer, 0, buffer.length, 0);
      if (bytesRead > 4096) throw new Error("Descriptor too large");
      value = JSON.parse(buffer.subarray(0, bytesRead).toString("utf8"));
    } catch {
      throw new Error("Invalid bridge endpoint descriptor");
    } finally {
      await file.close();
    }
    if (typeof value !== "object" || value === null || Array.isArray(value)) {
      throw new Error("Invalid bridge endpoint descriptor");
    }
    const { version, origin, port, routePrefix } = value as Record<string, unknown>;
    if (version !== 1 || typeof port !== "number" || !Number.isInteger(port) || port < 1 || port > 65535
        || typeof origin !== "string"
        || !["http:", "https:"].some(protocol => ["127.0.0.1", "localhost", "[::1]"]
          .some(host => origin === `${protocol}//${host}:${port}`))) {
      throw new Error("Invalid bridge endpoint descriptor origin");
    }
    const prefix = routePrefix ?? configured.pathname.replace(/\/+$/, "");
    if (typeof prefix !== "string" || !/^\/[a-zA-Z0-9/_-]+$/.test(prefix)) {
      throw new Error("Invalid bridge endpoint descriptor route");
    }
    return `${origin}${prefix}`;
  };
}
