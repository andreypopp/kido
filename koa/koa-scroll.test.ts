import assert from 'node:assert/strict';
import { test } from 'node:test';
import { scrollInitial, scrollMemory, scrollStored, scrollUpdate, type State, type ScrollEvent, type Measure, type Row, type ItemId, type Lookup } from './page/scroll.ts';

const scope = { view: 'root', sessionId: 's' };
const row = (seq: number, top: number, bottom = top + 100): Row => ({ item: { kind: 'message', seq }, top, bottom });
type FixtureMeasure = Omit<Measure, 'lookup'> & { rows: readonly Row[]; loaded: readonly ItemId[]; mounted?: readonly ItemId[]; more: boolean };
const same = (a: ItemId, b: ItemId) => a.kind === b.kind && (a.kind === 'message' ? b.kind === 'message' && a.seq === b.seq : b.kind === 'job' && a.byte === b.byte);
function fixture() {
  let state: State = scrollInitial(scope);
  let measurement: FixtureMeasure = { now: 1000, top: 900, max: 900, viewport: 300, width: 700, dock: 250, origin: 0, focused: true, visible: true, reducedMotion: false, rows: [row(0, 0), row(1, 100)], loaded: [{ kind: 'message', seq: 0 }, { kind: 'message', seq: 1 }], more: false, anchor: { item: { kind: 'message', seq: 0 }, edge: 'row', offset: -900 } };
  const step = (events: ScrollEvent[] = [], changes: Partial<FixtureMeasure> = {}) => {
    measurement = { ...measurement, ...changes };
    const result = scrollUpdate(state, events, {
      ...measurement,
      lookup(item): Lookup {
        const row = measurement.rows.find(row => same(row.item, item));
        if (row) return { kind: !measurement.mounted || measurement.mounted.some(found => same(found, item)) ? 'mounted' : 'unmounted', row };
        if (measurement.loaded.some(found => same(found, item))) return { kind: 'unmounted', row: { item, top: 0, bottom: 0 } };
        return measurement.more ? { kind: 'unloaded' } : { kind: 'removed' };
      },
    });
    state = result.state;
    if (result.decision.scrollTop !== undefined) {
      measurement.top = result.decision.scrollTop;
      state = scrollStored(state, measurement.top);
    }
    return result;
  };
  step();
  return { step, state: () => state, store: (top: number) => { state = scrollStored(state, top); measurement.top = top; } };
}
test('scope switches retain the restored topic filter mode', () => {
  const f = fixture();
  const event = { type: 'switch' as const, loaded: false, scope: { view: 'other', sessionId: 's' }, filtered: true };
  assert.equal(f.step([event]).state.filtered, true);
});

test('filter switches follow the new bottom without keeping the previous reader anchor', () => {
  const f = fixture();
  f.step([intent], { top: 400, anchor: { item: { kind: 'message', seq: 1 }, edge: 'row', offset: -300 } });
  const result = f.step([{ type: 'filter', active: true, topic: 'new' }, item(20, true, false)], { max: 1200, rows: [row(20, 1100)], loaded: [{ kind: 'message', seq: 20 }] });
  assert.deepEqual([result.state.kind,result.decision.scrollTop,result.decision.divider?.seq], ['following',1200,undefined]);
});

test('filter switches position at the first visible unread row and show its divider', () => {
  const f = fixture();
  f.step([intent,item(10)], { top: 100, rows: [row(1,100),row(10,700)], loaded: [{kind:'message',seq:1},{kind:'message',seq:10}], anchor: {item:{kind:'message',seq:1},edge: 'row', offset:0} });
  const result = f.step([{type:'filter',active:true,topic:'first'},item(10,true,false)], { rows: [{...row(10,700),leading:650}] });
  assert.deepEqual([result.state.kind,result.decision.scrollTop,result.decision.divider?.seq,result.decision.latest], ['reader',650,10,{show:true,count:0}]);
});

test('seeing a later row under one filter does not mark another filters hidden unread row seen', () => {
  const f = fixture();
  f.step([intent,item(10)], {top:100,rows:[row(1,100),row(10,700)],loaded:[{kind:'message',seq:1},{kind:'message',seq:10}],anchor:{item:{kind:'message',seq:1},edge: 'row', offset:0}});
  f.step([{type:'filter',active:true,topic:'second'},item(20,true,false)], {rows:[row(20,800)],loaded:[{kind:'message',seq:20}]});
  const result = f.step([{type:'filter',active:true,topic:'first'},item(10,true,false)], {rows:[row(10,500)],loaded:[{kind:'message',seq:10}]});
  assert.deepEqual([result.state.kind,result.decision.scrollTop,result.decision.divider?.seq], ['reader',500,10]);
});

