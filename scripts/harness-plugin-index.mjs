#!/usr/bin/env node
import { readFile } from 'node:fs/promises'

const [manifestPath, commit, timestamp] = process.argv.slice(2)
if (!manifestPath || !/^[a-f0-9]{40}$/.test(commit ?? '') || !/^\d{1,11}$/.test(timestamp ?? '')) {
  throw new Error('Usage: node scripts/harness-plugin-index.mjs <published-package.json> <commit> <unix-seconds>')
}
const manifest = JSON.parse(await readFile(manifestPath, 'utf8'))
if (manifest.name !== 'dsh-anywhere' || !manifest.engines?.dsh || !manifest.version) {
  throw new Error('Expected the prebuilt DSH Anywhere plugin manifest.')
}
const repository = 'https://github.com/aluvien/DSH-Anywhere-Connector'
const index = {
  format: 1,
  title: 'DSH Anywhere',
  plugins: [{
    name: manifest.name,
    title: 'DSH Anywhere',
    description: { en: 'Connect your iPhone to Harness.', zh: '用 iPhone 远程连接 Harness。' },
    repository: { url: repository, directory: 'packages/dsh-anywhere-plugin' },
    metadata: { keywords: ['remote', 'iphone', '远程连接', '手机'] },
    'dist-tags': { latest: manifest.version },
    versions: [{
      version: manifest.version,
      publishTimestamp: Number(timestamp),
      source: { type: 'git', url: repository, commit, path: 'release/harness' },
      engines: { dsh: manifest.engines.dsh },
    }],
  }],
}
process.stdout.write(JSON.stringify(index, null, 2) + '\n')
