import { createHash, randomBytes, randomUUID, timingSafeEqual } from "node:crypto";
import { chmod, mkdir, readFile, rename, writeFile } from "node:fs/promises";
import { dirname } from "node:path";

export interface MachineRecord {
  readonly id: string;
  readonly name: string;
  readonly tokenHash: string;
  readonly pairingSecretHash: string;
  readonly createdAt: number;
}

export interface DeviceRecord {
  readonly id: string;
  readonly machineId: string;
  readonly name: string;
  readonly tokenHash: string;
  readonly createdAt: number;
}

interface RegistryFile {
  readonly version: 1;
  readonly machines: Record<string, MachineRecord>;
  readonly devices: Record<string, DeviceRecord>;
}

export type RelayPrincipal =
  | { readonly role: "machine"; readonly machineId: string }
  | { readonly role: "device"; readonly machineId: string; readonly deviceId: string };

export interface MachineRegistration {
  readonly machineId: string;
  readonly machineToken: string;
  readonly pairingSecret: string;
}

export interface DevicePairing {
  readonly deviceId: string;
  readonly deviceToken: string;
  readonly machineName: string;
}

const emptyRegistry = (): RegistryFile => ({ version: 1, machines: {}, devices: {} });

export const hashSecret = (value: string): string =>
  createHash("sha256").update(value, "utf8").digest("hex");

const secretEquals = (expectedHash: string, supplied: string): boolean => {
  const left = Buffer.from(expectedHash, "hex");
  const right = Buffer.from(hashSecret(supplied), "hex");
  return left.length === right.length && timingSafeEqual(left, right);
};

const newSecret = (): string => randomBytes(32).toString("base64url");

/** A deliberately tiny JSON registry. Values returned from this class never contain plaintext credentials. */
export class Registry {
  private state: RegistryFile = emptyRegistry();
  private persistQueue: Promise<void> = Promise.resolve();

  public constructor(private readonly path: string) {}

  public async load(): Promise<void> {
    try {
      const raw = await readFile(this.path, "utf8");
      const parsed: unknown = JSON.parse(raw);
      if (!isRegistryFile(parsed)) throw new Error("invalid registry format");
      this.state = parsed;
    } catch (error: unknown) {
      if (isMissingFile(error)) {
        this.state = emptyRegistry();
        return;
      }
      throw new Error(`unable to load relay registry: ${error instanceof Error ? error.message : String(error)}`);
    }
  }

  public async registerMachine(name: string): Promise<MachineRegistration> {
    const machineId = `machine_${randomUUID()}`;
    const machineToken = newSecret();
    const pairingSecret = newSecret();
    this.state.machines[machineId] = {
      id: machineId,
      name,
      tokenHash: hashSecret(machineToken),
      pairingSecretHash: hashSecret(pairingSecret),
      createdAt: Date.now(),
    };
    await this.persist();
    return { machineId, machineToken, pairingSecret };
  }

  public async pairDevice(machineId: string, pairingSecret: string, name: string): Promise<DevicePairing | undefined> {
    const machine = this.state.machines[machineId];
    if (machine === undefined || !secretEquals(machine.pairingSecretHash, pairingSecret)) return undefined;
    const deviceId = `device_${randomUUID()}`;
    const deviceToken = newSecret();
    this.state.devices[deviceId] = {
      id: deviceId,
      machineId,
      name,
      tokenHash: hashSecret(deviceToken),
      createdAt: Date.now(),
    };
    await this.persist();
    return { deviceId, deviceToken, machineName: machine.name };
  }

  public authenticate(token: string): RelayPrincipal | undefined {
    for (const machine of Object.values(this.state.machines)) {
      if (secretEquals(machine.tokenHash, token)) return { role: "machine", machineId: machine.id };
    }
    for (const device of Object.values(this.state.devices)) {
      if (secretEquals(device.tokenHash, token)) {
        return { role: "device", machineId: device.machineId, deviceId: device.id };
      }
    }
    return undefined;
  }

  private persist(): Promise<void> {
    // Registration and pairing can arrive concurrently. Serialize atomic
    // renames so a later write cannot be lost by an earlier in-flight write.
    this.persistQueue = this.persistQueue.catch(() => undefined).then(async () => {
      await mkdir(dirname(this.path), { recursive: true });
      await chmod(dirname(this.path), 0o700);
      const temporaryPath = `${this.path}.${randomUUID()}.tmp`;
      await writeFile(temporaryPath, `${JSON.stringify(this.state, null, 2)}\n`, { encoding: "utf8", mode: 0o600 });
      await rename(temporaryPath, this.path);
    });
    return this.persistQueue;
  }
}

const isMissingFile = (value: unknown): value is NodeJS.ErrnoException =>
  typeof value === "object" && value !== null && "code" in value && value.code === "ENOENT";

const isRecord = (value: unknown): value is Record<string, unknown> => typeof value === "object" && value !== null && !Array.isArray(value);

const isMachine = (value: unknown): value is MachineRecord =>
  isRecord(value) && typeof value.id === "string" && typeof value.name === "string" &&
  typeof value.tokenHash === "string" && typeof value.pairingSecretHash === "string" && typeof value.createdAt === "number";

const isDevice = (value: unknown): value is DeviceRecord =>
  isRecord(value) && typeof value.id === "string" && typeof value.machineId === "string" && typeof value.name === "string" &&
  typeof value.tokenHash === "string" && typeof value.createdAt === "number";

const isRegistryFile = (value: unknown): value is RegistryFile => {
  if (!isRecord(value) || value.version !== 1 || !isRecord(value.machines) || !isRecord(value.devices)) return false;
  return Object.values(value.machines).every(isMachine) && Object.values(value.devices).every(isDevice);
};