test('scrolling a normal view keeps its existing unread divider and offscreen count', () => {
  const f = fixture();
  f.step([intent,item(10)], {top:100,rows:[row(1,100),row(10,600)],loaded:[{kind:'message',seq:1},{kind:'message',seq:10}],anchor:{item:{kind:'message',seq:1},offset:0,edge:'row'}});
  const result=f.step([scroll], {top:550,anchor:{item:{kind:'message',seq:10},offset:50,edge:'row'}});
  assert.deepEqual([result.decision.divider?.seq,result.decision.latest], [10,{show:true,count:0}]);
});

test('hidden arrivals and reply sections stay unread when switching to their topic or all topics', () => {
  for (const active of [true,false]) for (const section of [false,true]) {
    const f = fixture();
    f.step([{type:'filter',active:true,topic:'initial'}]);
    if (section) f.step([{type:'item',seq:10,kind:'assistant',visible:true,appended:false,rows:[{row:{kind:'text' as const,source:{kind:'block' as const,seq:10,index:0}},visible:true}]}]);
    f.step([{type:'item',seq:10,kind:'assistant',visible:section,appended:!section,rows:[...(section?[{row:{kind:'text' as const,source:{kind:'block' as const,seq:10,index:0}},visible:true}]:[]),{row:{kind:'text' as const,source:{kind:'block' as const,seq:10,index:1}},visible:false}]}]);
    const result=f.step([{type:'filter',active,topic:active?'other':undefined},{type:'item',seq:10,kind:'assistant',visible:true,appended:false,rows:[{row:{kind:'text' as const,source:{kind:'block' as const,seq:10,index:1}},visible:true}]}], {rows:[{item:{kind:'message',seq:10,row:{kind:'text',source:{kind:'block',seq:10,index:1}}},top:500,bottom:600}],loaded:[{kind:'message',seq:10}]});
    assert.deepEqual([result.state.kind,result.decision.divider?.seq,result.decision.divider?.row,result.decision.scrollTop], active ? ['reader',10,{kind:'text',source:{kind:'block',seq:10,index:1}},500] : ['following',undefined,undefined,900]);
  }
});

test('view memory restores readers, records following and rejects another session', () => {
  const f = fixture();
  f.step([intent, item(7)], { top: 500, anchor: { item: { kind: 'message', seq: 1 }, edge: 'row', offset: -400 } });
  const memory = scrollMemory(f.state());
  assert.deepEqual(memory, [{ scope, anchor: { item: { kind: 'message' as const, seq: 1 }, edge: 'row' as const, offset: -400 }, last: 7 }]);
  const m: Measure = { now: 1000, top: 0, max: 900, viewport: 300, width: 700, dock: 250, origin: 0, focused: true, visible: true, reducedMotion: true, lookup: () => ({ kind: 'unloaded' }) };
  const restored = scrollUpdate(scrollInitial({ view: '', sessionId: undefined }, memory), [{ type: 'switch', filtered: false, loaded: false, scope }], m);
  assert.equal(restored.state.kind, 'restoring');
  if (restored.state.kind === 'restoring') assert.deepEqual(restored.state.target, memory[0]);
  const missing = scrollUpdate(restored.state, [{ type: 'reset' }, { type: 'frame' }], { ...m, lookup: () => ({ kind: 'removed' }) });
  assert.equal(missing.state.kind, 'following');
  assert.equal(missing.decision.scrollTop, 900);
  assert.equal(scrollUpdate(scrollInitial({ view: '', sessionId: undefined }, memory), [{ type: 'switch', filtered: false, loaded: false, scope: { ...scope, sessionId: 'other' } }], m).state.kind, 'following');
  assert.deepEqual(scrollMemory(fixture().state()), [{ scope, last: -1 }]);
  assert.deepEqual(scrollMemory({ ...f.state(), kind: 'following' }), [{ scope, last: 7 }]);
  const current = memory[0];
  assert.ok(current && 'anchor' in current);
  const other = { ...current, scope: { view: 'other', sessionId: 's' } };
  const travelling: State = { ...f.state(), kind: 'reader', anchor: current.anchor, travel: { from: 500, start: 1000 }, saved: new Map([[JSON.stringify([scope.view, null]), current], [JSON.stringify(['other', null]), other]]) };
  assert.deepEqual(scrollMemory(travelling), [{ scope, last: 7 }, other]);
});

test('following memory waits for non-empty positioning before background growth becomes reader', () => {
  const memory = scrollMemory(fixture().state());
  const m: Measure = { now: 1000, top: 0, max: 0, viewport: 300, width: 700, dock: 250, origin: 0, focused: false, visible: true, reducedMotion: true, lookup: () => ({ kind: 'removed' }) };
  let result = scrollUpdate(scrollInitial({ view: '', sessionId: undefined }, memory), [{ type: 'switch', filtered: false, loaded: false, scope }, { type: 'reset' }], m);
  result = scrollUpdate(result.state, [layout], { ...m, max: 900 });
  assert.equal(result.state.kind, 'following');
  assert.equal(result.decision.scrollTop, 900);
  result = scrollUpdate(scrollStored(result.state, 900), [{ type: 'focus' }], { ...m, top: 900, max: 900, focused: true });
  assert.equal(result.state.kind, 'following');
  result = scrollUpdate(result.state, [layout], { ...m, top: 900, max: 1000 });
  assert.equal(result.state.kind, 'reader');
});

