#!/usr/bin/env node
// Install built, self-contained packages into an existing Desktop profile.
// No package-manager run in the user's profile, credentials, or session edits.
import { cp, mkdir, readFile, realpath, rename, rm, writeFile, access } from 'node:fs/promises';
import { homedir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { randomUUID } from 'node:crypto';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const options = {};
for (let i = 2; i < process.argv.length; i += 2) {
  const key = process.argv[i];
  if (!['--profile', '--config'].includes(key) || !process.argv[i + 1]) throw new Error('Usage: install-desktop.mjs [--profile path] --config path');
  options[key] = resolve(process.argv[i + 1]);
}
if (!options['--config']) throw new Error('--config is required');
const configPath = options['--config'];
const support = dirname(configPath);
const profile = options['--profile'] ?? join(process.env.DSH_HOME ?? join(homedir(), '.dsh'), 'profiles', 'desktop');
const manifestPath = join(profile, 'package.json');
const original = await readFile(manifestPath, 'utf8');
const manifest = JSON.parse(original);
if (!Array.isArray(manifest.dsh?.profile?.bundles)) throw new Error('Not an initialized Harness Desktop profile');
await access(configPath);

const stage = join(support, `.desktop-stage-${randomUUID()}`);
const backup = join(support, 'backups', `desktop-${Date.now()}-${randomUUID().slice(0, 8)}`);
const installed = [];
const displaced = [];
let manifestWritten = false;
const exists = async path => { try { await access(path); return true; } catch (e) { if (e.code === 'ENOENT') return false; throw e; } };
const quote = text => `'${text.replaceAll("'", "'\\''")}'`;

async function copyPackage(source, target, ancestor = new Set()) {
  source = await realpath(source);
  if (ancestor.has(source)) throw new Error('Cyclic runtime dependency');
  const metadata = JSON.parse(await readFile(join(source, 'package.json'), 'utf8'));
  await mkdir(target, { recursive: true });
  // Package roots contain their compiled entrypoints and assets. Never copy
  // the pnpm dependency tree or development dependencies wholesale.
  await cp(source, target, { recursive: true, dereference: true,
    filter: path => path === source || !['node_modules', '.git', 'tests', 'src'].includes(path.slice(source.length + 1).split('/')[0]) });
  delete metadata.devDependencies;
  delete metadata.scripts;
  for (const name of Object.keys(metadata.dependencies ?? {})) {
    const dependency = await realpath(join(source, 'node_modules', name));
    const dependencyMetadata = JSON.parse(await readFile(join(dependency, 'package.json'), 'utf8'));
    metadata.dependencies[name] = dependencyMetadata.version;
    await copyPackage(dependency, join(target, 'node_modules', name), new Set([...ancestor, source]));
  }
  await writeFile(join(target, 'package.json'), JSON.stringify(metadata, null, 2) + '\n');
  return metadata;
}

async function replace(source, target, backupName) {
  await mkdir(dirname(target), { recursive: true });
  if (await exists(target)) {
    const saved = join(backup, backupName);
    await rename(target, saved);
    displaced.push([saved, target]);
  }
  await rename(source, target);
  installed.push(target);
}

try {
  await mkdir(stage, { recursive: true, mode: 0o700 });
  // Check all build outputs before touching the live installation.
  await access(join(root, 'packages/dsh-anywhere-plugin/lib/gateway.js'));
  await access(join(root, 'packages/connector/lib/bridge-endpoint-file.js'));
  const pluginStage = join(stage, 'dsh-anywhere');
  const plugin = await copyPackage(join(root, 'packages/dsh-anywhere-plugin'), pluginStage);
  plugin.name = 'dsh-anywhere';
  await writeFile(join(pluginStage, 'package.json'), JSON.stringify(plugin, null, 2) + '\n');
  const connectorStage = join(stage, 'connector-desktop');
  await copyPackage(join(root, 'packages/connector'), connectorStage);
  await writeFile(join(connectorStage, 'run-connector.sh'),
    `#!/bin/sh\nexec ${quote(process.execPath)} ${quote(join(support, 'connector-desktop/lib/cli.js'))} start --config ${quote(configPath)}\n`, { mode: 0o700 });
  // Validate that staging can import both packages, including dependencies.
  await import(join(pluginStage, 'lib/index.js'));
  await import(join(connectorStage, 'lib/connector.js'));
  await mkdir(backup, { recursive: true, mode: 0o700 });
  await writeFile(join(backup, 'profile-package.json'), original, { mode: 0o600 });
  await replace(pluginStage, join(profile, 'node_modules/dsh-anywhere'), 'dsh-anywhere');
  await replace(connectorStage, join(support, 'connector-desktop'), 'connector-desktop');
  manifest.dependencies ??= {};
  manifest.dependencies['dsh-anywhere'] = plugin.version;
  // Discovery is now owned by the Bridge; leave the old package on disk for
  // rollback but stop loading its competing writer on the next Host launch.
  delete manifest.dependencies['dsh-anywhere-endpoint'];
  manifest.dsh.profile.bundles = [...new Set(manifest.dsh.profile.bundles
    .filter(name => name !== 'dsh-anywhere-endpoint').concat('dsh-anywhere'))];
  const nextManifest = join(profile, `.package-${randomUUID()}.json`);
  await writeFile(nextManifest, JSON.stringify(manifest, null, 2) + '\n');
  await rename(nextManifest, manifestPath);
  manifestWritten = true;
  console.log(`Desktop Bridge and Connector installed. Backup: ${backup}`);
  console.log('Restart DeepSeek Harness after active tasks finish to load the updated Bridge.');
} catch (error) {
  for (const target of installed.reverse()) await rm(target, { recursive: true, force: true });
  for (const [saved, target] of displaced.reverse()) await rename(saved, target);
  if (manifestWritten) await writeFile(manifestPath, original);
  throw error;
} finally { await rm(stage, { recursive: true, force: true }); }
