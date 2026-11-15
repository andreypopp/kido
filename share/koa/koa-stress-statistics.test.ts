import assert from 'node:assert/strict';
import { test } from 'node:test';
import { dotsPhase, holdsDots, strayReads } from './page/metrics.ts';
import { metricsRequest } from './koa-records.ts';
import { engineDeltas, evaluate, latency, percentile, summarize, totals } from './stress/statistics.ts';
import { CHUNK_TOKENS, STREAM_RESPONSES, STREAM_TOKENS, historyMessages, streamingReplies, HISTORY_ROWS } from './stress/workloads.ts';

test('percentiles interpolate between ranks', () => {
  assert.equal(percentile([], .5), undefined);
  assert.equal(percentile([7], .99), 7);
  assert.equal(percentile([5, 5, 5], .95), 5);
  assert.equal(percentile([40, 10, 30, 20], .5), 25);
  assert.equal(percentile([1, 2, 3, 4, 5], .99), 4.96);
});

test('summaries count frames over each limit and budgets stay reported until set', () => {
  const spread = summarize([10, 20, 50, 60]);
  assert.deepEqual([spread.count, spread.p50, spread.over17, spread.over50], [4, 35, 3, 1]);
  assert.equal(summarize([]).over17, 0);
  const verdicts = evaluate([{ name: 'a', limit: { type: 'reported' } }, { name: 'b', limit: { type: 'max', value: 10 } }, { name: 'c', limit: { type: 'max', value: 10 } }, { name: 'd', limit: { type: 'max', value: 10 } }], { a: 99, b: 11, c: 10 });
  assert.deepEqual(verdicts.map(verdict => verdict.status), ['reported', 'failed', 'ok', 'reported']);
});

test('observation totals and engine deltas are cumulative', () => {
  const sum = totals([
    { type: 'frame', at: 1, duration: 20, gap: 17, lex: 1, strays: 2, by: {} }, { type: 'frame', at: 2, duration: 4, lex: 0, strays: 0, by: {} },
    { type: 'apply', record: 'patch', at: 3, duration: 60, lex: 5, strays: 1, by: {} }, { type: 'stray', at: 4, source: 'key' }, { type: 'key', at: 5, latency: 9 },
    { type: 'dots', at: 6, phase: 'text', count: 2 }, { type: 'dots', at: 7, phase: 'call', count: 1 }, { type: 'dots', at: 8, phase: 'end', count: 1 },
  ]);
  assert.deepEqual([sum.frame.count, sum.frame.over17, sum.gap.count, sum.apply.over50, sum.lexMs], [2, 1, 1, 1, 6]);
  assert.deepEqual([sum.strays, sum.dots, sum.key.p50], [{ frame: 2, apply: 1, other: 1 }, { call: 1, text: 2, end: 1 }, 9]);
  const delta = engineDeltas([{ at: 0, metrics: { LayoutCount: 10, JSHeapUsedSize: 5 } }, { at: 2000, metrics: { LayoutCount: 50, JSHeapUsedSize: 3, Nodes: 7 } }], 20);
  assert.deepEqual([delta?.layouts, delta?.layoutsPerSecond, delta?.layoutsPerFrame, delta?.heapMax, delta?.nodes], [40, 20, 2, 5, 7]);
  assert.equal(engineDeltas([{ at: 0, metrics: {} }], 1), undefined);
});

test('stray reads count a read after a write in the same task only', () => {
  let posted = 0;
  const reads = strayReads(() => { posted++; });
  assert.equal(reads.read(), false);
  reads.write(true); reads.write(true);
  assert.equal(posted, 1);
  assert.deepEqual([reads.read(), reads.read()], [true, false]);
  reads.write(true);
  assert.equal(posted, 1);
  reads.settle();
  assert.equal(reads.read(), false);
  reads.write(true);
  assert.equal(posted, 2);
});

test('a frame starts clean unless something outside a frame wrote since the last frame', () => {
  const reads = strayReads(() => {});
  reads.write(true);
  reads.frameStart();
  assert.equal(reads.read(), false);
  reads.write(false);
  reads.frameStart();
  assert.equal(reads.read(), true);
  reads.write(true);
  reads.frameStart();
  assert.equal(reads.read(), false);
});

test('a removal counts when the node is the dots or holds them', () => {
  const holder = (matches: boolean, inside: boolean) => ({ matches: () => matches, querySelector: () => inside ? {} : null });
  assert.deepEqual([holder(true, false), holder(false, true), holder(false, false), {}].map(holdsDots), [true, true, false, false]);
});