test('background reset waits for new layout rather than completing against old content', () => {
  const f = fixture();
  f.step([{ type: 'reset' }], { focused: false, top: 500, max: 500 });
  const placed = f.step([layout], { max: 900 });
  assert.equal(placed.state.kind, 'following');
  assert.equal(placed.decision.scrollTop, 900);
  const growth = f.step([layout], { max: 1000 });
  assert.equal(growth.state.kind, 'reader');
  assert.equal(growth.decision.scrollTop, undefined);
});

test('completed Latest travel does not retain positioning intent during background growth', () => {
  const f = fixture();
  f.step([intent], { top: 500 });
  f.step([{ type: 'latest' }]);
  const placed = f.step([{ type: 'frame' }], { now: 1300 });
  assert.equal(placed.state.kind, 'following');
  assert.equal(placed.decision.scrollTop, 900);
  const growth = f.step([layout], { focused: false, max: 1000 });
  assert.equal(growth.state.kind, 'reader');
  assert.equal(growth.decision.scrollTop, undefined);
});

test('reader input cancels initial positioning even at an empty bottom', () => {
  const m: Measure = { now: 1000, top: 0, max: 0, viewport: 300, width: 700, dock: 250, origin: 0, focused: false, visible: true, reducedMotion: true, lookup: () => ({ kind: 'removed' }) };
  const cancelled = scrollUpdate(scrollInitial(scope), [intent], m);
  assert.equal(cancelled.state.kind, 'following');
  assert.ok(cancelled.state.kind === 'following' && !cancelled.state.positioning);
  const result = scrollUpdate(cancelled.state, [layout], { ...m, max: 900 });
  assert.equal(result.state.kind, 'reader');
  assert.equal(result.decision.scrollTop, undefined);
});

test('a toggle holds its anchor, cancels travel and glide, and follows only at the bottom', () => {
  for (const mode of ['following', 'glide', 'reader', 'travel'] as const) {
    const f = fixture();
    if (mode === 'glide') { f.step([layout], { max: 1000 }); f.store(900); }
    if (mode === 'reader' || mode === 'travel') f.step([intent]);
    if (mode === 'travel') f.step([{ type: 'latest' }]);
    const result = f.step([{ type: 'layout', cause: 'toggle', anchor: { item: { kind: 'message', seq: 1 }, edge: 'row', offset: -800 } }], { max: 1200 });
    assert.equal(result.decision.scrollTop ?? 900, 900);
    assert.equal(result.state.kind, 'reader');
    assert.equal(result.decision.glideOffset, 0);
    assert.equal(result.decision.divider?.seq, undefined);
    assert.equal(f.step([{ type: 'frame' }], { now: 1100 }).decision.scrollTop, undefined);
  }
  const clamped = fixture().step([{ type: 'layout', cause: 'toggle', anchor: { item: { kind: 'message', seq: 1 }, edge: 'row', offset: 200 } }]);
  assert.equal(clamped.decision.scrollTop, 0);
  const fractional = fixture();
  const held = fractional.step([{ type: 'layout', cause: 'toggle', anchor: { item: { kind: 'message', seq: 1 }, edge: 'row', offset: -799.5 } }]);
  assert.equal(held.decision.scrollTop, 899.5);
  assert.equal(held.state.kind, 'reader');
  const f = fixture();
  const result = f.step([{ type: 'layout', cause: 'toggle', anchor: { item: { kind: 'message', seq: 1 }, edge: 'row', offset: -800 } }], { max: 800, top: 800 });
  assert.equal(result.state.kind, 'following');
  assert.equal(result.decision.scrollTop, 800);
  assert.equal(result.decision.glideOffset, 0);
});

const layout: ScrollEvent = { type: 'layout', cause: 'layout' };
const intent: ScrollEvent = { type: 'input', direction: 'up' };
const scroll: ScrollEvent = { type: 'scroll' };
const item = (seq: number, visible = true, appended = true): ScrollEvent => ({ type: 'item', seq, kind: 'assistant', visible, appended });

test('fractional bottom rounding still follows and writes the bottom', () => {
  const f = fixture();
  const result = f.step([scroll], { top: 900.5 });
  assert.equal(result.state.kind, 'following');
  assert.equal(result.decision.scrollTop, 900);
});

