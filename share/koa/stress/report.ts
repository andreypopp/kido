import assert from 'node:assert/strict';
import { readdir, readFile } from 'node:fs/promises';
import { resolve, join } from 'node:path';
import { names } from './workloads.ts';

type Sample = { t: number; bytes: number; clockError: number; frame?: number; applied?: number };
type Record = { samples: Sample[]; bytes: number; opens: number; caps: number; flushes: number; highWater: number };
type Memory = { rssKiB: number; processes: number };
type Summary = { target: 'page' | 'kido'; id: number; status: string; error?: string; metrics: string[]; seconds: number; heap?: number; before?: Memory; after?: Memory };
type Row = { target: 'chrome' | 'kido'; id: number; name: string | undefined; status: 'ok' | 'failed'; error?: string; timing?: 'flush→frame' | 'flush→apply'; seconds?: string; p50?: number; p95?: number; p99?: number; bytes?: number; opens?: number; caps?: number; flushes?: number; flushHz?: string; sampleHz?: string; heapMB?: string; rssDeltaMiB?: string; processesBefore?: number; processesAfter?: number };
export async function report(directory: string) {
  const manifests = (await readdir(directory)).filter(name => /^(page|kido)-manifest\.json$/.test(name));
  assert.ok(manifests.length, 'No run manifest');
  const rows: Row[] = [];
  for (const file of manifests) {
    const manifest: { target: 'page' | 'kido'; ids: number[] } = JSON.parse(await readFile(join(directory, file), 'utf8'));
    assert.ok(['page', 'kido'].includes(manifest.target) && Array.isArray(manifest.ids) && manifest.ids.length > 0, 'Invalid manifest');
    assert.equal(new Set(manifest.ids).size, manifest.ids.length, 'Duplicate workloads');
    for (const id of manifest.ids) {
      assert.ok(Number.isSafeInteger(id) && id >= 1 && id <= names.length, 'Invalid workload');
      const summary: Summary = JSON.parse(await readFile(join(directory, `${manifest.target}-${id}-summary.json`), 'utf8'));
      assert.equal(summary.target, manifest.target); assert.equal(summary.id, id);
      assert.ok(summary.status === 'ok' || summary.status === 'failed', 'Invalid workload status');
      assert.ok(Number.isFinite(summary.seconds) && summary.seconds > 0, 'Invalid duration');
      assert.ok(Array.isArray(summary.metrics));
      if (summary.status === 'failed') {
        assert.ok(typeof summary.error === 'string' && summary.error.length > 0, 'Missing failure reason');
        rows.push({ target: summary.target === 'page' ? 'chrome' : 'kido', id, name: names[id - 1], status: 'failed', error: summary.error, seconds: summary.seconds.toFixed(1), processesBefore: summary.before?.processes, processesAfter: summary.after?.processes });
        continue;
      }
      assert.equal(summary.metrics.length, summary.target === 'page' ? 1 : id === 6 ? 8 : id === 12 ? 7 : 1, 'Missing pane metrics');
      const timing = summary.target === 'page' ? 'frame' : 'applied';
      const streams = await Promise.all(summary.metrics.map(async path => {
        const records: Record[] = (await readFile(path, 'utf8')).trim().split('\n').map(line => JSON.parse(line));
        assert.ok(records.length, 'No metric records');
        for (const record of records) {
          for (const key of ['bytes', 'opens', 'caps', 'flushes', 'highWater']) assert.ok(Number.isFinite(Reflect.get(record, key)), 'Invalid counter ' + key);
          assert.ok(Array.isArray(record.samples), 'Invalid sample batch');
          for (const sample of record.samples) {
            const at = sample[timing];
            assert.ok(Number.isFinite(sample.t) && typeof at === 'number' && Number.isFinite(at) && Number.isFinite(sample.bytes), 'Invalid timing sample');
            assert.ok(Number.isFinite(sample.clockError) && Math.abs(sample.clockError) <= 100 && at - sample.t >= -100, 'Wall-clock jump detected');
          }
        }
        assert.ok(records.flatMap(record => record.samples).length > 0, 'No timing samples for ' + path);
        return records;
      }));
      const samples = streams.flatMap(stream => stream.flatMap(record => record.samples));
      const times = samples.map(sample => { const at = sample[timing]; assert.ok(at !== undefined); return at - sample.t; }).sort((a, b) => a - b);
      const percentile = (fraction: number) => { const value = times[Math.min(times.length - 1, Math.floor(times.length * fraction))]; assert.ok(value !== undefined); return Number(value.toFixed(2)); };
      const total = (key: 'bytes' | 'opens' | 'caps' | 'flushes') => streams.reduce((sum, stream) => { const last = stream.at(-1); assert.ok(last); return sum + last[key]; }, 0);
      if (summary.target === 'kido') assert.ok(summary.before && summary.after && Object.values(summary.before).every(Number.isFinite) && Object.values(summary.after).every(Number.isFinite), 'Invalid WebContent memory');
      else assert.ok(Number.isFinite(summary.heap), 'Invalid Chrome heap');
      rows.push({ target: summary.target === 'page' ? 'chrome' : 'kido', id, name: names[id - 1], status: 'ok', timing: summary.target === 'page' ? 'flush→frame' : 'flush→apply', seconds: summary.seconds.toFixed(1), p50: percentile(.5), p95: percentile(.95), p99: percentile(.99), bytes: total('bytes'), opens: total('opens'), caps: total('caps'), flushes: total('flushes'), flushHz: (total('flushes') / summary.seconds).toFixed(1), sampleHz: (new Set(samples.map(sample => sample[timing])).size / summary.seconds).toFixed(1), heapMB: summary.heap === undefined ? undefined : (summary.heap / 1e6).toFixed(1), rssDeltaMiB: summary.after && summary.before ? ((summary.after.rssKiB - summary.before.rssKiB) / 1024).toFixed(1) : undefined, processesBefore: summary.before?.processes, processesAfter: summary.after?.processes });
    }
  }
  return rows.sort((a, b) => a.id - b.id || a.target.localeCompare(b.target));
}
if (process.argv[1] === new URL(import.meta.url).pathname) {
  const directory = process.env.KOA_STRESS_OUTPUT;
  if (!directory) throw Error('KOA_STRESS_OUTPUT is required');
  const rows = await report(resolve(directory));
  console.table(rows);
  if (rows.some(row => row.status === 'failed')) process.exitCode = 1;
  console.log('Chrome flush→frame uses rAF, not a paint-completion signal; Kido flush→apply uses never-ordered pages. RSS is global WebContent RSS with before/after baselines. W12 creates parented panes through the API; unit 5 covers spawn_agent argv. W9 slot ordering is checked through Kido. Browser body kinds do not reproduce the bridge constraint.');
}
