import { describe, expect, it, vi } from 'vitest'
import { observeConfigurationChanges, discoverConfigurationModels, readConfiguration, updateConfiguration, configurationFailure } from './configuration.js'

const namespace = { ns: 'llm-test', revision: 4, schema: { type: 'object' }, value: { models: [{ id: 'm', opaque: { keep: true } }], baseURL: 'https://test.invalid' },
  user: { baseURL: 'https://test.invalid' }, base: { models: [{ id: 'm' }] }, secrets: [{ path: ['apiKey'], set: true }], applies: 'live' }
const snapshot = { writable: true, hasDocument: true, namespaces: [namespace] }
describe('native computer configuration', () => {
  it('reads only the redacted Native controller and preserves schema, hidden-slot metadata and unknown model fields', async () => {
    const invoke = vi.fn(async () => snapshot)
    expect(await readConfiguration({ section: 'settings' }, invoke)).toEqual({ section: 'settings', value: snapshot })
    expect(invoke).toHaveBeenCalledWith('settings', 'describe', {})
    const plugins = { entries: [{ entryId: 'e', moduleName: 'plugin', enabled: true, fiberPhase: 'loading' }], agentPresets: [{ id: 'standard', trust: 'system', isDefault: true,
      rows: [{ entryId: null, moduleName: 'conditional', enabled: 'conditional', condition: 'platform === darwin', fiberPhase: null }] }] }
    expect(await readConfiguration({ section: 'plugins' }, async () => plugins)).toEqual({ section: 'plugins', value: plugins })
  })
  it('publishes only identifiers for raw/resolved settings, credentials, adapters and plugin lifecycle changes', () => {
    const handlers = new Map<string, (...args: unknown[]) => void>(), publish = vi.fn()
    observeConfigurationChanges((event, listener) => { handlers.set(event, listener) }, publish)
    handlers.get('settings/updated')!('llm-test', { apiKey: 'secret' }, { apiKey: 'old-secret' }, 'provider')
    handlers.get('settings/document-updated')!('llm-test', 8)
    handlers.get('credentials/reference-updated')!('TEST_KEY')
    handlers.get('credentials/record-updated')!({ key: 'private-record', value: 'secret' })
    handlers.get('llm/adapters-updated')!()
    handlers.get('internal/status')!({ config: { apiKey: 'secret' } }, 'old-state')
    expect(publish.mock.calls.map(([event]) => event)).toEqual([
      { type: 'configuration.invalidated', payload: { section: 'settings', ns: 'llm-test' } },
      { type: 'configuration.invalidated', payload: { section: 'settings', ns: 'llm-test' } },
      { type: 'configuration.invalidated', payload: { section: 'credentials', ref: 'TEST_KEY' } },
      { type: 'configuration.invalidated', payload: { section: 'credentials' } },
      { type: 'configuration.invalidated', payload: { section: 'providers' } },
      { type: 'configuration.invalidated', payload: { section: 'plugins' } },
    ])
    handlers.get('credentials/reference-updated')!('bad-ref')
    handlers.get('settings/document-updated')!({ apiKey: 'secret' }, 9)
    expect(publish).toHaveBeenCalledTimes(6)
  })
  it('probes the exact Native discovery contract without returning overrides or adapter failures', async () => {
    const input = { settingsNs: 'llm-test', request: { provider: 'p', baseURL: 'https://new.invalid', api: 'openai', apiKey: 'temporary-never-echo' } }
    const models = [{ id: 'new', name: 'New model', contextWindow: 128000, maxTokens: 4096 }]
    const invoke = vi.fn(async () => models)
    expect(await discoverConfigurationModels(input, invoke)).toEqual({ settingsNs: input.settingsNs, models })
    expect(invoke).toHaveBeenCalledExactlyOnceWith('llm', 'discoverModels', input)
    await expect(discoverConfigurationModels(input, async () => { throw new Error(input.request.apiKey) })).rejects.toMatchObject({ status: 502, message: expect.not.stringContaining(input.request.apiKey) })
    await expect(discoverConfigurationModels(input, async () => { throw { code: 'gateway/method-not-found' } })).rejects.toMatchObject({ status: 501 })
    for (const code of ['NO_DISCOVERY', 'DISCOVERY_UNSUPPORTED']) await expect(discoverConfigurationModels(input, async () => { throw { code: 'llm/model-discovery-rejected', cause: { code, message: input.request.apiKey } } })).rejects.toMatchObject({ status: 501, message: expect.not.stringContaining(input.request.apiKey) })
    await expect(discoverConfigurationModels(input, async () => { throw { code: 'llm/model-discovery-rejected', cause: { code: 'INVALID_DISCOVERY' } } })).rejects.toMatchObject({ status: 400 })
    await expect(discoverConfigurationModels(input, async () => [{ id: 'bad', apiKey: input.request.apiKey }])).rejects.toMatchObject({ status: 502 })
  })
  it('passes exact Native CAS operations and refuses stale, readonly or secret-container replacement before writing', async () => {
    const invoke = vi.fn(async (_namespace: string, method: string) => method === 'describe' ? snapshot : { ...namespace, revision: 5 })
    const request = { kind: 'settings', ns: namespace.ns, expectedRevision: 4, ops: [{ op: 'set', path: ['baseURL'], value: 'https://new.invalid' }] }
    expect(await updateConfiguration(request, 'r', invoke)).toMatchObject({ kind: 'settings', requestId: 'r', namespace: { revision: 5 } })
    expect(invoke).toHaveBeenLastCalledWith('settings', 'mutate', { ns: namespace.ns, expectedRevision: 4, ops: request.ops })
    invoke.mockClear()
    await expect(updateConfiguration({ ...request, expectedRevision: 3 }, 'r', invoke)).rejects.toMatchObject({ status: 409 })
    expect(invoke).toHaveBeenCalledTimes(1)
    await expect(updateConfiguration({ ...request, ops: [{ op: 'set', path: [], value: {} }] }, 'r', invoke)).rejects.toMatchObject({ status: 400 })
    await expect(updateConfiguration(request, 'r', async () => ({ ...snapshot, writable: false }))).rejects.toMatchObject({ status: 403 })
  })
  it('keeps credential writes one-way and returns a real acknowledgement without a secret or a second fallible read', async () => {
    const invoke = vi.fn(async (_namespace: string, method: string) => method === 'describe' ? { TEST_KEY: { configured: true, writable: true, source: 'file' } } : undefined)
    const result = await updateConfiguration({ kind: 'credential', action: 'set', ref: 'TEST_KEY', value: 'secret-never-echo' }, 'r', invoke)
    expect(result).toEqual({ kind: 'credential', requestId: 'r', ref: 'TEST_KEY' })
    expect(invoke).toHaveBeenLastCalledWith('credentials', 'set', { ref: 'TEST_KEY', value: 'secret-never-echo' })
    expect(invoke).toHaveBeenCalledTimes(2)
    expect(JSON.stringify(result)).not.toContain('secret-never-echo')
    await expect(updateConfiguration({ kind: 'credential', action: 'unset', ref: 'TEST_KEY' }, 'r', async () => ({ TEST_KEY: { configured: true, writable: false, source: 'environment' } }))).rejects.toMatchObject({ status: 403 })
  })
  it('contains adapter exceptions and rejects incomplete native mutation acknowledgements', async () => {
    await expect(readConfiguration({ section: 'providers' }, async () => { throw new Error('secret-never-echo') })).rejects.toMatchObject({ status: 502 })
    expect(configurationFailure(new Error('secret-never-echo')).message).not.toContain('secret-never-echo')
    expect(configurationFailure({ code: 'settings/conflict' }).status).toBe(409)
    await expect(readConfiguration({ section: 'settings' }, async () => { throw { code: 'gateway/namespace-not-found' } })).rejects.toMatchObject({ status: 501 })
    await expect(updateConfiguration({ kind: 'settings', ns: 'llm-test', expectedRevision: 4, ops: [{ op: 'unset', path: ['baseURL'] }] }, 'r', async (_namespace, method) => method === 'describe' ? snapshot : { ...namespace, ns: 'other' })).rejects.toThrow('acknowledgement')
  })
})