test('elastic measurements never write or change follow state or its geometry', () => {
  for (const mode of ['following', 'reader', 'travel'] as const) for (const top of [-40, 940]) {
    const f = fixture();
    if (mode !== 'following') f.step([intent], { top: 0 });
    if (mode === 'travel') f.step([{ type: 'latest' }]);
    const before = f.state();
    const batches: ScrollEvent[][] = [[scroll], [intent, scroll], [layout], [{ type: 'resize' }], [{ type: 'frame' }]];
    for (const events of batches) {
      const result = f.step(events, { top, width: 650, now: 1001 });
      assert.equal(result.decision.scrollTop, undefined, `${mode} at ${top}: ${events[0]?.type}`);
      assert.equal(result.state.kind, before.kind);
      assert.deepEqual(result.state.last, before.last);
      if (result.state.kind === 'reader' && before.kind === 'reader') assert.deepEqual(result.state.anchor, before.anchor);
    }
    const rebound = f.step([scroll], { top: mode === 'following' ? 900 : 0, width: 700, now: 1002 });
    assert.equal(rebound.state.kind, before.kind);
  }
});

test('focused following writes each current measured bottom, including deferred layout and shrink/regrowth', () => {
  const f = fixture();
  for (const max of [1000, 1300, 800, 1400]) {
    const result = f.step([layout], { max, ...(max === 800 ? { top: 800 } : {}) });
    assert.equal(result.state.kind, 'following');
    assert.equal(result.decision.scrollTop, max);
  }
  assert.equal(f.step([{ type: 'frame' }], { max: 1700 }).decision.scrollTop, 1700);
});

test('a scroll of any size above the bottom leaves following, a clamp does not, and a move down to the bottom follows again', () => {
  const f = fixture();
  const clamp = f.step([scroll], { top: 700, max: 700 });
  assert.deepEqual([clamp.state.kind, clamp.decision.scrollTop], ['following', 700]);
  f.step([layout], { max: 900 });
  const read = f.step([scroll], { top: 899.5, anchor: { item: { kind: 'message', seq: 1 }, edge: 'row', offset: -799.5 } });
  assert.deepEqual([read.state.kind, read.decision.scrollTop], ['reader', undefined]);
  assert.equal(f.step([scroll], { top: 899.8 }).state.kind, 'following');
});

test('a reader sub-pixel scroll moves the anchor and is never written back', () => {
  const f = fixture();
  f.step([intent, scroll], { top: 500, anchor: { item: { kind: 'message', seq: 1 }, edge: 'row', offset: -400 } });
  for (const top of [500.4, 500.8, 501.2, 501.6, 502]) {
    const anchor = { item: { kind: 'message', seq: 1 }, edge: 'row', offset: 100 - top } as const;
    const result = f.step([scroll], { top, anchor });
    assert.equal(result.decision.scrollTop, undefined, `scroll to ${top}`);
    assert.deepEqual(result.state.kind === 'reader' && result.state.anchor, anchor);
  }
  assert.equal(f.step([{ type: 'frame' }]).decision.scrollTop, undefined);
});

test('up input without scroll range keeps following and adds no unread divider', () => {
  const f = fixture();
  f.step([layout], { top: 0, max: 0 });
  f.step([intent]);
  const result = f.step([item(2)]);
  assert.deepEqual([result.state.kind, result.decision.divider?.seq], ['following', undefined]);
});

test('a slow wheel up from the bottom leaves following, and its sub-pixel scrolls never snap back', () => {
  const f = fixture();
  f.step([intent]);
  for (const top of [899.6, 899.2, 898.8]) {
    const result = f.step([scroll], { top, anchor: { item: { kind: 'message', seq: 1 }, edge: 'row', offset: 100 - top } });
    assert.deepEqual([result.state.kind, result.decision.scrollTop], ['reader', undefined], `scroll to ${top}`);
  }
  assert.equal(f.step([{ type: 'frame' }]).decision.scrollTop, undefined);
});

test('a layout during reader input keeps the movement that the reader made after the last scroll event', () => {
  const f = fixture();
  f.step([intent, scroll], { top: 100, anchor: { item: { kind: 'message', seq: 1 }, edge: 'row', offset: 0 } });
  const result = f.step([layout], { top: 120, rows: [row(1, 150)], max: 1000 });
  assert.equal(result.decision.scrollTop, 170);
  assert.deepEqual(result.state.kind === 'reader' && result.state.anchor, { item: { kind: 'message', seq: 1 }, edge: 'row', offset: -20 });
});

test('a scroll below the last written frame cancels Latest, its echo does not', () => {
  const f = fixture();
  f.step([intent, scroll], { top: 100, anchor: { item: { kind: 'message', seq: 1 }, edge: 'row', offset: 0 } });
  f.step([{ type: 'latest' }]);
  const frame = f.step([{ type: 'frame' }], { now: 1125 }).decision.scrollTop ?? 0;
  const echo = f.step([scroll]).state;
  assert.ok(echo.kind === 'reader' && echo.travel);
  const cancel = f.step([scroll], { top: frame - 0.5, anchor: { item: { kind: 'message', seq: 1 }, edge: 'row', offset: 100.5 - frame } });
  assert.deepEqual([cancel.state.kind === 'reader' && cancel.state.travel, cancel.decision.scrollTop, cancel.decision.frame], [undefined, undefined, 'none']);
});

