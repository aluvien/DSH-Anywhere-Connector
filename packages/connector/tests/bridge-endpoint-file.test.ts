import { describe, expect, it } from 'vitest';
import { mkdtemp, writeFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { endpointFileResolver } from '../src/bridge-endpoint-file.js';
import { runCli } from '../src/cli.js';

describe('Bridge endpoint discovery', () => {
  it('follows port changes, preserves legacy fallback and rejects unsafe descriptors', async () => {
    const dir = await mkdtemp(join(tmpdir(), 'dsh-discovery-'));
    const file = join(dir, 'bridge-endpoint.json');
    const fallback = 'http://127.0.0.1:3080/dsh-anywhere/v1';
    const resolve = endpointFileResolver(file, fallback);
    try {
      expect(await resolve()).toBe(fallback);
      for (const port of [59656, 59657]) {
        await writeFile(file, JSON.stringify({ version: 1, origin: `http://127.0.0.1:${port}`, port }));
        expect(await resolve()).toBe(`http://127.0.0.1:${port}/dsh-anywhere/v1`);
      }
      for (const origin of ['http://attacker.test:1234', 'http://user@127.0.0.1:1234', 'http://127.0.0.1:1234/elsewhere']) {
        await writeFile(file, JSON.stringify({ version: 1, origin, port: 1234 }));
        await expect(resolve()).rejects.toThrow('Invalid bridge endpoint');
      }
      await writeFile(file, 'x'.repeat(4097));
      await expect(resolve()).rejects.toThrow('Invalid bridge endpoint');
      expect(await endpointFileResolver(file, 'https://custom.example/bridge')()).toBe('https://custom.example/bridge');
    } finally { await rm(dir, { recursive: true, force: true }); }
  });

  it('status uses discovery too, while an explicit environment URL takes precedence', async () => {
    const dir = await mkdtemp(join(tmpdir(), 'dsh-status-'));
    const file = join(dir, 'connector.json');
    try {
      await writeFile(file, JSON.stringify({ relayURL: 'wss://relay.example', machineId: 'mac',
        machineToken: 'secret', bridgeToken: 'secret', bridgeBaseURL: 'http://127.0.0.1:3080/dsh-anywhere/v1' }));
      await writeFile(join(dir, 'bridge-endpoint.json'), JSON.stringify({ version: 1, origin: 'http://127.0.0.1:59656', port: 59656 }));
      for (const override of [undefined, 'http://127.0.0.1:4321/custom']) {
        let queried = '';
        const environment = override === undefined ? {} : { DSH_ANYWHERE_BRIDGE_BASE_URL: override };
        expect(await runCli(['status', '--config', file], { environment,
          stdout: () => {}, stderr: () => {}, fetch: (async (url) => {
            queried = String(url); return Response.json({ ok: true });
          }) as typeof fetch })).toBe(0);
        expect(queried).toBe(`${override ?? 'http://127.0.0.1:59656/dsh-anywhere/v1'}/health`);
      }
    } finally { await rm(dir, { recursive: true, force: true }); }
  });
});