test('the streaming workload is deterministic: size, mix and tool calls', () => {
  const replies = streamingReplies();
  assert.deepEqual(streamingReplies(), replies);
  assert.equal(replies.length, STREAM_RESPONSES + 1);
  assert.equal(replies.filter(reply => reply.tools?.[0]?.name === 'probe').length, STREAM_RESPONSES);
  assert.equal(replies.at(-1)?.tools, undefined);
  const texts = replies.map(reply => reply.chunks?.join('') ?? '');
  assert.equal(texts.slice(0, -1).join('').match(/\S+/g)?.length, STREAM_TOKENS);
  assert.equal(texts.at(-1)?.match(/\S+/g)?.length, STREAM_TOKENS);
  assert.ok(replies.every(reply => reply.chunks?.every(chunk => (chunk.match(/\S+/g)?.length ?? 0) <= CHUNK_TOKENS) && reply.delayMs === 50));
  const all = texts.join('');
  assert.ok(/^- /m.test(all) && /^```ts$/m.test(all) && /^\| - \|/m.test(all));
  const history = historyMessages();
  assert.ok(history.rows >= HISTORY_ROWS && history.texts.length % 2 === 0);
  assert.deepEqual(historyMessages(), history);
});

test('markdown renders and flush stages are summarized for the worst markers', () => {
  const sum = totals([{ type: 'markdown', at: 1, words: 100, lex: 1, fallbacks: 0 }, { type: 'markdown', at: 2, words: 9500, lex: 3, fallbacks: 1 }, { type: 'markdown', at: 3, words: 9600, lex: 5, fallbacks: 2 }]);
  assert.deepEqual([sum.markdown.all.mean, sum.markdown.near.count, sum.markdown.near.max, sum.markdown.fallbacks, sum.markdown.words], [3, 2, 5, 3, 9600]);
  const stages = (id: number, received: number, request?: { at: number; fired: number }) => ({ id, received, visibility: 'visible' as const, ...request && { request } });
  const legs = latency([
    { t: 0, bytes: 0, clockError: 0, frame: 40, stages: stages(1, 2, { at: 5, fired: 30 }) },
    { t: 100, bytes: 0, clockError: 0, frame: 110, stages: stages(2, 101) },
    { t: 200, bytes: 0, clockError: 0, applied: 201 },
  ]);
  assert.deepEqual([legs.writeToReceive.count, legs.writeToReceive.max, legs.receiveToRequest.max, legs.requestToRaf.max, legs.rafToDone.max, legs.timer], [2, 2, 3, 25, 10, 1]);
  assert.deepEqual(legs.worst.map(leg => [leg.id, leg.total]), [[1, 40], [2, 10]]);
});

test('the metrics request validates flush stages', () => {
  const sample = { t: 1, frame: 2, bytes: 3, clockError: 0 };
  const accepts = (stages: object) => metricsRequest({ samples: [{ ...sample, stages }], observations: [{ type: 'markdown', at: 1, words: 5, lex: .5, fallbacks: 0 }] }) !== undefined;
  assert.equal(accepts({ id: 1, received: 2, visibility: 'hidden', request: { at: 1, fired: 2 } }), true);
  for (const bad of [{ id: 1.5, received: 2, visibility: 'hidden' }, { id: 1, received: 2, visibility: 'prerender' }, { id: 1, received: 2, visibility: 'hidden', request: { at: 1 } }]) assert.equal(accepts(bad), false);
});

test('dots phases follow where the dots sit before and after a removal', () => {
  assert.deepEqual([dotsPhase('row', 'row'), dotsPhase('row', 'step'), dotsPhase('step', 'row'), dotsPhase(undefined, 'row'), dotsPhase('row', undefined)], ['text', 'call', 'call', 'text', 'end']);
});

test('the metrics request refuses an unknown or incomplete observation', () => {
  const frame = { type: 'frame', at: 1, duration: 2, lex: 0, strays: 0, by: {} };
  const sample = { t: 1, frame: 2, bytes: 3, clockError: 0 };
  const accepts = (observation: object) => metricsRequest({ samples: [sample], observations: [observation] }) !== undefined;
  assert.equal(accepts(frame), true);
  assert.equal(accepts({ type: 'dots', at: 1, phase: 'end', count: 1 }), true);
  for (const bad of [{ ...frame, duration: undefined }, { ...frame, strays: 1.5, by: {} }, { ...frame, gap: 'x' }, { type: 'key', at: 1 }, { type: 'dots', at: 1, phase: 'later', count: 1 }, { type: 'dots', at: 1, phase: 'call' }, { type: 'stray' }, { type: 'bogus', at: 1 }]) assert.equal(accepts(bad), false);
  assert.equal(metricsRequest([sample]), undefined);
  assert.equal(metricsRequest({ samples: [sample], observations: Array(201).fill(frame) }), undefined);
});