test('the echo of a write that the browser rounded is not a reader move', () => {
  const f = fixture();
  f.step([intent, scroll], { top: 100, anchor: { item: { kind: 'message', seq: 1 }, edge: 'row', offset: 0 } });
  assert.equal(f.step([layout], { rows: [row(1, 350.4)], max: 1150 }).decision.scrollTop, 350.4);
  f.store(350);
  f.step([scroll], { rows: [row(1, 380.4)], anchor: { item: { kind: 'message', seq: 0 }, edge: 'row', offset: -350 } });
  assert.equal(f.step([layout]).decision.scrollTop, 380.4);
});

test('a scroll below the bottom leaves following and below the last travel frame cancels Latest, also with a layout in the same batch', () => {
  const f = fixture();
  const read = f.step([layout, scroll], { top: 850, anchor: { item: { kind: 'message', seq: 1 }, edge: 'row', offset: -750 } });
  assert.deepEqual([read.state.kind, read.decision.scrollTop], ['reader', undefined]);
  f.step([{ type: 'latest' }]);
  const frame = f.step([{ type: 'frame' }], { now: 1125 }).decision.scrollTop ?? 0;
  const cancel = f.step([layout, scroll], { top: frame - 0.5, anchor: { item: { kind: 'message', seq: 1 }, edge: 'row', offset: 100.5 - frame } });
  assert.deepEqual([cancel.state.kind === 'reader' && cancel.state.travel, cancel.decision.scrollTop], [undefined, undefined]);
});

test('a clamp to a fractional position at the shrunk bottom is no move in reader or following', () => {
  const following = fixture();
  const kept = following.step([scroll], { top: 699.6, max: 700 });
  assert.deepEqual([kept.state.kind, kept.decision.scrollTop], ['following', 700]);
  const f = fixture();
  f.step([intent, scroll], { top: 650, rows: [row(1, 650)], anchor: { item: { kind: 'message', seq: 1 }, edge: 'row', offset: 0 } });
  f.step([scroll], { top: 299.6, max: 300, anchor: { item: { kind: 'message', seq: 0 }, edge: 'row', offset: -299.6 } });
  assert.equal(f.step([layout], { max: 1450 }).decision.scrollTop, 650);
});

test('reader preserves anchor through images, folds, prepend, clamped shrink and regrowth', () => {
  const f = fixture();
  f.step([intent, scroll], { top: 100, anchor: { item: { kind: 'message', seq: 1 }, edge: 'row', offset: 0 } });
  assert.equal(f.step([layout], { rows: [row(1, 350)], max: 1150 }).decision.scrollTop, 350);
  assert.equal(f.step([{ type: 'history' }], { rows: [row(1, 650)], max: 1450 }).decision.scrollTop, 650);
  assert.equal(f.step([layout, scroll], { rows: [row(1, 650)], max: 300, top: 300 }).decision.scrollTop, undefined);
  assert.equal(f.step([layout], { rows: [row(1, 650)], max: 1450 }).decision.scrollTop, 650);
});

test('a delayed scroll for the last accepted reader position cannot replace its anchor after prepend', () => {
  const f = fixture();
  f.step([intent, scroll], { top: 100, anchor: { item: { kind: 'message', seq: 1 }, edge: 'row', offset: 0 } });
  const result = f.step([{ type: 'history' }, scroll], { rows: [row(1, 300)], anchor: { item: { kind: 'message', seq: 0 }, edge: 'row', offset: 0 } });
  assert.equal(result.decision.scrollTop, 300);
});

test('reader movement while history loads replaces the old anchor', () => {
  const f = fixture();
  f.step([intent, scroll], { top: 100, anchor: { item: { kind: 'message', seq: 1 }, edge: 'row', offset: 0 } });
  f.step([intent, scroll], { top: 180, anchor: { item: { kind: 'message', seq: 1 }, edge: 'row', offset: -80 } });
  assert.equal(f.step([{ type: 'history' }], { rows: [row(1, 400)], max: 1200 }).decision.scrollTop, 480);
});

test('unfocused growth becomes reader; focus alone cannot follow; first arrival makes an unread divider', () => {
  const f = fixture();
  const background = f.step([layout], { focused: false, max: 1000 });
  assert.equal(background.state.kind, 'reader');
  assert.equal(background.decision.scrollTop, undefined);
  const fresh = f.step([item(2)], { rows: [row(0, 0), row(1, 100), row(2, 1200)] });
  assert.deepEqual([fresh.decision.divider?.seq, fresh.decision.latest.count], [2, 1]);
  assert.equal(f.step([{ type: 'focus' }], { focused: true }).state.kind, 'reader');
});

