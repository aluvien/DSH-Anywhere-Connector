import { ConfigurationDiscoverySchema, ConfigurationModelsSchema, ConfigurationInvalidatedSchema, ConfigurationReadSchema, ConfigurationResultSchema, ConfigurationUpdateSchema, ConfigurationUpdatedSchema, SettingsSnapshotSchema } from '@dsh-anywhere/protocol'
import { HttpError } from './http.js'

type Invoke = (namespace: string, method: string, args: Record<string, unknown>) => Promise<unknown>
const object = (value: unknown): Record<string, unknown> => value !== null && typeof value === 'object' && !Array.isArray(value) ? value as Record<string, unknown> : {}

export async function readConfiguration(input: unknown, invoke: Invoke) {
  const request = ConfigurationReadSchema.parse(input)
  try {
    let value
    switch (request.section) {
      case 'settings': value = await invoke('settings', 'describe', {}); break
      case 'plugins': value = await invoke('pluginInventory', 'list', {}); break
      case 'credentials': {
        value = await invoke('credentials', 'describe', { refs: request.refs })
        const keys = Object.keys(object(value)), refs = new Set(request.refs)
        if (keys.length !== refs.size || keys.some((key) => !refs.has(key))) throw new Error('Credential reference mismatch')
        break
      }
      case 'providers': {
        const [registered, configurable] = await Promise.allSettled([invoke('llm', 'listProviders', {}), invoke('llm', 'listConfigurableProviders', {})])
        if (registered.status === 'rejected') throw registered.reason
        if (configurable.status === 'rejected') throw configurable.reason
        value = { registered: registered.value, configurable: configurable.value }; break
      }
    }
    return ConfigurationResultSchema.parse({ section: request.section, value })
  } catch (error) {
    const code = object(error).code
    if (['gateway/namespace-not-found', 'gateway/method-not-found', 'method-not-found'].includes(String(code))) throw new HttpError(501, '当前 Harness 尚未提供此配置能力，请更新电脑端')
    // These surfaces may touch credentials. Do not echo arbitrary adapter
    // exceptions or malformed payloads through protocol errors or logs.
    throw new HttpError(502, '电脑端未能提供有效的脱敏配置，请检查 Harness 状态')
  }
}

/** The Host remains the writer and performs the final CAS. A read-only
 * preflight prevents replacing a container whose old secrets were redacted. */
export async function updateConfiguration(input: unknown, requestId: string, invoke: Invoke) {
  const request = ConfigurationUpdateSchema.parse(input)
  if (request.kind === 'settings') {
    const snapshot = SettingsSnapshotSchema.parse(await invoke('settings', 'describe', {}))
    const current = snapshot.namespaces.find((item) => item.ns === request.ns)
    if (!snapshot.writable) throw new HttpError(403, '此电脑的配置来源只读')
    if (current === undefined) throw new HttpError(404, '配置项目已不存在，请刷新')
    if (current.revision !== request.expectedRevision) throw new HttpError(409, '配置已在其他端更新；请读取最新版本并合并，你的修改已保留')
    for (const op of request.ops) {
      if (op.op !== 'set') continue
      if (current.secrets.some((secret) => secret.set && secret.path.length > op.path.length && op.path.every((key, index) => secret.path[index] === key))) {
        throw new HttpError(400, '此修改会覆盖包含隐藏密钥的配置，请逐字段编辑；含密钥的数组需在电脑端编辑')
      }
    }
    const namespace = await invoke('settings', 'mutate', { ns: request.ns, ops: request.ops, expectedRevision: request.expectedRevision })
    const receipt = ConfigurationUpdatedSchema.parse({ kind: 'settings', requestId, namespace })
    if (receipt.kind !== 'settings' || receipt.namespace.ns !== request.ns || receipt.namespace.revision < request.expectedRevision) throw new Error('Invalid native settings acknowledgement')
    return receipt
  }
  const before = object(await invoke('credentials', 'describe', { refs: [request.ref] }))[request.ref]
  if (object(before).writable !== true) throw new HttpError(403, '此凭据的当前来源只读，请在电脑端处理')
  const result = await invoke('credentials', request.action, request.action === 'set' ? { ref: request.ref, value: request.value } : { ref: request.ref })
  if (result !== undefined && result !== null) throw new Error('Invalid native credential acknowledgement')
  return ConfigurationUpdatedSchema.parse({ kind: 'credential', requestId, ref: request.ref })
}

export function configurationFailure(error: unknown): HttpError {
  if (error instanceof HttpError) return error
  const code = object(error).code
  if (code === 'settings/conflict') return new HttpError(409, '配置已在其他端更新；请读取最新版本并合并，你的修改已保留')
  if (code === 'settings/rejected' || code === 'credential/rejected' || code === 'gateway/bad-request') return new HttpError(400, 'Harness 拒绝保存，请检查字段格式、凭据来源和写入权限')
  if (['gateway/namespace-not-found', 'gateway/method-not-found', 'method-not-found'].includes(String(code))) return new HttpError(501, '当前 Harness 尚未提供此配置能力，请更新电脑端')
  return new HttpError(503, '保存结果尚未确认，请保留原请求，检查电脑状态后重试', 'unknown')
}

/** This probes a Native-owned adapter. Neither overrides nor failures are
 * replayable configuration state; an adapter may include its key in errors. */
export async function discoverConfigurationModels(input: unknown, invoke: Invoke) {
  const request = ConfigurationDiscoverySchema.parse(input)
  try {
    const models = await invoke('llm', 'discoverModels', request)
    return ConfigurationModelsSchema.parse({ settingsNs: request.settingsNs, models })
  } catch (error) {
    const code = object(error).code, cause = object(object(error).cause).code
    if (code === 'llm/model-discovery-rejected' && (cause === 'NO_DISCOVERY' || cause === 'DISCOVERY_UNSUPPORTED')) throw new HttpError(501, '此服务暂未提供可读取的模型目录，请在配置中手动添加模型')
    if (code === 'llm/model-discovery-rejected' && cause === 'INVALID_DISCOVERY') throw new HttpError(400, '模型发现需要提供方或服务地址，请补齐配置')
    if (['gateway/namespace-not-found', 'gateway/method-not-found', 'method-not-found'].includes(String(code))) throw new HttpError(501, '当前 Harness 尚未提供模型发现能力，请更新电脑端')
    throw new HttpError(502, '模型发现未成功，请检查电脑端服务地址、协议与凭据')
  }
}

export function observeConfigurationChanges(on: (event: string, listener: (...args: unknown[]) => void) => void,
  publish: (event: { type: 'configuration.invalidated'; payload: ReturnType<typeof ConfigurationInvalidatedSchema.parse> }) => void) {
  const send = (payload: unknown) => {
    const parsed = ConfigurationInvalidatedSchema.safeParse(payload)
    if (parsed.success) publish({ type: 'configuration.invalidated', payload: parsed.data })
  }
  // Never pass settings next/prev or a credential record to the wire.
  for (const event of ['settings/document-updated', 'settings/updated']) on(event, (ns) => send({ section: 'settings', ns }))
  on('credentials/reference-updated', (ref) => send({ section: 'credentials', ref }))
  on('credentials/record-updated', () => send({ section: 'credentials' }))
  on('llm/adapters-updated', () => send({ section: 'providers' }))
  for (const event of ['internal/plugin', 'internal/status']) on(event, () => send({ section: 'plugins' }))
}
