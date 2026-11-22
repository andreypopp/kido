import assert from 'node:assert/strict';
import { test } from 'node:test';
import { realFixture } from './koa-program-fixture.ts';
import { ofType, pollUntil, selfPane } from './koa-agent-fixture.ts';
import { cp, mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { join, resolve } from 'node:path';

const classification = { settings: { koa: { topics: { model: 'fake/classifier' } } }, models: [{ provider: 'fake', id: 'fake-model' }, { provider: 'fake', id: 'classifier' }] };

test('archive and restore persist through reload while explicit sends and new turn assignments keep archive state', { timeout: 10000 }, async t => {
  const app = await realFixture(t, { ...classification, replies: [
    { when: '[topic: one]\nfirst', text: '[topic: one]\nFirst reply' },
    { when: '[topic: other]\nsecond', text: '[topic: other]\nSecond reply' },
    { when: '[topic: one]\nexplicit', text: 'Still archived' },
  ] });
  for (const [topic, text] of [['one', 'first'], ['other', 'second']]) {
    const before = app.count(); await app.post('prompt', { text, topic, mode: 'prompt', attachments: [] });
    await app.until(ofType('state', state => !state.working), before);
  }
  const history = await (await fetch(app.url('items?before=100'))).json();
  let before = app.count();
  assert.equal((await app.post('topics/archive', { name: 'one', archived: true })).status, 200);
  const archived = await app.until(ofType('state', state => 'topics' in state && !!state.topics.find(topic => topic.name === 'one')?.archived), before);
  assert.ok(archived.sessionFile);
  const entries = (await readFile(archived.sessionFile, 'utf8')).trim().split('\n').map(line => JSON.parse(line));
  assert.equal((await app.post('topics/archive', { name: 'one', archived: true })).status, 200);
  assert.equal((await readFile(archived.sessionFile, 'utf8')).trim().split('\n').length, entries.length);
  assert.equal((await (await fetch(app.url('items?before=100'))).json()).epoch, history.epoch);
  before = app.count(); await app.post('prompt', { text: 'explicit', topic: 'one', mode: 'prompt', attachments: [] });
  await app.until(ofType('state', state => !state.working), before);
  const explicit = await app.until(ofType('item', record => record.item.kind === 'user' && record.item.text === 'explicit'), before);
  assert.equal(explicit.item.kind === 'user' ? explicit.item.topic : undefined, 'one');
  before = app.count(); await app.post('prompt', { text: '/reload', mode: 'prompt', attachments: [] });
  await app.until(ofType('reset'), before);
  const replay = await app.until(ofType('state', state => 'topics' in state && !!state.topics.find(topic => topic.name === 'one')?.archived), before);
  const saved = replay.sessionFile; assert.ok(saved);
  const resumed = await realFixture(t, { ...classification, replies: [], setup: async ({ sessions }) => { const file = join(sessions, 'archived.jsonl'); await cp(saved, file); return ['--session', file]; } });
  await resumed.until(ofType('state', state => 'topics' in state && !!state.topics.find(topic => topic.name === 'one')?.archived));
  assert.equal((await app.post('topics/move', { from: 'one', to: 'renamed' })).status, 200);
  assert.equal((await app.post('topics/move', { from: 'other', to: 'renamed' })).status, 200);
  const current = await (await fetch(app.url('items?before=100'))).json();
  const reply = current.items.find((item: { kind: string }) => item.kind === 'assistant'); assert.ok(reply);
  assert.equal((await app.post('messages/topic', { seq: reply.seq, topic: 'New topic' })).status, 200);
  const moved = await (await fetch(app.url('items?before=100'))).json();
  assert.equal(moved.items.find((item: { kind: string }) => item.kind === 'user')?.topic, 'New topic');
  before = app.count(); assert.equal((await app.post('topics/archive', { name: 'renamed', archived: false })).status, 200);
  await app.until(ofType('state', state => 'topics' in state && state.topics.some(topic => topic.name === 'renamed' && !topic.archived)), before);
  assert.equal(app.provider.requests.filter(request => request.body.model === 'classifier').length, 0);
  for (const body of [{ name: 'missing', archived: true }, { name: 'renamed', archived: 1 }]) assert.equal((await app.post('topics/archive', body)).status, 400);
});

test('a classifier alias to an archived topic is rejected and archived quotes fall through without context', { timeout: 10000 }, async t => {
  const app = await realFixture(t, { ...classification, replies: [
    { when: '[topic: one]\nseed', text: '[topic: one]\nA sufficiently long quoted passage' },
    { model: 'classifier', when: 'New message:\nlate', text: 'one' },
    { when: 'late', text: 'Done' },
    { model: 'classifier', when: 'New message:\n> A sufficiently long quoted passage\nAgain', text: 'renamed' },
    { when: '> A sufficiently long quoted passage\nAgain', text: 'Done again' },
  ] });
  let before = app.count(); await app.post('prompt', { text: 'seed', topic: 'one', mode: 'prompt', attachments: [] });
  await app.until(ofType('state', state => !state.working), before);
  await app.post('topics/move', { from: 'one', to: 'renamed' });
  await app.post('topics/archive', { name: 'renamed', archived: true });
  before = app.count(); await app.post('prompt', { text: 'late', mode: 'prompt', attachments: [] });
  const late = await app.until(ofType('item', record => record.item.kind === 'user' && record.item.text === 'late'), before);
  assert.equal(late.item.kind === 'user' ? late.item.topic : undefined, undefined);
  await app.until(ofType('state', state => !state.working), before);
  before = app.count(); await app.post('prompt', { text: '> A sufficiently long quoted passage\nAgain', mode: 'prompt', attachments: [] });
  const quoted = await app.until(ofType('item', record => record.item.kind === 'user' && record.item.text.includes('Again')), before);
  assert.equal(quoted.item.kind === 'user' ? quoted.item.topic : undefined, undefined);
  await app.until(ofType('state', state => !state.working), before);
  const requests = app.provider.requests.filter(request => request.body.model === 'classifier');
  assert.equal(requests.length, 2);
  assert.ok(!JSON.stringify(requests[1].body).includes('## renamed'));
  assert.equal(app.records().filter(ofType('item', record => record.item.kind === 'notify' && record.item.text.text.startsWith('Topic classifier:'))).length, 1);
});

test('a rejected classified submission returns the accepted text to the editor', { timeout: 10000 }, async t => {
  const dir = await mkdtemp('/tmp/koa-rejected-prompt-');
  t.after(() => rm(dir, { recursive: true, force: true }));
  await cp(resolve('../build/koa/share/koa'), dir, { recursive: true });
  const program = join(dir, 'koa/koa.ts');
  await writeFile(program, (await readFile(program, 'utf8')).replace('const disposition = await koaAgents.submitPrompt', 'const disposition = await Promise.reject(new Error("submission rejected")); await koaAgents.submitPrompt'));
  const app = await realFixture(t, { ...classification, program, replies: [{ model: 'classifier', when: 'New message:\nrecover me', text: 'Recovery', gate: 'classify' }] });
  const before = app.count();
  assert.deepEqual(await (await app.post('prompt', { text: 'recover me', mode: 'prompt', attachments: [] })).json(), { disposition: 'queued' });
  await pollUntil(() => app.provider.requests.length === 1, 5000, 'held classification');
  app.provider.release('classify');
  await app.until(ofType('item', record => record.item.kind === 'notify' && record.item.text.text === 'submission rejected'), before);
  const state = [...app.records()].reverse().find(ofType('state'));
  assert.equal(state?.editor?.text, 'recover me');
});

test('reload leaves an accepted classification pending and delivers it once', { timeout: 10000 }, async t => {
  const app = await realFixture(t, { ...classification, replies: [{ model: 'classifier', when: 'New message:\nheld reload', text: 'Held', gate: 'classify' }, { when: '[topic: Held]\nheld reload', text: 'Done' }] });
  const before = app.count(); await app.post('prompt', { text: 'held reload', mode: 'prompt', attachments: [] });
  await app.until(ofType('state', record => record.queue.classifying.length === 1), before);
  await pollUntil(() => app.provider.requests.length === 1, 5000, 'held classification');
  const reload = app.count(); await app.post('prompt', { text: '/reload', mode: 'prompt', attachments: [] });
  const notice = await app.until(ofType('item', record => record.item.kind === 'notify' && record.item.text.text.startsWith('reload: not while')), reload);
  assert.ok(notice);
  app.provider.release('classify');
  await app.until(ofType('item', record => record.item.kind === 'user' && record.item.text === 'held reload'), reload);
  assert.equal(app.provider.requests.filter(request => request.body.model === 'classifier').length, 1);
});

test('renamed queued prompts use their displayed identity for removal', { timeout: 10000 }, async t => {
  const app = await realFixture(t, { replies: [{ when: 'begin', text: '[topic: one]\nWorking', gate: 'work' }] });
  const before = app.count(); await app.post('prompt', { text: 'begin', topic: 'one', mode: 'prompt', attachments: [] });
  await app.until(ofType('state', record => record.working), before);
  await app.post('prompt', { text: 'queued', topic: 'one', mode: 'follow_up', attachments: [] });
  assert.equal((await app.post('topics/move', { from: 'one', to: 'renamed' })).status, 200);
  const renamed = await app.until(ofType('state', record => record.queue.followUp[0]?.topic === 'renamed'), before);
  assert.equal((await app.post('queue/remove', { kind: 'follow-up', index: 0, text: renamed.queue.followUp[0].text, topic: 'renamed' })).status, 200);
  app.provider.release('work');
});

test('a rejected held prompt does not restore into a replacement session', { timeout: 10000 }, async t => {
  const app = await realFixture(t, { ...classification, replies: [{ model: 'classifier', when: 'New message:\nold draft', text: 'Old', gate: 'classify' }] });
  const before = app.count();
  await app.post('prompt', { text: 'old draft', mode: 'prompt', attachments: [] });
  const pending = await app.until(ofType('state', record => record.queue.classifying.length === 1), before);
  await pollUntil(() => app.provider.requests.length === 1, 5000, 'held old classification');
  const switched = app.count();
  await app.post('sessions/new');
  const replacement = await app.until(ofType('state', record => record.life.type === 'ready' && record.sessionId !== pending.sessionId), switched);
  app.provider.release('classify');
  await app.until(ofType('item', record => record.item.kind === 'notify' && record.item.text.text === 'pi session changed'), switched);
  const latest = [...app.records()].reverse().find(ofType('state'));
  assert.equal(latest?.sessionId, replacement.sessionId);
  assert.equal(latest?.editor, undefined);
});

test('a handled initial classified prompt leaves no pending row', { timeout: 10000 }, async t => {
  const app = await realFixture(t, { ...classification, args: ['handled input'], replies: [{ model: 'classifier', when: 'New message:\nhandled input', text: 'Handled' }], extensions: { 'handled.ts': `export default pi => pi.on('input', (_event, ctx) => { ctx.ui.notify('input handled'); return { action: 'handled' }; });` } });
  await pollUntil(() => app.provider.requests.length === 1, 5000, 'initial classifier');
  await app.until(ofType('item', record => record.item.kind === 'notify' && record.item.text.text === 'input handled'));
  const ready = [...app.records()].reverse().find(ofType('state'));
  assert.deepEqual(ready?.queue.classifying, []);
});

test('an inbox prompt held during work advertises and delivers follow-up mode', { timeout: 10000 }, async t => {
  const app = await realFixture(t, { ...classification, panes: [selfPane()], replies: [
    { when: 'begin', text: '[topic: work]\nWorking', gate: 'work' },
    { model: 'classifier', when: 'New message:\ninbox queued', text: 'Inbox', gate: 'classify' },
    { when: '[topic: Inbox]\ninbox queued', text: 'Done' },
  ] });
  const before = app.count(); await app.post('prompt', { text: '[topic: work]\nbegin', mode: 'prompt', attachments: [] });
  await app.until(ofType('state', record => record.working), before);
  const queued = app.count(), delivery = app.feed({ id: 'inbox-mode', kind: 'user', text: 'inbox queued', record: '' });
  const pending = await app.until(ofType('state', record => record.queue.classifying.length === 1), queued);
  assert.equal(pending.queue.classifying[0].mode, 'followUp');
  app.provider.release('classify'); await delivery;
  await app.until(ofType('state', record => record.queue.followUp.length === 1), queued);
  app.provider.release('work');
  await app.until(ofType('item', record => record.item.kind === 'user' && record.item.text === 'inbox queued'), queued);
  assert.deepEqual(app.provider.violations, []);
});

test('a quote match is synchronous and explicit markers take precedence', { timeout: 10000 }, async t => {
  const app = await realFixture(t, { ...classification, replies: [
    { when: 'begin', text: '[topic: quoted]\nA sufficiently long quotation to match' },
    { when: '> A sufficiently long quotation to match\nYes', text: 'Done' },
    { when: '[topic: manual]\n> A sufficiently long quotation to match', text: 'Manual' },
  ] });
  let before = app.count();
  await app.post('prompt', { text: '[topic: quoted]\nbegin', mode: 'prompt', attachments: [] });
  await app.until(ofType('state', record => !record.working), before);
  before = app.count();
  const result = await (await app.post('prompt', { text: '> A sufficiently long quotation to match\nYes', mode: 'prompt', attachments: [] })).json();
  assert.equal(result.disposition, 'started');
  const quoted = await app.until(ofType('item', record => record.item.kind === 'user'), before);
  assert.equal(quoted.item.kind === 'user' ? quoted.item.topic : undefined, 'quoted');
  assert.ok(app.records().slice(before).filter(ofType('state')).every(state => state.queue.classifying.length === 0));
  await app.until(ofType('state', record => !record.working), before);
  before = app.count();
  await app.post('prompt', { text: '[topic: manual]\n> A sufficiently long quotation to match', mode: 'prompt', attachments: [] });
  const manual = await app.until(ofType('item', record => record.item.kind === 'user'), before);
  assert.equal(manual.item.kind === 'user' ? manual.item.topic : undefined, 'manual');
  assert.equal(app.provider.requests.filter(request => request.body.model === 'classifier').length, 0);
});

test('a persisted reply move stores entry ids and survives reload', { timeout: 10000 }, async t => {
  const app = await realFixture(t, { replies: [{ when: 'first', text: '[topic: one]\nFirst reply' }, { when: 'second', text: '[topic: two]\nSecond reply' }] });
  for (const [text, topic] of [['first', 'one'], ['second', 'two']]) {
    const before = app.count(); await app.post('prompt', { text, topic, mode: 'prompt', attachments: [] });
    await app.until(ofType('state', record => !record.working), before);
  }
  const history = await (await fetch(app.url('items?before=100'))).json();
  const reply = history.items.find((item: { kind: string }) => item.kind === 'assistant'); assert.ok(reply);
  const moved = app.count();
  assert.equal((await app.post('messages/topic', { seq: reply.seq, topic: 'two' })).status, 200);
  const user = history.items.find((item: { kind: string }) => item.kind === 'user'); assert.ok(user);
  const movedUser = await app.until(ofType('item', record => record.item.seq === user.seq), moved);
  const movedReply = await app.until(ofType('item', record => record.item.seq === reply.seq), moved);
  assert.equal(movedUser.item.kind === 'user' ? movedUser.item.topic : undefined, 'two');
  assert.ok(movedUser.item.revision > user.revision);
  assert.ok(movedReply.item.kind === 'assistant' && movedReply.item.blocks.every(block => block.topic === 'two'));
  assert.ok(movedReply.item.revision > reply.revision);
  const corrected = await (await fetch(app.url('items?before=100'))).json();
  assert.equal(corrected.epoch, history.epoch);
  assert.equal(app.records().slice(moved).some(ofType('reset')), false);
  const state = [...app.records()].reverse().find(ofType('state')); assert.ok(state?.sessionFile);
  const entries = (await readFile(state.sessionFile, 'utf8')).trim().split('\n').map(line => JSON.parse(line));
  const move = entries.find(entry => entry.customType === 'koa.message-topic');
  assert.equal(move.data.entries.length, 2);
  assert.ok(move.data.entries.every((id: string) => entries.some(entry => entry.id === id && entry.type === 'message')));
  const beforeReload = app.count(); await app.post('prompt', { text: '/reload', mode: 'prompt', attachments: [] });
  const replay = await app.until(ofType('reset'), beforeReload);
  assert.equal(replay.items.find(item => item.kind === 'user')?.topic, 'two');
});

test('non-string classifier settings send an unmarked prompt and warn once', { timeout: 10000 }, async t => {
  const app = await realFixture(t, { settings: { koa: { topics: { model: 42 } } }, replies: [{ when: 'invalid setting', text: 'Done' }] });
  const before = app.count();
  await app.post('prompt', { text: 'invalid setting', mode: 'prompt', attachments: [] });
  const user = await app.until(ofType('item', record => record.item.kind === 'user'), before);
  assert.equal(user.item.kind === 'user' ? user.item.topic : undefined, undefined);
  await pollUntil(() => app.provider.requests.length === 1, 5000, 'the prompt request');
  const notices = app.records().filter(ofType('item', record => record.item.kind === 'notify' && record.item.text.text.startsWith('Topic classifier:')));
  assert.equal(notices.length, 1);
  assert.match(JSON.stringify(notices), /invalid koa\.topics\.model: 42/);
  assert.deepEqual(app.provider.requests.map(request => request.body.model), ['fake-model']);
  assert.deepEqual(app.provider.violations, []);
});

test('classifier skips explicit labels and commands, and off makes no request', { timeout: 10000 }, async t => {
  const app = await realFixture(t, { ...classification, replies: [
    { when: '[topic: filtered]\nfilter', text: 'Done' },
    { when: '[topic: typed]\nmanual', text: 'Done' },
  ], extensions: { 'probe.ts': `export default pi => pi.registerCommand('probe', {description:'probe',handler:(_args,ctx)=>ctx.ui.notify('probe','info')});` } });
  for (const prompt of [{ text: 'filter', topic: 'filtered' }, { text: '[topic: typed]\nmanual' }, { text: '/probe' }]) {
    const before = app.count();
    await app.post('prompt', { ...prompt, mode: 'prompt', attachments: [] });
    if (prompt.text === '/probe') await app.until(ofType('item', record => record.item.kind === 'notify' && record.item.text.text === 'probe'), before);
    else await app.until(ofType('state', record => !record.working), before);
  }
  assert.deepEqual(app.provider.requests.map(request => request.body.model), ['fake-model', 'fake-model']);
  assert.deepEqual(app.provider.violations, []);
  const off = await realFixture(t, { replies: [{ when: 'unlabelled', text: 'Done' }] });
  const beforeOff = off.count();
  await off.post('prompt', { text: 'unlabelled', mode: 'prompt', attachments: [] });
  await off.until(ofType('state', record => !record.working), beforeOff);
  assert.deepEqual(off.provider.requests.map(request => request.body.model), ['fake-model']);
  assert.deepEqual(off.provider.violations, []);
});

test('classifier failures send unlabelled prompts and warn once; timeout aborts', { timeout: 15000 }, async t => {
  const dir = await mkdtemp('/tmp/koa-classifier-');
  t.after(() => rm(dir, { recursive: true, force: true }));
  await cp(resolve('../build/koa/share/koa'), dir, { recursive: true });
  const program = join(dir, 'koa/koa.ts');
  await writeFile(program, (await readFile(program, 'utf8')).replace('koaAgents.createTree({', 'koaAgents.createTree({ classifierDeadlineMs: 200,'));
  const app = await realFixture(t, { ...classification, program, replies: [
    { model: 'classifier', when: 'New message:\nslow', text: 'slow', gate: 'timeout' },
    { model: 'classifier', when: 'New message:\nserver', status: 500 },
    { model: 'classifier', when: 'New message:\ninvalid', text: 'a]b' },
    ...['slow', 'server', 'invalid'].map(when => ({ when, text: 'Done' })),
  ] });
  for (const text of ['slow', 'server', 'invalid']) {
    const before = app.count();
    assert.equal((await app.post('prompt', { text, mode: 'prompt', attachments: [] })).status, 200);
    const user = await app.until(ofType('item', record => record.item.kind === 'user'), before);
    assert.equal(user.item.kind === 'user' ? user.item.topic : undefined, undefined);
    await app.until(ofType('state', record => !record.working), before);
  }
  await pollUntil(() => app.provider.requests[0]?.aborted === true, 5000, 'aborted classifier request');
  const history = await (await fetch(app.url('items?before=' + Number.MAX_SAFE_INTEGER))).json();
  const notices = history.items.filter((item: { kind: string; text?: { text: string } }) => item.kind === 'notify' && item.text?.text.startsWith('Topic classifier:'));
  assert.equal(notices.length, 1);
  assert.match(notices[0].text.text, /timeout|aborted/i);
  assert.equal(app.provider.requests.filter(request => request.body.model === 'classifier').length, 3);
  assert.deepEqual(app.provider.violations, []);
});

test('a prompt shows as classifying and the composer answer is out before the classifier answers', { timeout: 10000 }, async t => {
  const app = await realFixture(t, { ...classification, replies: [
    { model: 'classifier', when: 'New message:\nfix the cache', text: 'Build cache', gate: 'classify' },
    { when: '[topic: Build cache]\nfix the cache', text: 'Done' },
  ] });
  const before = app.count();
  const response = await app.post('prompt', { text: 'fix the cache', mode: 'prompt', attachments: [] });
  assert.equal(response.status, 200);
  assert.deepEqual(await response.json(), { disposition: 'queued' });
  const held = await app.until(ofType('state', record => record.queue.classifying.length === 1), before);
  assert.deepEqual(held.queue.classifying, [{ text: 'fix the cache', attachments: [], mode: 'prompt' }]);
  await pollUntil(() => app.provider.requests.length === 1, 5000, 'the classifier request');
  const released = app.count();
  app.provider.release('classify');
  const user = await app.until(ofType('item', record => record.item.kind === 'user'), released);
  assert.equal(user.item.kind === 'user' ? user.item.topic : undefined, 'Build cache');
  const idle = await app.until(ofType('state', record => !record.working && record.queue.classifying.length === 0), released);
  assert.deepEqual(idle.queue.classifying, []);
  assert.deepEqual(app.provider.violations, []);
});

test('classification preserves FIFO and queued steer context while a turn runs', { timeout: 10000 }, async t => {
  const app = await realFixture(t, { ...classification, replies: [
    { model: 'classifier', when: 'New message:\nfirst', text: 'cache', gate: 'classify' },
    { when: '[topic: cache]\nfirst', text: 'Working', gate: 'turn' },
    { model: 'classifier', when: 'New message:\nsecond', text: 'release' },
    { model: 'classifier', when: 'New message:\nthird', text: 'docs' },
  ] });
  const first = app.post('prompt', { text: 'first', mode: 'prompt', attachments: [] });
  await pollUntil(() => app.provider.requests.length === 1, 5000, 'first classification');
  const second = app.post('prompt', { text: 'second', mode: 'prompt', attachments: [] });
  await app.until(ofType('state', record => record.queue.classifying.length === 2));
  assert.equal((await second).status, 200);
  app.provider.release('classify');
  assert.equal((await first).status, 200);
  assert.equal((await second).status, 200);
  const state = await app.until(ofType('state', record => record.queue.steering.length === 1));
  assert.deepEqual(state.queue.steering.map(prompt => [prompt.text, prompt.topic]), [['second', 'release']]);
  await app.post('prompt', { text: 'third', mode: 'follow_up', attachments: [] });
  const context = app.provider.requests.find(request => request.body.model === 'classifier' && JSON.stringify(request.body.messages).includes('New message:\\nthird'));
  assert.ok(context);
  assert.match(JSON.stringify(context.body.messages), /## cache/);
  assert.match(JSON.stringify(context.body.messages), /user: first/);
  assert.match(JSON.stringify(context.body.messages), /## release/);
  assert.match(JSON.stringify(context.body.messages), /user: second/);
  await app.post('queue/clear');
  const beforeDone = app.count();
  app.provider.release('turn');
  await app.until(ofType('state', record => !record.working), beforeDone);
  assert.deepEqual(app.provider.violations, []);
});

test('classifier labels the root prompt before pi and uses a separate small request', { timeout: 10000 }, async t => {
  const app = await realFixture(t, { settings: { koa: { topics: { model: 'fake/classifier' } } }, models: [{ provider: 'fake', id: 'fake-model' }, { provider: 'fake', id: 'classifier' }], replies: [
    { model: 'classifier', when: 'New message:\nfix the cache', text: 'build-cache' },
    { when: '[topic: build-cache]\nfix the cache', text: '[topic: build-cache]\nFixed' },
  ] });
  assert.equal((await app.post('prompt', { text: 'fix the cache', mode: 'prompt', attachments: [] })).status, 200);
  const user = await app.until(ofType('item', record => record.item.kind === 'user'));
  assert.equal(user.item.kind === 'user' ? user.item.topic : undefined, 'build-cache');
  await app.until(ofType('state', record => !record.working), app.count() - 1);
  assert.equal(app.provider.requests[0]?.body.model, 'classifier');
  assert.equal(app.provider.requests[0]?.body.tools, undefined);
  assert.equal(app.provider.requests.length, 2);
  assert.deepEqual(app.provider.violations, []);
});

test('ko user messages classify only the root and a subagent view stays unlabelled', { timeout: 15000 }, async t => {
  const app = await realFixture(t, { ...classification, panes: [selfPane()], replies: [
    { when: 'spawn kid', tools: [{ name: 'spawn_agent', args: { name: 'kid', task: 'kid task', model: 'fake/fake-model' } }] },
    { when: 'spawn kid', text: 'Spawned' },
    { when: 'kid task', text: 'Child done' },
    { when: 'notice from kid', text: 'Noted' },
    { model: 'classifier', when: 'New message:\nroot inbox', text: 'inbox' },
    { when: '[topic: inbox]\nroot inbox', text: 'Root done' },
    { when: 'child inbox', text: 'Child inbox done' },
    { when: 'child page', text: 'Child page done' },
    { when: 'notice from kid', text: 'Noted again' },
    { when: 'notice from kid', text: 'Noted once more' },
  ] });
  await app.post('prompt', { text: '[topic: setup]\nspawn kid', mode: 'prompt', attachments: [] });
  const listing = await app.until(ofType('state', record => record.agents.some(agent => agent.name === 'kid')));
  const target = listing.agents.find(agent => agent.name === 'kid')?.target;
  assert.ok(target?.type === 'view');
  await app.until(ofType('item', record => record.item.kind === 'agent' && record.item.inbound.form === 'report'));
  await app.feed({ id: 'root-user', kind: 'user', text: 'root inbox', record: '' });
  await pollUntil(() => app.provider.requests.some(request => JSON.stringify(request.body.messages.at(-1)).includes('[topic: inbox]')), 5000, 'labelled root inbox');
  await app.feed({ id: 'child-user', kind: 'user', text: 'child inbox', record: 'agents/kid' });
  await pollUntil(() => app.provider.requests.some(request => JSON.stringify(request.body.messages.at(-1)).includes('child inbox')), 5000, 'child inbox');
  const beforeView = app.count();
  await app.post('view', { id: target.id });
  await app.until(ofType('state', record => record.view.id === target.id && !record.working), beforeView);
  const before = app.count();
  await app.post('prompt', { text: 'child page', mode: 'prompt', attachments: [] });
  const user = await app.until(ofType('item', record => record.item.kind === 'user' && record.item.text === 'child page'), before);
  assert.equal(user.item.kind === 'user' ? user.item.topic : undefined, undefined);
  await app.until(ofType('state', record => !record.working), before);
  assert.equal(app.provider.requests.filter(request => request.body.model === 'classifier').length, 1);
  assert.deepEqual(app.provider.violations, []);
});

test('command-line root messages get a classifier marker', { timeout: 10000 }, async t => {
  const app = await realFixture(t, { ...classification, args: ['from command line'], replies: [
    { model: 'classifier', when: 'New message:\nfrom command line', text: 'startup' },
    { when: '[topic: startup]\nfrom command line', text: 'Done' },
  ] });
  const user = await app.until(ofType('item', record => record.item.kind === 'user'));
  assert.equal(user.item.kind === 'user' ? user.item.topic : undefined, 'startup');
  await pollUntil(() => app.provider.requests.length === 2, 5000, 'command-line prompt reaches pi');
  assert.deepEqual(app.provider.violations, []);
});

test('reply status skips topic markers and uses the first non-empty section', { timeout: 20000 }, async t => {
  const app = await realFixture(t, { replies: [
    { text: '[topic: x]\n\n## **Hello** `there`' },
    { text: '[topic: x]\n\nFirst part\nMore text\n[topic: y]\nSecond part' },
  ] });
  for (const expected of ['Hello there', 'First part']) {
    const before = app.count();
    assert.equal((await app.post('prompt', { text: 'hello', mode: 'prompt', attachments: [] })).status, 200);
    await app.until(ofType('state', record => record.working), before);
    await app.until(ofType('state', record => !record.working), before);
    await pollUntil(() => [...app.stdout().matchAll(/\x1b\]7501;state=done:app=koa:msg=([^\x1b]*)/g)].length === ['Hello there', 'First part'].indexOf(expected) + 1, 5000, 'the reply status');
    const status = [...app.stdout().matchAll(/\x1b\]7501;state=done:app=koa:msg=([^\x1b]*)/g)].at(-1);
    assert.equal(Buffer.from(status?.[1] ?? '', 'base64').toString('utf8'), expected);
  }
});

test('queues with a topic preserve full identity and slash commands dispatch unchanged', { timeout: 10000 }, async t => {
  const app = await realFixture(t, { replies: [{ text: '[topic: work]\nDone', gate: 'hold' }], extensions: { 'command.ts': `export default pi => pi.registerCommand('probe', {description:'probe',handler:(_args,ctx)=>ctx.ui.notify('command dispatched','info')});` } });
  assert.equal((await app.post('prompt', { text: 'begin', mode: 'prompt', attachments: [], topic: 'work' })).status, 200);
  await app.until(ofType('state', record => record.working));
  for (const topic of ['one', 'two']) assert.equal((await app.post('prompt', { text: 'same', mode: 'follow_up', attachments: [], topic })).status, 200);
  const queued = await app.until(ofType('state', record => record.queue.followUp.length === 2));
  assert.deepEqual(queued.queue.followUp.map(entry => [entry.text, entry.topic]), [['same', 'one'], ['same', 'two']]);
  assert.equal((await app.post('queue/remove', { kind: 'follow-up', index: 0, text: 'same', topic: 'two' })).status, 409);
  assert.equal((await app.post('queue/remove', { kind: 'follow-up', index: 0, text: 'same', topic: 'one' })).status, 200);
  const restored = await (await app.post('queue/clear')).json();
  assert.deepEqual(restored.followUp, [{ text: 'same', attachments: [], topic: 'two' }]);
  const command = await (await app.post('prompt', { text: '/probe', mode: 'prompt', attachments: [], topic: 'work' })).json();
  assert.equal(command.disposition, 'handled');
  await app.until(ofType('item', record => record.item.kind === 'notify' && record.item.text.text === 'command dispatched'));
  app.provider.release('hold');
});

test('root prompt topics reach pi, state and sparse history without marker text', { timeout: 10000 }, async t => {
  const app = await realFixture(t, { replies: [{ text: '[topic: work]\n**First summary**\nBody\n[topic: other]\nOther summary' }] });
  const response = await app.post('prompt', { text: 'hello', mode: 'prompt', attachments: [], topic: 'work' });
  assert.equal(response.status, 200);
  const user = await app.until(ofType('item', record => record.item.kind === 'user'));
  assert.equal(user.item.kind === 'user' ? user.item.topic : undefined, 'work');
  assert.equal(user.item.kind === 'user' ? user.item.text : undefined, 'hello');
  const state = await app.until(ofType('state', record => !record.working && 'topics' in record && record.topics.length === 2));
  assert.equal(state.view.type, 'root'); assert.ok('topics' in state);
  assert.deepEqual(state.topics.map(topic => [topic.name, topic.last?.summary]), [['work', '**First summary**'], ['other', 'Other summary']]);
  assert.ok(state.topics.every(topic => typeof topic.last?.at === 'number'));
  const page = await (await fetch(app.url('items?before=' + Number.MAX_SAFE_INTEGER + '&topic=other'))).json();
  assert.equal(page.more, false);
  assert.equal(page.items.some((item: { kind: string }) => item.kind === 'user'), false);
  assert.equal((await app.post('prompt', { text: 'bad', mode: 'prompt', attachments: [], topic: 'a]b' })).status, 400);
});