test('Enter follows from every prior mode after background growth and from a delayed composer clamp', () => {
  const f = fixture();
  f.step([{ type: 'submit' }]);
  assert.equal(f.step([layout], { focused: false, max: 1000 }).state.kind, 'reader');
  const sent: ScrollEvent = { type: 'item', seq: 2, kind: 'user', visible: true, appended: true };
  const appended = f.step([sent], { max: 1300, rows: [row(2, 1200)], loaded: [{ kind: 'message', seq: 2 }] });
  assert.deepEqual([appended.state.kind, appended.decision.scrollTop, appended.decision.divider?.seq], ['following', 1300, undefined]);
  f.step([{ type: 'submit' }], { focused: true });
  assert.equal(f.step([sent, scroll], { top: 1200, max: 1500 }).decision.scrollTop, 1500);
});

test('queued and started sends follow immediately; handled, failed and switched sends forget pending correlation', () => {
  for (const result of ['queued', 'started'] as const) {
    const f = fixture(); f.step([intent]);
    assert.equal(f.step([{ type: 'send-result', result }], { focused: false }).decision.scrollTop, 900);
  }
  for (const result of ['handled', 'failed'] as const) {
    const f = fixture(); f.step([{ type: 'submit' }, { type: 'send-result', result }, intent]);
    assert.equal(f.step([{ type: 'item', seq: 2, kind: 'user', visible: true, appended: true }]).state.kind, 'reader');
  }
  const f = fixture(); f.step([{ type: 'submit' }, { type: 'switch', filtered: false, loaded: false, scope: { view: 'other', sessionId: 's' } }]);
  assert.equal(f.state().pendingSend, undefined);
});

test('unread eligibility is data input, counts once after empty growth, and can disappear', () => {
  const f = fixture();
  f.step([intent, scroll], { top: 100, anchor: { item: { kind: 'message', seq: 1 }, edge: 'row', offset: 0 }, rows: [row(1, 100), row(2, 600), row(3, 700)] });
  assert.equal(f.step([item(2, false)]).decision.latest.count, 0);
  assert.equal(f.step([item(2, true, false)]).decision.latest.count, 1);
  assert.equal(f.step([item(2, true, false), item(3)]).decision.latest.count, 2);
  assert.deepEqual(f.step([item(2, false, false)]).decision.latest, { show: true, count: 1 });
  assert.equal(f.step([item(2, true, false)]).decision.latest.count, 2);
  assert.equal(f.step([{ type: 'item', seq: 4, kind: 'other', visible: true, appended: true }]).decision.latest.count, 2);
});

test('Latest hysteresis uses one third and one quarter, unread overrides it, and send/reset clears', () => {
  const f = fixture();
  const move = (top: number) => f.step([intent, scroll], { top, anchor: undefined, rows: [row(2, 1300)] });
  assert.equal(move(799).decision.latest.show, true);
  assert.equal(move(810).decision.latest.show, true);
  assert.equal(move(826).decision.latest.show, false);
  assert.equal(move(810).decision.latest.show, false);
  assert.equal(f.step([item(2)]).decision.latest.show, true);
  assert.equal(f.step([{ type: 'submit' }]).decision.latest.show, false);
  f.step([intent, item(2)]);
  assert.equal(f.step([{ type: 'reset' }]).decision.divider?.seq, undefined);
});

test('Latest travel retargets the moving bottom, is interrupted by intent, and completes without glide', () => {
  const f = fixture();
  f.step([intent, scroll], { top: 100, anchor: undefined });
  const start = f.step([{ type: 'latest' }]);
  assert.equal(start.state.kind, 'reader');
  assert.equal(f.step([{ type: 'frame' }], { now: 1125, max: 1000 }).decision.scrollTop, 887.5);
  assert.equal(f.step([intent], { now: 1130 }).decision.frame, 'none');
  f.step([{ type: 'latest' }], { now: 1200 });
  const end = f.step([{ type: 'frame' }], { now: 1450, max: 1200 });
  assert.deepEqual([end.state.kind, end.decision.scrollTop, end.decision.glideOffset], ['following', 1200, 0]);
  f.step([intent]);
  assert.equal(f.step([{ type: 'latest' }], { reducedMotion: true }).decision.scrollTop, 1200);
});

test('either input direction cancels Latest at the current measured anchor', () => {
  for (const direction of ['up', 'down'] satisfies ('up' | 'down')[]) {
    const f = fixture();
    f.step([intent, scroll], { top: 100, anchor: undefined });
    f.step([{ type: 'latest' }]);
    f.step([{ type: 'frame' }], { now: 1125 });
    const result = f.step([{ type: 'input', direction }], { rows: [row(5, 780)], anchor: { item: { kind: 'message', seq: 5 }, edge: 'row', offset: -20 } });
    assert.deepEqual(result.state.kind === 'reader' && result.state.anchor, { item: { kind: 'message', seq: 5 }, edge: 'row', offset: -20 });
    assert.equal(result.decision.frame, 'none');
  }
});

