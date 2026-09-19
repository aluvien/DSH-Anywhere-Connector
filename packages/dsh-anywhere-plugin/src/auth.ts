import { randomBytes, randomInt, timingSafeEqual } from 'node:crypto'

export interface PairedDevice {
  readonly id: string
  readonly name: string
  readonly token: string
  readonly pairedAt: number
}

export interface PairingSnapshot {
  readonly code: string
  readonly expiresAt: number
}

export interface TrustedDeviceRegistration {
  readonly id: string
  readonly name: string
  readonly token: string
}

export class PairingAuthority {
  private readonly devicesByToken = new Map<string, PairedDevice>()
  private code = ''
  private expiresAt = 0

  constructor(
    private readonly ttlMs = 10 * 60_000,
    private readonly onRotate?: (snapshot: PairingSnapshot) => void,
  ) {
    this.rotate()
  }

  snapshot(): PairingSnapshot {
    if (Date.now() >= this.expiresAt) this.rotate()
    return { code: this.code, expiresAt: this.expiresAt }
  }

  claim(code: string, name: string): PairedDevice | undefined {
    const snapshot = this.snapshot()
    if (!safeEqual(code, snapshot.code) || name.trim().length === 0) return undefined
    const device: PairedDevice = {
      id: `device_${randomBytes(12).toString('base64url')}`,
      name: name.trim().slice(0, 80),
      token: randomBytes(32).toString('base64url'),
      pairedAt: Date.now(),
    }
    this.devicesByToken.set(device.token, device)
    this.rotate()
    return device
  }

  registerTrustedDevice(registration: TrustedDeviceRegistration): PairedDevice {
    for (const [token, device] of this.devicesByToken) {
      if (device.id === registration.id || token === registration.token) {
        this.devicesByToken.delete(token)
      }
    }
    const device: PairedDevice = {
      id: registration.id,
      name: registration.name,
      token: registration.token,
      pairedAt: Date.now(),
    }
    this.devicesByToken.set(device.token, device)
    return device
  }

  authenticate(header: string | undefined): PairedDevice | undefined {
    if (header === undefined || !header.startsWith('Bearer ')) return undefined
    const token = header.slice('Bearer '.length)
    for (const device of this.devicesByToken.values()) {
      if (safeEqual(token, device.token)) return device
    }
    return undefined
  }

  hasDevice(deviceId: string): boolean {
    for (const device of this.devicesByToken.values()) {
      if (device.id === deviceId) return true
    }
    return false
  }

  revoke(deviceId: string): boolean {
    for (const [token, device] of this.devicesByToken) {
      if (device.id !== deviceId) continue
      this.devicesByToken.delete(token)
      return true
    }
    return false
  }

  private rotate(): void {
    this.code = String(randomInt(0, 1_000_000)).padStart(6, '0')
    this.expiresAt = Date.now() + this.ttlMs
    this.onRotate?.({ code: this.code, expiresAt: this.expiresAt })
  }
}

function safeEqual(left: string, right: string): boolean {
  const a = Buffer.from(left)
  const b = Buffer.from(right)
  return a.length === b.length && timingSafeEqual(a, b)
}
