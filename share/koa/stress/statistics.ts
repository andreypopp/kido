import type { MetricsSample, Observation } from '../koa-records.ts';

export type Engine = { at: number; metrics: Record<string, number> };
export type Spread = { count: number; p50?: number; p95?: number; p99?: number; over17: number; over50: number };
type Budget = { name: string; limit: { type: 'reported' } | { type: 'max'; value: number } };
type Verdict = { name: string; value: number | undefined; status: 'reported' | 'ok' | 'failed' };

export function percentile(values: readonly number[], fraction: number): number | undefined {
  if (!values.length) return undefined;
  const sorted = values.toSorted((a, b) => a - b), rank = fraction * (sorted.length - 1), low = Math.floor(rank), high = Math.ceil(rank);
  const a = sorted[low], b = sorted[high];
  return a === undefined || b === undefined ? undefined : a + (b - a) * (rank - low);
}

export const summarize = (values: readonly number[]): Spread => ({
  count: values.length, p50: percentile(values, .5), p95: percentile(values, .95), p99: percentile(values, .99),
  over17: values.filter(value => value > 16.7).length, over50: values.filter(value => value > 50).length,
});

export type Detail = { count: number; mean?: number; p95?: number; p99?: number; max?: number };
const detail = (values: readonly number[]): Detail => ({ count: values.length, mean: values.length ? values.reduce((sum, value) => sum + value, 0) / values.length : undefined, p95: percentile(values, .95), p99: percentile(values, .99), max: values.length ? Math.max(...values) : undefined });
export const NEAR_WORDS = 9000;

export function latency(samples: readonly MetricsSample[]) {
  const timed = samples.flatMap(sample => sample.frame !== undefined && sample.stages ? [{ sample, frame: sample.frame, stages: sample.stages }] : []);
  const legs = timed.map(({ sample, frame, stages }) => ({
    id: stages.id, visibility: stages.visibility, total: frame - sample.t,
    receive: stages.received - sample.t, request: stages.request && stages.request.at - stages.received,
    raf: stages.request && stages.request.fired - stages.request.at, done: stages.request && frame - stages.request.fired,
  }));
  const defined = (pick: (leg: (typeof legs)[number]) => number | undefined) => legs.flatMap(leg => { const value = pick(leg); return value === undefined ? [] : [value]; });
  return {
    writeToReceive: detail(defined(leg => leg.receive)), receiveToRequest: detail(defined(leg => leg.request)), requestToRaf: detail(defined(leg => leg.raf)), rafToDone: detail(defined(leg => leg.done)),
    hidden: legs.filter(leg => leg.visibility === 'hidden').length, timer: legs.filter(leg => leg.raf === undefined).length,
    worst: legs.toSorted((a, b) => b.total - a.total).slice(0, 5),
  };
}

export function totals(observations: readonly Observation[]) {
  const frames = observations.flatMap(observation => observation.type === 'frame' ? [observation] : []), applies = observations.flatMap(observation => observation.type === 'apply' ? [observation] : []);
  const strays = (list: readonly { strays: number }[]) => list.reduce((sum, entry) => sum + entry.strays, 0);
  const probes = (list: readonly { probes: number }[]) => list.reduce((sum, entry) => sum + entry.probes, 0);
  const dots = (phase: 'call' | 'text' | 'end') => observations.reduce((sum, observation) => sum + (observation.type === 'dots' && observation.phase === phase ? observation.count : 0), 0);
  const renders = observations.flatMap(observation => observation.type === 'markdown' ? [observation] : []);
  return {
    markdown: { all: detail(renders.map(render => render.lex)), near: detail(renders.filter(render => render.words >= NEAR_WORDS).map(render => render.lex)), fallbacks: renders.reduce((sum, render) => sum + render.fallbacks, 0), words: Math.max(0, ...renders.map(render => render.words)) },
    frame: summarize(frames.map(frame => frame.duration)),
    gap: summarize(frames.flatMap(frame => frame.gap === undefined ? [] : [frame.gap])),
    apply: summarize(applies.map(apply => apply.duration)),
    slowApplies: applies.filter(apply => apply.duration > 16.7).reduce<Record<string, number>>((kinds, apply) => ({ ...kinds, [apply.record]: (kinds[apply.record] ?? 0) + 1 }), {}),
    lexMs: [...frames, ...applies].reduce((sum, entry) => sum + entry.lex, 0),
    key: summarize(observations.flatMap(observation => observation.type === 'key' ? [observation.latency] : [])),
    strays: { frame: strays(frames), apply: strays(applies), other: observations.filter(observation => observation.type === 'stray').length },
    strayBy: [...frames, ...applies, ...observations.flatMap(observation => observation.type === 'stray' ? [{ by: { [observation.source]: 1 } }] : [])].reduce<Record<string, number>>((sum, entry) => { for (const [source, count] of Object.entries(entry.by)) sum[source] = (sum[source] ?? 0) + count; return sum; }, {}),
    probes: { frame: probes(frames), apply: probes(applies), other: observations.filter(observation => observation.type === 'probe').length },
    dots: { call: dots('call'), text: dots('text'), end: dots('end') },
  };
}

export function engineDeltas(samples: readonly Engine[], frames: number) {
  const first = samples.at(0), last = samples.at(-1);
  if (!first || !last || first === last) return undefined;
  const seconds = (last.at - first.at) / 1000, delta = (name: string) => (last.metrics[name] ?? 0) - (first.metrics[name] ?? 0);
  return {
    seconds, layouts: delta('LayoutCount'), layoutsPerSecond: delta('LayoutCount') / seconds, layoutsPerFrame: frames ? delta('LayoutCount') / frames : undefined,
    layoutSeconds: delta('LayoutDuration'), recalcs: delta('RecalcStyleCount'), taskSeconds: delta('TaskDuration'),
    heapMax: Math.max(...samples.map(sample => sample.metrics.JSHeapUsedSize ?? 0)), nodes: last.metrics.Nodes,
  };
}

export const evaluate = (budgets: readonly Budget[], values: Readonly<Record<string, number | undefined>>): Verdict[] => budgets.map(({ name, limit }) => {
  const value = values[name];
  return { name, value, status: limit.type === 'reported' || value === undefined ? 'reported' : value > limit.value ? 'failed' : 'ok' };
});

export const streamBudgets: Budget[] = [
  { name: 'frame p99 ms', limit: { type: 'reported' } },
  { name: 'frames over 50 ms', limit: { type: 'reported' } },
  { name: 'stray reads per frame', limit: { type: 'reported' } },
  { name: 'dots detachments while text streams', limit: { type: 'reported' } },
  { name: 'key→frame p99 ms', limit: { type: 'reported' } },
];
