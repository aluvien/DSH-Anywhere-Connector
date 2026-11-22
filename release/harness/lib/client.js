window.__ModuleLoader__.load({ id: "dsh-anywhere", factory(require) {
const exports = {};
const { createElement: h, useEffect, useState } = require('react')

const stateLabels = {
  disabled: '尚未开启远程连接',
  external: '正在使用已安装的 Connector',
  registered: '已注册，连接尚未启动',
  connecting: '正在连接 Harness 和 Relay',
  connected: '远程连接已就绪',
}

async function callSetup(action, signal) {
  const response = await fetch(new URL('dsh-anywhere/v1/setup', document.baseURI), {
    method: action ? 'POST' : 'GET',
    headers: { 'x-dsh-anywhere-setup': '1', 'content-type': 'application/json' },
    body: action ? JSON.stringify({ action }) : undefined,
    cache: 'no-store',
    signal,
  })
  if (!response.ok) throw new Error('无法完成远程连接操作，请检查 Harness 与 Relay 后重试。')
  return response.json()
}

function RemoteSetupPanel() {
  const [state, setState] = useState(null)
  const [pairingCode, setPairingCode] = useState(null)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState('')

  useEffect(() => {
    const controller = new AbortController()
    let timer
    async function refresh() {
      try {
        const result = await callSetup(undefined, controller.signal)
        if (!controller.signal.aborted) setState(result.state)
      } catch {
        if (!controller.signal.aborted) setState(null)
      }
      if (!controller.signal.aborted) timer = setTimeout(refresh, 3_000)
    }
    void refresh()
    return () => { controller.abort(); clearTimeout(timer) }
  }, [])

  useEffect(() => {
    if (!pairingCode) return
    const timer = setTimeout(() => setPairingCode(null), Math.max(0, pairingCode.expiresAt - Date.now()))
    return () => clearTimeout(timer)
  }, [pairingCode])

  async function submit(action) {
    setBusy(true)
    setError('')
    if (action === 'pair') setPairingCode(null)
    try {
      const result = await callSetup(action)
      setState(result.state)
      if (result.qrImage) setPairingCode({ image: result.qrImage, expiresAt: result.expiresAt })
    } catch (error) {
      setError(error.message)
    } finally {
      setBusy(false)
    }
  }

  const canPair = state === 'external' || state === 'connected'
  const canEnable = state === 'disabled' || state === 'registered'
  return h('section', { 'aria-label': 'DSH Anywhere 远程连接' },
    h('h3', null, '远程连接'),
    h('p', { role: 'status' }, stateLabels[state] ?? '等待本机 Harness 提供连接状态'),
    canEnable && h('button', { type: 'button', disabled: busy, onClick: () => submit('enable') }, '开启远程连接'),
    canPair && h('button', { type: 'button', disabled: busy, onClick: () => submit('pair') },
      pairingCode ? '生成新配对码' : '显示配对码'),
    error && h('p', { role: 'alert' }, error),
    pairingCode && h('p', null, h('img', { src: pairingCode.image, alt: '用 DSH Anywhere 扫描此一次性配对码', width: 220, height: 220,
      style: { padding: 8, background: '#fff' } })),
  )
}

exports.inject = ['slots', 'locale']
exports.apply = ctx => {
  const name = 'plugins.bundle.config'
  ctx.effect(() => ctx.locale.register('dshAnywhereRemoteSetup', {
    en: { title: 'Remote access' }, zh: { title: '远程连接' },
  }), 'dsh-anywhere: remote setup locale')
  ctx.effect(() => ctx.slots.inject(name, () => ctx.slots.register({
    name, key: 'dsh-anywhere', locale: 'dshAnywhereRemoteSetup',
  }, RemoteSetupPanel)), 'dsh-anywhere: remote setup panel')
}

return exports;
} });
