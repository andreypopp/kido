import assert from 'node:assert/strict';
import { readdir, readFile, writeFile } from 'node:fs/promises';
import { Console } from 'node:console';
import { Writable } from 'node:stream';
import { resolve, join } from 'node:path';
import { workloads, streaming, STREAM_MEMORY_MIB } from './workloads.ts';
import { NEAR_WORDS, engineDeltas, evaluate, latency, percentile, streamBudgets, totals, type Detail, type Engine, type Spread } from './statistics.ts';
import type { MetricsSample, Observation } from '../koa-records.ts';

type Batch = { observations: Observation[]; samples: MetricsSample[]; bytes: number; opens: number; caps: number; flushes: number; highWater: number };
type Memory = { footprintBytes: number; maxFootprintBytes: number; processes: number };
type Summary = { since?: number; until?: number; engine?: Engine[]; dots?: Record<string, string[]>; dotsNodes?: number; layerEvents?: number; mappedLayers?: number; keys?: 'cdp' | 'synthetic'; timing: 'applied' | 'frame'; id: number; status: string; error?: string; metrics: string[]; seconds: number; heap?: number; before?: Memory; after?: Memory } & ({ target: 'page' } | { target: 'kido'; visible: boolean });
type Row = { stream?: Record<string, string>; pages?: 'hidden pages' | 'visible pages'; target: 'chrome' | 'kido'; id: number; name: string | undefined; status: 'ok' | 'failed'; error?: string; timing?: 'flush→frame' | 'flush→apply'; seconds?: string; p50?: number; p95?: number; p99?: number; bytes?: number; opens?: number; caps?: number; flushes?: number; flushHz?: string; sampleHz?: string; heapMB?: string; footprintDeltaMiB?: string; memoryMaxPageMiB?: string; memoryBudget?: string; memoryPerPageMiB?: string; processesBefore?: number; processesAfter?: number };
const ms = (value: number | undefined) => value === undefined ? '—' : value.toFixed(1);
const details = (summary: Detail) => `${ms(summary.mean)} / ${ms(summary.p95)} / ${ms(summary.p99)} / ${ms(summary.max)} (n=${summary.count})`;
const spread = (summary: Spread) => `${ms(summary.p50)} / ${ms(summary.p95)} / ${ms(summary.p99)}`;

type Pass = { summary: Summary; observations: Observation[]; loading: Observation[] };
async function pass(summary: Summary): Promise<Pass> {
  assert.ok(summary.since !== undefined && summary.until !== undefined && Number.isFinite(summary.since) && Number.isFinite(summary.until), 'Missing measurement window');
  const { since, until } = summary;
  const batches: Batch[] = (await readFile(summary.metrics[0] ?? '', 'utf8')).trim().split('\n').map(line => JSON.parse(line));
  const all = batches.flatMap(batch => batch.observations);
  return { summary, observations: all.filter(observation => observation.at >= since && observation.at <= until), loading: all.filter(observation => observation.at < since) };
}

const layerText = (summary: Summary) => {
  const layers = Object.values(summary.dots ?? {});
  if (summary.layerEvents === undefined) return '—';
  if (summary.layerEvents === 0) return 'no layer tree events';
  if (!summary.mappedLayers) return 'no mapping: the layers carry no backendNodeId';
  if (!layers.length) return 'not composited: layers carry backend ids, none is a dots node';
  const most = Math.max(...layers.map(ids => ids.length));
  return `${layers.length} of ${summary.dotsNodes} nodes layered; ids per node max ${most} (${most === 1 ? 'stable' : 'changed'})`;
};

