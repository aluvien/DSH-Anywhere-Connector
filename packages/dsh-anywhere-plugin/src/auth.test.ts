import { describe, expect, it } from 'vitest'
import { PairingAuthority } from './auth.js'

describe('PairingAuthority', () => {
  it('claims a one-time code and authenticates its bearer token', () => {
    const authority = new PairingAuthority()
    const code = authority.snapshot().code
    const device = authority.claim(code, 'iPhone')
    expect(device).toBeDefined()
    expect(authority.authenticate(`Bearer ${device!.token}`)?.id).toBe(device!.id)
    expect(authority.claim(code, 'second phone')).toBeUndefined()
  })

  it('rejects malformed authorization', () => {
    const authority = new PairingAuthority()
    expect(authority.authenticate(undefined)).toBeUndefined()
    expect(authority.authenticate('Basic abc')).toBeUndefined()
  })

  it('authenticates a stable trusted device with a timing-safe bearer token', () => {
    const authority = new PairingAuthority()
    const trusted = authority.registerTrustedDevice({
      id: 'dsh-anywhere-connector',
      name: 'DSH Anywhere Connector',
      token: 'connector-token-that-is-at-least-32-characters',
    })

    expect(authority.authenticate(`Bearer ${trusted.token}`)).toEqual(trusted)
    expect(authority.authenticate(`Bearer ${trusted.token.slice(0, -1)}x`)).toBeUndefined()
  })

  it('can register the trusted device again after revocation', () => {
    const authority = new PairingAuthority()
    const registration = {
      id: 'dsh-anywhere-connector',
      name: 'DSH Anywhere Connector',
      token: 'connector-token-that-is-at-least-32-characters',
    }
    authority.registerTrustedDevice(registration)
    expect(authority.revoke(registration.id)).toBe(true)
    expect(authority.authenticate(`Bearer ${registration.token}`)).toBeUndefined()
    expect(authority.registerTrustedDevice(registration).id).toBe(registration.id)
    expect(authority.authenticate(`Bearer ${registration.token}`)?.id).toBe(registration.id)
  })
})
