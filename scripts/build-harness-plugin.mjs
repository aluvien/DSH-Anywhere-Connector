#!/usr/bin/env node
import { cp, mkdir, readFile, readdir, writeFile } from 'node:fs/promises'
import { dirname, posix, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

const root = fileURLToPath(new URL('..', import.meta.url))
const [outputArgument, version] = process.argv.slice(2)
if (!outputArgument || !/^\d+\.\d+\.\d+(?:-[\w.]+)?$/.test(version ?? '')) {
  throw new Error('Usage: node scripts/build-harness-plugin.mjs <new-output-directory> <version>')
}
const output = resolve(outputArgument)
await mkdir(output)

const dependencies = {
  '@dsh-anywhere/connector': 'lib/connector/index.js',
  '@dsh-anywhere/protocol': 'lib/protocol/index.js',
}
const sources = [
  ['packages/dsh-anywhere-plugin/lib', 'lib/bridge'],
  ['packages/connector/lib', 'lib/connector'],
  ['packages/protocol/dist', 'lib/protocol'],
]
for (const [source, directory] of sources) {
  for (const file of await readdir(resolve(root, source), { recursive: true })) {
    if (!file.endsWith('.js') || file.endsWith('.test.js')) continue
    const destination = posix.join(directory, file.replaceAll('\\', '/'))
    const input = await readFile(resolve(root, source, file), 'utf8')
    const rewritten = input.replace(/\bfrom (["'])(@dsh-anywhere\/(?:connector|protocol))\1/g,
      (_, quote, specifier) => {
        const relative = posix.relative(posix.dirname(destination), dependencies[specifier])
        return `from ${quote}${relative.startsWith('.') ? '' : './'}${relative}${quote}`
      }).replace(/^\/\/# sourceMappingURL=.*$/gm, '')
    const target = resolve(output, destination)
    await mkdir(dirname(target), { recursive: true })
    await writeFile(target, rewritten)
  }
}
const name = 'dsh-anywhere'
const packageJSON = {
  name, version, type: 'module',
  description: 'Pair an iPhone with DeepSeek Harness using DSH Anywhere.',
  repository: 'https://github.com/aluvien/DSH-Anywhere-Connector',
  engines: { dsh: '>=0.2.2-rc.3 <0.2.3-0' },
  main: './lib/bridge/index.js',
  exports: { '.': './lib/bridge/index.js', './client': './lib/client.js', './package.json': './package.json' },
  dependencies: { 'qrcode-generator': '2.0.4', ws: '8.21.3', zod: '4.6.0' },
  dsh: {
    bundle: { patch: './cordis.patch.yml' },
    client: { platform: 'web', inject: ['@deepseek-ai/dsh-client-locale', '@deepseek-ai/dsh-client-ui-plugin-manager'] },
  },
}
await writeFile(resolve(output, 'package.json'), JSON.stringify(packageJSON, null, 2) + '\n')
const patch = await readFile(resolve(root, 'packages/dsh-anywhere-plugin/cordis.patch.yml'), 'utf8')
await writeFile(resolve(output, 'cordis.patch.yml'), patch.replace("name: './lib/index.js'", "name: 'dsh-anywhere'")
  .replace('        routePrefix:', '        managedConnector: true\n        routePrefix:'))
const client = await readFile(resolve(root, 'packages/dsh-anywhere-plugin/client/remote-setup.cjs'), 'utf8')
await writeFile(resolve(output, 'lib/client.js'),
  `window.__ModuleLoader__.load({ id: ${JSON.stringify(name)}, factory(require) {\nconst exports = {};\n${client}\nreturn exports;\n} });\n`)
await cp(resolve(root, 'packages/dsh-anywhere-plugin/README.md'), resolve(output, 'README.md'))