function streamTable(frame: Pass, probe: Pass | undefined, budgets: Parameters<typeof evaluate>[0], samples: readonly MetricsSample[]) {
  const legs = latency(samples);
  const timed = totals(frame.observations), counted = probe && totals(probe.observations), loaded = totals(frame.loading).frame;
  const engine = (pass: Pass | undefined, count: number | undefined) => pass?.summary.engine && engineDeltas(pass.summary.engine, count ?? 0);
  const both = (name: string, text: (pass: Pass, sum: ReturnType<typeof totals>) => string): [string, string][] => [[name + ' [frame pass]', text(frame, timed)], [name + ' [probe pass]', probe && counted ? text(probe, counted) : '—']];
  const layouts = (pass: Pass, sum: ReturnType<typeof totals>) => { const delta = engine(pass, sum.frame.count); return delta ? `${delta.layouts}, ${delta.layoutsPerSecond.toFixed(1)}/s, ${delta.layoutsPerFrame?.toFixed(2) ?? '—'}/frame` : '—'; };
  const verdicts = evaluate(budgets, { 'frame p99 ms': timed.frame.p99, 'frames over 50 ms': timed.frame.over50, 'stray reads per frame': counted?.frame.count ? counted.strays.frame / counted.frame.count : undefined, 'dots detachments while text streams': counted?.dots.text, 'key→frame p99 ms': timed.key.p99, 'history load max frame ms': loaded.max, 'history load frames over 50 ms': loaded.count ? loaded.over50 : undefined });
  const table = Object.fromEntries([
    ...both('frames (render task)', (_, sum) => String(sum.frame.count)),
    ...both('frame ms p50 / p95 / p99', (_, sum) => spread(sum.frame)),
    ['frames over 16.7 / 50 ms [frame pass]', `${timed.frame.over17} / ${timed.frame.over50}`],
    ['history load (reset and older) frame ms max / frames over 50 ms [before the stream]', `${ms(loaded.max)} / ${loaded.over50} (n=${loaded.count})`],
    ['frame gap ms p50 / p95 / p99 [frame pass]', (timed.gap.count ? spread(timed.gap) : 'no tick re-scheduled itself') + ` (${timed.gap.count} chained of ${timed.frame.count} frames)`],
    ['gaps over 16.7 / 50 ms [frame pass]', `${timed.gap.over17} / ${timed.gap.over50}`],
    ['record apply ms p50 / p95 / p99 [frame pass]', spread(timed.apply)],
    ['applies over 16.7 / 50 ms [frame pass]', `${timed.apply.over17} / ${timed.apply.over50}`],
    ['applies over 16.7 ms by record [frame pass]', JSON.stringify(timed.slowApplies)],
    ['lex ms (all scopes) [frame pass]', timed.lexMs.toFixed(0)],
    ['markdown lex ms mean / p95 / p99 / max per changed-source render [frame pass]', details(timed.markdown.all)],
    [`markdown lex ms mean / p95 / p99 / max at ${NEAR_WORDS}+ words (largest render ${timed.markdown.words} words) [frame pass]`, details(timed.markdown.near)],
    ['markdown incremental lex fallbacks (boundary + references) [frame pass]', String(timed.markdown.fallbacks)],
    ['flush write→receive ms mean / p95 / p99 / max [frame pass]', details(legs.writeToReceive)],
    ['receive→frame request ms mean / p95 / p99 / max (negative: already requested) [frame pass]', details(legs.receiveToRequest)],
    ['frame request→rAF ms mean / p95 / p99 / max [frame pass]', details(legs.requestToRaf)],
    ['frame request→rAF samples over 100 ms [frame pass]', `${legs.rafOver100} of ${legs.requestToRaf.count}`],
    ['rAF→tick done ms mean / p95 / p99 / max [frame pass]', details(legs.rafToDone)],
    ['markers received while hidden / completed by timer, not rAF [frame pass]', `${legs.hidden} / ${legs.timer}`],
    ['worst 5 flush→frame markers: id total (write→receive, receive→request, request→rAF, rAF→done) visibility [frame pass]', legs.worst.map(leg => `#${leg.id} ${leg.total.toFixed(1)} (${[leg.receive, leg.request, leg.raf, leg.done].map(ms).join(', ')}) ${leg.visibility}`).join('; ') || '—'],
    ['key→frame ms p50 / p99 [frame pass]', `${ms(timed.key.p50)} / ${ms(timed.key.p99)} (n=${timed.key.count}, ${frame.summary.keys ?? 'unknown'} keys)`],
    ['stray reads in frame / apply / other [probe pass]', counted ? `${counted.strays.frame} / ${counted.strays.apply} / ${counted.strays.other}` : '—'],
    ['stray reads by dirtying source [probe pass]', counted ? JSON.stringify(counted.strayBy) : '—'],
    ['dots detachments at calls / while text / at end [probe pass]', counted ? `${counted.dots.call} / ${counted.dots.text} / ${counted.dots.end}` : '—'],
    ...both('Chrome layouts (count, per s, per frame)', layouts),
    ...both('Chrome layout s / style recalcs / task s', (pass, sum) => { const delta = engine(pass, sum.frame.count); return delta ? `${delta.layoutSeconds.toFixed(2)} / ${delta.recalcs} / ${delta.taskSeconds.toFixed(2)}` : '—'; }),
    ...both('Chrome heap max MiB / nodes at end', (pass, sum) => { const delta = engine(pass, sum.frame.count); return delta ? `${(delta.heapMax / 1048576).toFixed(1)} / ${delta.nodes}` : '—'; }),
    ['DOM nodes at end / max [frame pass]', (() => { const delta = engine(frame, timed.frame.count); return delta ? `${delta.nodes} / ${delta.nodesMax} (CDP Nodes)` : `${timed.nodes.end ?? '—'} / ${timed.nodes.max ?? '—'} (1 s samples)`; })()],
    ['dots layer [probe pass]', probe ? layerText(probe.summary) : '—'],
    ...verdicts.map(verdict => ['budget ' + verdict.name, `${verdict.status}${verdict.value === undefined ? '' : ' (' + verdict.value.toFixed(2) + ')'}`]),
  ]);
  const failures = verdicts.flatMap(verdict => verdict.status === 'failed' ? [`${verdict.name}: ${verdict.value?.toFixed(2)} exceeds its budget`] : []);
  return { table, failures };
}