test('hiding or leaving Latest saves the anchor at the intermediate position', () => {
  for (const event of [{ type: 'visibility' }, { type: 'switch', filtered: false, loaded: false, scope: { view: 'child', sessionId: 'c' } }] satisfies ScrollEvent[]) {
    const f = fixture();
    f.step([intent, scroll], { top: 100, anchor: undefined });
    f.step([{ type: 'latest' }]);
    f.step([{ type: 'frame' }], { now: 1125 });
    const current = { item: { kind: 'message', seq: 5 }, edge: 'row', offset: -20 } satisfies import('./page/scroll.ts').Anchor;
    const result = f.step([event], { visible: event.type !== 'visibility', rows: [row(5, 780)], anchor: current });
    const saved = result.state.saved.get(JSON.stringify(['root', null]));
    assert.deepEqual(event.type === 'switch' ? saved && 'anchor' in saved && saved.anchor : result.state.kind === 'reader' && result.state.anchor, current);
  }
});

test('an animation frame reuses maps and mutation leaves the previous state unchanged', () => {
  const f = fixture();
  const before = f.state();
  const animated = f.step([{ type: 'frame' }], { now: 1050 }).state;
  assert.equal(animated.candidates, before.candidates);
  assert.equal(animated.saved, before.saved);
  const changed = f.step([intent, item(2)], { rows: [row(2, 1200)] }).state;
  assert.notEqual(changed.candidates, animated.candidates);
  assert.equal(animated.candidates.has(2), false);
});

test('glide uses signed measured bottom deltas, retargets current offset, and repeated geometry adds nothing', () => {
  const f = fixture();
  assert.equal(f.step([layout], { max: 1000 }).decision.glideOffset, 100);
  assert.equal(f.step([layout]).decision.glideOffset, 100);
  const half = f.step([{ type: 'frame' }], { now: 1090 }).decision.glideOffset;
  assert.ok(half > 30 && half < 32);
  const next = f.step([layout], { max: 1020 });
  assert.ok(Math.abs(next.decision.glideOffset - half - 20) < 0.001);
  assert.equal(next.decision.scrollTop, 1020);
  assert.equal(f.step([layout], { max: 3000 }).decision.glideOffset, 300);
  assert.equal(f.step([layout], { max: 900, top: 900 }).decision.glideOffset, -300);
});

test('glide exclusions clear the transform and first paint is a baseline', () => {
  for (const event of [{ type: 'reset' }, { type: 'history' }, { type: 'resize' }, { type: 'input', direction: 'up' }, { type: 'layout', cause: 'instant' }] satisfies ScrollEvent[]) {
    const f = fixture(); f.step([layout], { max: 1000 });
    assert.equal(f.step([event], { max: 1200 }).decision.glideOffset, 0);
  }
  for (const change of [{ reducedMotion: true }, { focused: false }, { visible: false }, { width: 800 }, { viewport: 400 }]) {
    const f = fixture(); f.step([layout], { max: 1000 });
    assert.equal(f.step([layout], { max: 1200, ...change }).decision.glideOffset, 0);
  }
  assert.equal(scrollUpdate(scrollInitial(scope), [layout], { now: 0, top: 0, max: 900, viewport: 300, width: 700, dock: 250, origin: 0, focused: true, visible: true, reducedMotion: false, lookup: () => ({ kind: 'removed' }) }).decision.glideOffset, 0);
});

test('an instant batch stays instant through repeated deliveries and its correction frame, then ordinary growth glides', () => {
  const f = fixture();
  assert.equal(f.step([{ type: 'layout', cause: 'instant' }], { max: 1000 }).decision.glideOffset, 0);
  assert.equal(f.step([layout], { max: 1200 }).decision.glideOffset, 0);
  assert.equal(f.step([layout], { max: 1300, rows: [row(1, 250)] }).decision.glideOffset, 0);
  assert.equal(f.step([{ type: 'frame' }]).decision.glideOffset, 0);
  assert.equal(f.step([layout], { max: 1350 }).decision.glideOffset, 50);
});

test('reader send slides only the sent row height, not the distance jumped', () => {
  const f = fixture();
  f.step([intent, scroll], { top: 100, anchor: undefined });
  f.step([{ type: 'submit' }]);
  assert.equal(f.step([{ type: 'item', seq: 2, kind: 'user', visible: true, appended: true }], { max: 1100, rows: [row(2, 1050, 1100)] }).decision.glideOffset, 50);
});

