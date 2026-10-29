import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, mkdir, readFile, writeFile, readdir, rm } from 'node:fs/promises';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';

test('Desktop installation is repeatable, self-contained and preserves registration and unrelated plugins', async () => {
  const root = await mkdtemp(join(tmpdir(), 'dsh-install-'));
  try {
    const profile = join(root, 'profile');
    const support = join(root, 'Application Support', 'DSH Anywhere');
    await mkdir(profile);
    await mkdir(support, { recursive: true });
    const config = join(support, 'connector.json');
    const registration = JSON.stringify({ bridgeToken: 'test-private-registration' });
    await writeFile(config, registration, { mode: 0o600 });
    await writeFile(join(profile, 'package.json'), JSON.stringify({
      dependencies: { 'other-plugin': '^1.0.0', 'dsh-anywhere-endpoint': '0.1.0' },
      dsh: { profile: { bundles: ['@deepseek-ai/dsh-base', 'other-plugin', 'dsh-anywhere-endpoint'] } },
    }));
    for (let i = 0; i < 2; i++) {
      await promisify(execFile)(process.execPath, ['scripts/install-desktop.mjs', '--profile', profile, '--config', config]);
      const installed = JSON.parse(await readFile(join(profile, 'package.json'), 'utf8'));
      assert.deepEqual(installed.dsh.profile.bundles, ['@deepseek-ai/dsh-base', 'other-plugin', 'dsh-anywhere']);
      assert.equal(installed.dependencies['other-plugin'], '^1.0.0');
      assert.equal(await readFile(config, 'utf8'), registration);
      assert.match(await readFile(join(profile, 'node_modules/dsh-anywhere/lib/gateway.js'), 'utf8'), /createPeer/);
      assert.match(await readFile(join(support, 'connector-desktop/lib/cli.js'), 'utf8'), /resolveBridgeBaseURL/);
      await assert.rejects(promisify(execFile)(process.execPath,
        [join(support, 'connector-desktop/lib/cli.js'), '--invalid']),
      error => error.code === 64 && error.stderr.includes('Usage: dsh-anywhere'));
    }
    assert.equal((await readdir(join(support, 'backups'))).length, 2);
  } finally { await rm(root, { recursive: true, force: true }); }
});
