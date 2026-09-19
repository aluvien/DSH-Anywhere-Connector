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
  /** A provisional pairing cannot authenticate after this deadline. The
   * marker bounds the Relay-side orphan window if the client dies before it
   * can persist its local pairing transaction. */
  provisionalUntil?: number;
  /** A persisted tombstone makes a failed final delete safe to retry. */
  revokedAt?: number;
}

interface RegistryFile {
  readonly version: 1;
  readonly machines: Record<string, MachineRecord>;
  readonly devices: Record<string, DeviceRecord>;
  /** Machine lease counters survive a Relay restart. A random process epoch
   * alone cannot tell the Bridge which of two delayed presence reports is
   * newer. */
  readonly machineLeaseGenerations?: Record<string, number>;
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
  readonly provisionalUntil?: number;
}

/** A device as its owner may see it. Only token hashes are ever stored. */
export interface DeviceSummary {
  readonly deviceId: string;
  readonly name: string;
  readonly createdAt: number;
}

export interface PairDeviceOptions {
  readonly provisional?: boolean;
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
/**
 * Relay-side bound for the crash window between returning a pairing token and
 * the phone durably committing its local profile. A client that never reaches
 * the activation phase therefore cannot leave an indefinitely usable device.
 */
export const PROVISIONAL_PAIRING_TTL_MS = 15 * 60_000;
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

const emptyRegistry = (): RegistryFile => ({
  version: 1,
  machines: {},
  devices: {},
  machineLeaseGenerations: {},
});

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
    if (this.state.machineLeaseGenerations === undefined) {
      this.state = { ...this.state, machineLeaseGenerations: {} };
    }
  }

  /** Allocate a machine connection lease that remains ordered across Relay
   * process restarts. Presence consumers can therefore fence an old random
   * relay epoch without guessing from wall-clock timestamps. */
  public async nextMachineLeaseGeneration(machineId: string): Promise<number> {
    if (this.state.machines[machineId] === undefined) throw new Error("unknown machine");
    const counters = this.state.machineLeaseGenerations ?? {};
    const next = (counters[machineId] ?? 0) + 1;
    counters[machineId] = next;
    this.state = { ...this.state, machineLeaseGenerations: counters };
    await this.persist();
    return next;
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

  public async pairDevice(machineId: string, pairingSecret: string, name: string,
                          options: PairDeviceOptions = {}): Promise<DevicePairing | undefined> {
    const machine = this.state.machines[machineId];
    if (machine === undefined || !secretEquals(machine.pairingSecretHash, pairingSecret)) return undefined;
    return await this.registerDevice(machineId, machine.name, name, options);
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
                                  now = Date.now(), options: PairDeviceOptions = {}): Promise<DevicePairing | undefined> {
    this.sweepPairingCodes(now);
    const key = hashSecret(code.trim().toUpperCase());
    const record = this.pairingCodes.get(key);
    if (record === undefined || record.machineId !== machineId) return undefined;
    const machine = this.state.machines[machineId];
    if (machine === undefined) return undefined;
    // Consume before creating the device: a second attempt with the same code
    // must fail even if device creation were to throw.
    this.pairingCodes.delete(key);
    return await this.registerDevice(machineId, machine.name, name, options);
  }

  private async registerDevice(machineId: string, machineName: string, name: string,
                               options: PairDeviceOptions = {}): Promise<DevicePairing> {
    const deviceId = `device_${randomUUID()}`;
    const deviceToken = newSecret();
    const provisionalUntil = options.provisional === true
      ? Date.now() + PROVISIONAL_PAIRING_TTL_MS : undefined;
    this.state.devices[deviceId] = {
      id: deviceId,
      machineId,
      name,
      tokenHash: hashSecret(deviceToken),
      createdAt: Date.now(),
      ...(provisionalUntil === undefined ? {} : { provisionalUntil }),
    };
    await this.persist();
    return {
      deviceId, deviceToken, machineName,
      ...(provisionalUntil === undefined ? {} : { provisionalUntil }),
    };
  }

  private sweepPairingCodes(now: number): void {
    for (const [key, record] of this.pairingCodes) {
      if (now >= record.expiresAt) this.pairingCodes.delete(key);
    }
  }

  /** Devices paired to one machine, oldest first. Never exposes token hashes. */
  public listDevices(machineId: string): readonly DeviceSummary[] {
    return Object.values(this.state.devices)
      .filter((device) => device.machineId === machineId && device.revokedAt === undefined &&
        device.provisionalUntil === undefined)
      .sort((left, right) => left.createdAt - right.createdAt)
      .map((device) => ({ deviceId: device.id, name: device.name, createdAt: device.createdAt }));
  }

  /** Removes expired provisional records so abandoned pair attempts cannot
   * accumulate indefinitely in the persistent registry. Authentication and
   * listing already reject them synchronously; this cleanup is best-effort
   * housekeeping performed by the Relay server. */
  public async sweepExpiredProvisionalDevices(now = Date.now()): Promise<void> {
    const expired = Object.values(this.state.devices)
      .filter((device) => device.revokedAt === undefined &&
        device.provisionalUntil !== undefined && now >= device.provisionalUntil)
      .map((device) => ({ machineId: device.machineId, deviceId: device.id }));
    for (const device of expired) {
      await this.revokeDevice(device.machineId, device.deviceId);
    }
  }

  /**
   * Completes the second phase of a provisional pairing. It is intentionally
   * idempotent: a retry after a successful activation returns true without
   * rewriting the record. Expired provisional records are no longer valid and
   * are removed before returning false.
   */
  public async activateDevice(machineId: string, deviceId: string): Promise<boolean> {
    const device = this.state.devices[deviceId];
    if (device === undefined || device.machineId !== machineId || device.revokedAt !== undefined) return false;
    if (device.provisionalUntil === undefined) return true;
    if (Date.now() >= device.provisionalUntil) {
      await this.revokeDevice(machineId, deviceId);
      return false;
    }
    const previousDeadline = device.provisionalUntil;
    delete device.provisionalUntil;
    try {
      await this.persist();
    } catch (error) {
      // Restore the provisional fence if the activation write did not reach
      // disk. The caller will fail closed and retry rather than assuming the
      // Relay and its registry disagree about lifecycle state.
      device.provisionalUntil = previousDeadline;
      throw error;
    }
    return true;
  }

  /**
   * Removes one device. Returns false when the id is unknown or belongs to a
   * different machine, so a caller can never revoke across a machine boundary.
   */
  public async revokeDevice(machineId: string, deviceId: string): Promise<boolean> {
    const device = this.state.devices[deviceId];
    if (device === undefined || device.machineId !== machineId) return false;
    // Persist a tombstone before removing the record. If either write fails,
    // the in-memory and (when the first write succeeded) on-disk record stays
    // non-authenticating, while a later DELETE can retry the unfinished step.
    if (device.revokedAt === undefined) {
      device.revokedAt = Date.now();
      await this.persist();
    }
    delete this.state.devices[deviceId];
    try {
      await this.persist();
    } catch (error) {
      // Keep the tombstone in memory so the token remains unusable and the
      // next revoke call can retry the final removal.
      this.state.devices[deviceId] = device;
      throw error;
    }
    return true;
  }

  public authenticate(token: string): RelayPrincipal | undefined {
    for (const machine of Object.values(this.state.machines)) {
      if (secretEquals(machine.tokenHash, token)) return { role: "machine", machineId: machine.id };
    }
    for (const device of Object.values(this.state.devices)) {
      if (device.revokedAt !== undefined) continue;
      if (device.provisionalUntil !== undefined && Date.now() >= device.provisionalUntil) continue;
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
  typeof value.tokenHash === "string" && typeof value.createdAt === "number" &&
  (value.provisionalUntil === undefined || typeof value.provisionalUntil === "number") &&
  (value.revokedAt === undefined || typeof value.revokedAt === "number");

const isRegistryFile = (value: unknown): value is RegistryFile => {
  if (!isRecord(value) || value.version !== 1 || !isRecord(value.machines) || !isRecord(value.devices)) return false;
  if (value.machineLeaseGenerations !== undefined &&
      (!isRecord(value.machineLeaseGenerations) ||
       !Object.values(value.machineLeaseGenerations).every((generation) =>
         typeof generation === "number" && Number.isSafeInteger(generation) && generation >= 0))) return false;
  return Object.values(value.machines).every(isMachine) && Object.values(value.devices).every(isDevice);
};