test('a reader send keeps its force until the actual row is mounted and glides only its measured height', () => {
  const f = fixture();
  f.step([intent, scroll], { top: 100, anchor: undefined });
  f.step([{ type: 'submit' }]);
  const beforeMount = f.step([{ type: 'item', seq: 2, kind: 'user', visible: true, appended: true }], { focused: false, max: 1100, rows: [row(2, 1000, 1030)], loaded: [{ kind: 'message', seq: 2 }], mounted: [] });
  assert.deepEqual([beforeMount.decision.scrollTop, beforeMount.decision.glideOffset, beforeMount.state.forceItem?.seq], [1100, 0, 2]);
  const mounted = f.step([{ type: 'frame' }], { focused: true, max: 1200, rows: [row(2, 1100, 1150)], mounted: [{ kind: 'message', seq: 2 }] });
  assert.deepEqual([mounted.decision.scrollTop, mounted.decision.glideOffset, mounted.state.forceItem], [1200, 50, undefined]);
});

test('view return restores reader instantly with away arrivals, but a followed view returns at bottom', () => {
  const f = fixture();
  f.step([intent, scroll], { top: 100, anchor: { item: { kind: 'message', seq: 1 }, edge: 'row', offset: 0 } });
  f.step([{ type: 'switch', filtered: false, loaded: false, scope: { view: 'child', sessionId: 'c' } }]);
  f.step([{ type: 'reset' }], { top: 0, max: 500, loaded: [], rows: [] });
  f.step([{ type: 'switch', filtered: false, loaded: false, scope }]);
  const restored = f.step([{ type: 'reset' }, item(2, true, false)], { loaded: [{ kind: 'message', seq: 1 }, { kind: 'message', seq: 2 }], rows: [row(1, 100), row(2, 700)], max: 900 });
  assert.deepEqual([restored.state.kind, restored.decision.scrollTop, restored.decision.divider?.seq, restored.decision.glideOffset], ['reader', 100, 2, 0]);
  f.step([{ type: 'switch', filtered: false, loaded: false, scope: { view: 'child', sessionId: 'c' } }]);
  assert.equal(f.step([{ type: 'reset' }], { max: 1500 }).decision.scrollTop, 1500);
});

test('restore requests unloaded anchors, mounts loaded anchors, rejects stale completions and falls back on failure', () => {
  const f = fixture();
  f.step([intent, scroll], { top: 100, anchor: { item: { kind: 'message', seq: 1 }, edge: 'row', offset: 0 } });
  f.step([{ type: 'switch', filtered: false, loaded: false, scope: { view: 'child', sessionId: 'c' } }, { type: 'switch', filtered: false, loaded: false, scope }]);
  const waiting = f.step([{ type: 'reset' }], { loaded: [], rows: [], more: true });
  assert.deepEqual(waiting.decision.request, { type: 'load', item: { kind: 'message', seq: 1 }, generation: 2 });
  assert.equal(f.step([{ type: 'restore-result', generation: 1, found: false }]).state.kind, 'restoring');
  assert.equal(f.step([{ type: 'restore-result', generation: 2, found: true }], { loaded: [{ kind: 'message', seq: 1 }] }).decision.request?.type, 'mount');
  const missing = fixture();
  missing.step([intent, scroll], { top: 100, anchor: { item: { kind: 'message', seq: 1 }, edge: 'row', offset: 0 } });
  missing.step([{ type: 'switch', filtered: false, loaded: false, scope: { view: 'child', sessionId: 'c' } }, { type: 'switch', filtered: false, loaded: false, scope }]);
  missing.step([{ type: 'reset' }], { loaded: [], rows: [], more: true });
  assert.equal(missing.step([{ type: 'restore-result', generation: 2, found: false }]).state.kind, 'following');
});

test('virtualization uses the new table anchor before prepend renders and uses the intermediate Latest position', () => {
  const f = fixture();
  f.step([intent, scroll], { top: 100, anchor: { item: { kind: 'message', seq: 1 }, edge: 'row', offset: 0 } });
  const prepend = f.step([{ type: 'history' }], { rows: [{ ...row(1, 100), windowTop: 600 }] });
  assert.deepEqual([prepend.decision.scrollTop, prepend.decision.windowTop], [undefined, 600]);
  f.step([{ type: 'latest' }]);
  assert.equal(f.step([{ type: 'frame' }], { now: 1125 }).decision.windowTop, 800);
});

test('job byte anchors use the same reader corrections and never add unread messages', () => {
  const f = fixture();
  const anchor: import('./page/scroll.ts').Anchor = { item: { kind: 'job', byte: 300 }, edge: 'row', offset: 20 };
  f.step([{ type: 'navigate', anchor }], { top: 100, rows: [{ item: anchor.item, top: 120, bottom: 150 }], loaded: [anchor.item] });
  const prepend = f.step([{ type: 'history' }], { rows: [{ item: anchor.item, top: 420, bottom: 450 }] });
  assert.deepEqual([prepend.decision.scrollTop, prepend.decision.latest.count, prepend.decision.glideOffset], [400, 0, 0]);
});