export async function report(directory: string, budgets = streamBudgets) {
  const files = await readdir(directory);
  const manifests = files.filter(name => /^(page|kido)-manifest\.json$/.test(name));
  assert.ok(manifests.length, 'No run manifest');
  const rows: Row[] = [];
  for (const file of manifests) {
    const manifest: { target: 'page' | 'kido'; ids: number[] } = JSON.parse(await readFile(join(directory, file), 'utf8'));
    assert.ok(['page', 'kido'].includes(manifest.target) && Array.isArray(manifest.ids) && manifest.ids.length > 0, 'Invalid manifest');
    assert.equal(new Set(manifest.ids).size, manifest.ids.length, 'Duplicate workloads');
    for (const id of manifest.ids) {
      assert.ok(Number.isSafeInteger(id) && id >= 1 && id <= workloads.length, 'Invalid workload');
      const workload = workloads[id - 1];
      assert.ok(workload, 'Invalid workload');
      const summary: Summary = JSON.parse(await readFile(join(directory, `${manifest.target}-${id}-summary.json`), 'utf8'));
      assert.equal(summary.target, manifest.target); assert.equal(summary.id, id);
      assert.ok(summary.status === 'ok' || summary.status === 'failed', 'Invalid workload status');
      const target = summary.target === 'page' ? 'chrome' : 'kido';
      if (summary.target === 'kido') assert.equal(typeof summary.visible, 'boolean', 'Missing visibility');
      const pages = summary.target === 'kido' ? summary.visible ? 'visible pages' : 'hidden pages' : undefined;
      if (summary.status === 'failed') {
        assert.ok(typeof summary.error === 'string' && summary.error.length > 0, 'Missing failure reason');
        rows.push({ target, id, name: workload.name, pages, status: 'failed', error: summary.error, seconds: Number.isFinite(summary.seconds) ? summary.seconds.toFixed(1) : undefined, processesBefore: summary.before?.processes, processesAfter: summary.after?.processes });
        continue;
      }
      assert.ok(Number.isFinite(summary.seconds) && summary.seconds > 0, 'Invalid duration');
      assert.ok(Array.isArray(summary.metrics));
      const timing = summary.timing;
      assert.ok(timing === 'frame' || timing === 'applied', 'Missing timing mode');
      assert.equal(summary.metrics.length, summary.target === 'page' ? 1 : id === 6 ? 8 : id === 12 ? 7 : 1, 'Missing pane metrics');
      const streams = await Promise.all(summary.metrics.map(async path => {
        const records: Batch[] = (await readFile(path, 'utf8')).trim().split('\n').map(line => JSON.parse(line));
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
      const times = samples.map(sample => { const at = sample[timing]; assert.ok(at !== undefined); return at - sample.t; });
      const rank = (fraction: number) => { const value = percentile(times, fraction); assert.ok(value !== undefined); return Number(value.toFixed(2)); };
      const total = (key: 'bytes' | 'opens' | 'caps' | 'flushes') => streams.reduce((sum, stream) => { const last = stream.at(-1); assert.ok(last); return sum + last[key]; }, 0);
      let memory: number, footprintDelta: number | undefined;
      if (summary.target === 'kido') {
        assert.ok(summary.before && summary.after && Object.values(summary.before).every(Number.isFinite) && Object.values(summary.after).every(Number.isFinite), 'Invalid WebContent memory');
        footprintDelta = (summary.after.footprintBytes - summary.before.footprintBytes) / 1048576;
        memory = footprintDelta / summary.metrics.length;
      } else {
        assert.ok(summary.heap !== undefined && Number.isFinite(summary.heap), 'Invalid Chrome heap');
        memory = summary.heap / 1048576;
      }
      const budget = workload.memory.type === 'reported' ? workload.memory : summary.target === 'page' ? { type: 'limit' as const, name: 'retained-js-heap', mib: streaming.includes(id) ? STREAM_MEMORY_MIB.page : 32 } : !summary.visible ? { type: 'limit' as const, name: 'webcontent-phys-footprint-increase', mib: streaming.includes(id) ? STREAM_MEMORY_MIB.kido : 180 } : { type: 'unmeasured' as const };
      const error = budget.type === 'limit' && memory > budget.mib ? `${budget.name}: ${memory.toFixed(1)} MiB/page exceeds ${budget.mib} MiB/page` : undefined;
      let stream: { table: Record<string, string>; failures: string[] } | undefined;
      if (streaming.includes(id)) {
        const probeName = `${manifest.target}-${id}-probe-summary.json`;
        const probeSummary: Summary | undefined = files.includes(probeName) ? JSON.parse(await readFile(join(directory, probeName), 'utf8')) : undefined;
        assert.ok(!probeSummary || probeSummary.status === 'ok', 'Probe pass failed: ' + probeSummary?.error);
        stream = streamTable(await pass(summary), probeSummary && await pass(probeSummary), budgets, samples.filter(sample => sample.t >= (summary.since ?? 0) && sample.t <= (summary.until ?? Infinity)));
      }
      const failure = [error, ...stream?.failures ?? []].filter(reason => reason !== undefined).join('; ') || undefined;
      rows.push({ stream: stream?.table, target, id, name: workload.name, pages, status: failure ? 'failed' : 'ok', error: failure, memoryBudget: budget.type === 'limit' ? `${budget.name}: ${budget.mib} MiB/page` : budget.type === 'reported' ? `no budget: ${budget.reason}` : 'no budget: not measured', memoryPerPageMiB: memory.toFixed(1), timing: timing === 'frame' ? 'flush→frame' : 'flush→apply', seconds: summary.seconds.toFixed(1), p50: rank(.5), p95: rank(.95), p99: rank(.99), bytes: total('bytes'), opens: total('opens'), caps: total('caps'), flushes: total('flushes'), flushHz: (total('flushes') / summary.seconds).toFixed(1), sampleHz: (new Set(samples.map(sample => sample[timing])).size / summary.seconds).toFixed(1), heapMB: summary.heap === undefined ? undefined : (summary.heap / 1e6).toFixed(1), footprintDeltaMiB: footprintDelta?.toFixed(1), memoryMaxPageMiB: summary.after ? (summary.after.maxFootprintBytes / 1048576).toFixed(1) : undefined, processesBefore: summary.before?.processes, processesAfter: summary.after?.processes });
    }
  }
  return rows.sort((a, b) => a.id - b.id || a.target.localeCompare(b.target));
}
if (process.argv[1] === new URL(import.meta.url).pathname) {
  const directory = process.env.KOA_STRESS_OUTPUT;
  if (!directory) throw Error('KOA_STRESS_OUTPUT is required');
  const rows = await report(resolve(directory));
  const lines: string[] = [];
  const sink = new Console({ stdout: new Writable({ write(chunk, _encoding, done) { lines.push(String(chunk)); done(); } }) });
  sink.table(rows, [...new Set(rows.flatMap(row => Object.keys(row)))].filter(key => key !== 'stream'));
  const streamed = rows.flatMap(row => row.stream ? [{ name: row.target + ' ' + row.id + (row.pages ? ' ' + row.pages : ''), stream: row.stream }] : []);
  if (streamed[0]) sink.table(Object.keys(streamed[0].stream).map(metric => ({ metric, ...Object.fromEntries(streamed.map(({ name, stream }) => [name, stream[metric] ?? '—'])) })));
  const text = lines.join('');
  process.stdout.write(text);
  await writeFile(join(resolve(directory), 'report.txt'), text);
  await writeFile(join(resolve(directory), 'report.json'), JSON.stringify(rows, undefined, 1));
  if (rows.some(row => row.status === 'failed')) process.exitCode = 1;
  console.log('flush→frame uses rAF, not a paint-completion signal; flush→apply measures record application without a frame. Chrome heap is measured after GC. Kido measures phys_footprint of its own WebContent processes; the budget divides the increase by the number of pages, and the maximum is reported without a gate. Visible-page footprints have no budget because they have not been measured. W12 creates parented panes through the API. Browser body kinds do not reproduce the bridge constraint.');
}
