import { test } from "node:test";
import assert from "node:assert/strict";
import { pathEditorCommand, resolvePath } from './koa-editor.ts';
import { floatRect } from "./koa-float.ts";
import type { components } from "../webview/ko-api.d.ts";

test('path resolution uses the view cwd and home', () => {
  assert.equal(resolvePath('src/a.ts', '/project', '/home/me'), '/project/src/a.ts');
  assert.equal(resolvePath('~', '/project', '/home/me'), '/home/me');
  assert.equal(resolvePath('~/a.ts', '/project', '/home/me'), '/home/me/a.ts');
  assert.equal(resolvePath('/etc/hosts', '/project', '/home/me'), '/etc/hosts');
});

test('only editors with a line argument receive +LINE before the path', () => {
  for (const name of ['vi', 'vim', 'nvim', 'nano', 'emacs', 'micro']) assert.deepEqual(pathEditorCommand(['/bin/' + name, '-x'], '/a.ts', 12), ['/bin/' + name, '-x', '+12', '/a.ts']);
  assert.deepEqual(pathEditorCommand(['code', '-w'], '/a.ts', 12), ['code', '-w', '/a.ts']);
  assert.deepEqual(pathEditorCommand(['nvim'], '/a.ts'), ['nvim', '/a.ts']);
});

type Window = components["schemas"]["Window"];
const leaf = (pane: string, cols: number, rows: number) => ({ pane, cols, rows });
const window = (cols: number, rows: number, tree: Window["tree"]): Window => ({ id: "window_1", name: "w", vars: {}, cols, rows, focus: "pane_1", tree, floats: [] });

test("the float is centred over koa's pane and 80% of it", () => {
  assert.deepEqual(floatRect(window(80, 24, leaf("pane_1", 80, 24)), "pane_1"), { x: 8, y: 2, cols: 64, rows: 19 });
  const split = window(201, 40, { split: "h", children: [leaf("pane_2", 100, 40), leaf("pane_1", 100, 40)] });
  assert.deepEqual(floatRect(split, "pane_1"), { x: 111, y: 4, cols: 80, rows: 32 }, "the pane on the right starts after the left pane and its separator");
});

test("a pane whose 80% is under the minimum grows the float to 60x16, shifted to stay inside the window", () => {
  const top = window(100, 30, { split: "v", children: [leaf("pane_1", 100, 18), leaf("pane_2", 100, 11)] });
  assert.deepEqual(floatRect(top, "pane_1"), { x: 10, y: 1, cols: 80, rows: 16 });
  const bottom = window(100, 30, { split: "v", children: [leaf("pane_2", 100, 13), leaf("pane_1", 100, 16)] });
  assert.deepEqual(floatRect(bottom, "pane_1"), { x: 10, y: 13, cols: 80, rows: 16 }, "centred at row 14 it would touch the bottom border");
});

test("a pane under the minimum gives way to the whole window, clipped to it", () => {
  const narrow = window(100, 30, { split: "h", children: [leaf("pane_1", 40, 30), leaf("pane_2", 59, 30)] });
  assert.deepEqual(floatRect(narrow, "pane_1"), { x: 20, y: 7, cols: 60, rows: 16 });
  assert.deepEqual(floatRect(window(50, 12, leaf("pane_1", 50, 12)), "pane_1"), { x: 1, y: 1, cols: 48, rows: 10 });
});
