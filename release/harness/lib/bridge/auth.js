import { randomBytes, randomInt, timingSafeEqual } from 'node:crypto';
export class PairingAuthority {
    ttlMs;
    onRotate;
    devicesByToken = new Map();
    code = '';
    expiresAt = 0;
    constructor(ttlMs = 10 * 60_000, onRotate) {
        this.ttlMs = ttlMs;
        this.onRotate = onRotate;
        this.rotate();
    }
    snapshot() {
        if (Date.now() >= this.expiresAt)
            this.rotate();
        return { code: this.code, expiresAt: this.expiresAt };
    }
    claim(code, name) {
        const snapshot = this.snapshot();
        if (!safeEqual(code, snapshot.code) || name.trim().length === 0)
            return undefined;
        const device = {
            id: `device_${randomBytes(12).toString('base64url')}`,
            name: name.trim().slice(0, 80),
            token: randomBytes(32).toString('base64url'),
            pairedAt: Date.now(),
        };
        this.devicesByToken.set(device.token, device);
        this.rotate();
        return device;
    }
    registerTrustedDevice(registration) {
        for (const [token, device] of this.devicesByToken) {
            if (device.id === registration.id || token === registration.token) {
                this.devicesByToken.delete(token);
            }
        }
        const device = {
            id: registration.id,
            name: registration.name,
            token: registration.token,
            pairedAt: Date.now(),
        };
        this.devicesByToken.set(device.token, device);
        return device;
    }
    authenticate(header) {
        if (header === undefined || !header.startsWith('Bearer '))
            return undefined;
        const token = header.slice('Bearer '.length);
        for (const device of this.devicesByToken.values()) {
            if (safeEqual(token, device.token))
                return device;
        }
        return undefined;
    }
    hasDevice(deviceId) {
        for (const device of this.devicesByToken.values()) {
            if (device.id === deviceId)
                return true;
        }
        return false;
    }
    revoke(deviceId) {
        for (const [token, device] of this.devicesByToken) {
            if (device.id !== deviceId)
                continue;
            this.devicesByToken.delete(token);
            return true;
        }
        return false;
    }
    rotate() {
        this.code = String(randomInt(0, 1_000_000)).padStart(6, '0');
        this.expiresAt = Date.now() + this.ttlMs;
        this.onRotate?.({ code: this.code, expiresAt: this.expiresAt });
    }
}
function safeEqual(left, right) {
    const a = Buffer.from(left);
    const b = Buffer.from(right);
    return a.length === b.length && timingSafeEqual(a, b);
}
