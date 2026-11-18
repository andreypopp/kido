import { test } from 'node:test';
import assert from 'node:assert/strict';
import { parseArgs } from '@earendil-works/pi-coding-agent';
import { parseKoaArgs, restartArgs } from './koa-args.ts';

test('option-like values stay values in koa and restart arguments', () => {
  for (const name of ['--browser', '--help']) {
    const parsed = parseKoaArgs([`--name=${name}`, '--model=-x', '--runtime=dev', '--', '--help']);
    assert.equal(parsed.values.name, name);
    assert.equal(parsed.values.model, '-x');
    assert.equal(parsed.values.help, undefined);
    assert.equal(parsed.values.browser, undefined);
    const pi = parseArgs(restartArgs(parsed, undefined));
    assert.equal(pi.name, name);
    assert.equal(pi.model, '-x');
    assert.equal(pi.unknownFlags.get('runtime'), 'dev');
    assert.deepEqual(pi.messages, ['--help']);
    assert.deepEqual(restartArgs(parsed, undefined), ['--name', name, '--model', '-x', '--runtime=dev', '--', '--help']);
    assert.deepEqual(restartArgs(parsed, '/session', true), [`--name=${name}`, '--runtime=dev', '--session=/session', '--', '--help']);
  }
});

test('runtime values reach the existing extension flag path', () => {
  const parsed = parseKoaArgs(['--runtime=-dev']);
  const pi = parseArgs(restartArgs(parsed, undefined));
  assert.equal(pi.unknownFlags.get('runtime'), '-dev');
  assert.deepEqual(pi.diagnostics, []);
});

test('reload keeps koa options and repeated pi context options', () => {
  const parsed = parseKoaArgs(['--browser', '--pi=/pi', '--metrics=/metrics', '--metrics-mode=probe', '-e', 'first', '-e', 'second', '--append-system-prompt=one', '--append-system-prompt=two', '--session-id=old', '--fork=old', '-c', '--no-session', '--provider=p', '--model=m', '--thinking=high', 'task']);
  assert.deepEqual(restartArgs(parsed, '/saved', true), ['--browser', '--pi=/pi', '--metrics=/metrics', '--metrics-mode=probe', '--extension=first', '--extension=second', '--append-system-prompt=one', '--append-system-prompt=two', '--session=/saved', '--', 'task']);
});

test('conflicting approval options are refused in either order', () => {
  for (const args of [['--approve', '--no-approve'], ['--no-approve', '--approve', '--no-approve']]) {
    assert.throws(() => parseKoaArgs(args), /--approve and --no-approve conflict/);
  }
});

test('unknown and dropped koa options are errors', () => {
  for (const args of [['--bogus'], ['--mode', 'rpc']]) assert.throws(() => parseKoaArgs(args), /Unknown option/);
});
