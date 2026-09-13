import { createHash, randomBytes, randomInt, randomUUID, timingSafeEqual } from "node:crypto";
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

/** A device as its owner may see it. Only token hashes are ever stored. */
export interface DeviceSummary {
  readonly deviceId: string;
  readonly name: string;
  readonly createdAt: number;
}

/** A freshly minted single-use pairing code and when it stops working. */
export interface IssuedPairingCode {
  readonly code: string;
  readonly expiresAt: number;
}

interface PairingCodeRecord {
  readonly machineId: string;
  readonly expiresAt: number;
}

const PAIRING_CODE_TTL_MS = 10 * 60_000;
const PAIRING_CODE_LENGTH = 8;
/** No 0/O/1/I/L: the code is read off a screen and typed by a human. */
const PAIRING_CODE_ALPHABET = "ABCDEFGHJKMNPQRSTUVWXYZ23456789";

function newPairingCode(): string {
  let code = "";
  for (let index = 0; index < PAIRING_CODE_LENGTH; index += 1) {
    code += PAIRING_CODE_ALPHABET[randomInt(PAIRING_CODE_ALPHABET.length)];
  }
  return code;
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
  /** Single-use pairing codes, held in memory only. See issuePairingCode. */
  private readonly pairingCodes = new Map<string, PairingCodeRecord>();

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
    return await this.registerDevice(machineId, machine.name, name);
  }

  /**
   * Mints a short-lived, single-use pairing code for one machine.
   *
   * Codes are deliberately **not persisted**: they live for minutes and the
   * owner can always mint another, so surviving a restart is not worth a
   * persisted-schema change. Only the hash is held in memory, so a leaked
   * registry dump would not reveal an unused code either.
   */
  public issuePairingCode(machineId: string, now = Date.now(), ttlMs = PAIRING_CODE_TTL_MS): IssuedPairingCode | undefined {
    if (this.state.machines[machineId] === undefined) return undefined;
    this.sweepPairingCodes(now);
    const code = newPairingCode();
    const expiresAt = now + ttlMs;
    this.pairingCodes.set(hashSecret(code), { machineId, expiresAt });
    return { code, expiresAt };
  }

  /**
   * Redeems a pairing code. The code is bound to one machine and consumed on
   * use, so a leaked code cannot be replayed or redirected at another machine.
   */
  public async pairDeviceWithCode(machineId: string, code: string, name: string,
                                  now = Date.now()): Promise<DevicePairing | undefined> {
    this.sweepPairingCodes(now);
    const key = hashSecret(code.trim().toUpperCase());
    const record = this.pairingCodes.get(key);
    if (record === undefined || record.machineId !== machineId) return undefined;
    const machine = this.state.machines[machineId];
    if (machine === undefined) return undefined;
    // Consume before creating the device: a second attempt with the same code
    // must fail even if device creation were to throw.
    this.pairingCodes.delete(key);
    return await this.registerDevice(machineId, machine.name, name);
  }

  private async registerDevice(machineId: string, machineName: string, name: string): Promise<DevicePairing> {
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
    return { deviceId, deviceToken, machineName };
  }

  private sweepPairingCodes(now: number): void {
    for (const [key, record] of this.pairingCodes) {
      if (now >= record.expiresAt) this.pairingCodes.delete(key);
    }
  }

  /** Devices paired to one machine, oldest first. Never exposes token hashes. */
  public listDevices(machineId: string): readonly DeviceSummary[] {
    return Object.values(this.state.devices)
      .filter((device) => device.machineId === machineId)
      .sort((left, right) => left.createdAt - right.createdAt)
      .map((device) => ({ deviceId: device.id, name: device.name, createdAt: device.createdAt }));
  }

  /**
   * Removes one device. Returns false when the id is unknown or belongs to a
   * different machine, so a caller can never revoke across a machine boundary.
   */
  public async revokeDevice(machineId: string, deviceId: string): Promise<boolean> {
    const device = this.state.devices[deviceId];
    if (device === undefined || device.machineId !== machineId) return false;
    delete this.state.devices[deviceId];
    await this.persist();
    return true;
  }

  public authenticate(token: string): RelayPrincipal | undefined {    for (const machine of Object.values(this.state.machines)) {
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
