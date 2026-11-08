import assert from "node:assert/strict";
import { existsSync, readFileSync, statSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { test } from "node:test";
import { webview, type Webview } from "../webview/index.ts";
import { makeFixture, pollUntil } from "./ko-pi-fixture.ts";

test("webview SDK support events, TTY, arguments, restart and close", async () => {
  const fx = makeFixture();
  const tty = process.stdout.isTTY;
  let wv: Webview | null = null;
  try {
    delete process.env.KO_PANE;
    assert.equal(await webview(), null);
    assert.match(readFileSync(join(fx.dir, "ko.jsonl"), "utf8"), /"webview","serve","--socket"/);
    process.env.KO_PANE = "pane_1";
    assert.equal(await webview({ ko: join(fx.dir, "missing") }), null);
    const refused = join(fx.dir, "refused");
    writeFileSync(refused, "#!/bin/sh\nprintf 'bridge refused\\n' >&2\nexit 1\n", { mode: 0o700 });
    await assert.rejects(webview({ ko: refused }), /bridge refused/);
    wv = await webview({ ko: join(fx.binDir, "ko") });
    assert.ok(wv);
    assert.equal(wv.supported, false);
    assert.equal(statSync(dirname(wv.socketPath)).mode & 0o777, 0o700);
    const changes: boolean[] = [];
    const listener = (value: boolean) => { changes.push(value); };
    wv.on("supported", listener);
    fx.serve({ type: "supported", supported: true });
    await pollUntil(() => changes.length === 1);
    assert.equal(wv.supported, true);
    Object.defineProperty(process.stdout, "isTTY", { configurable: true, value: false });
    await assert.rejects(wv.show(), /TTY/);
    Object.defineProperty(process.stdout, "isTTY", { configurable: true, value: true });
    assert.equal(wv.shown, false);
    await wv.hide();
    await Promise.all([wv.show("/page?q=1"), wv.show("/page?q=1")]);
    assert.equal(wv.shown, true);
    await wv.show("/a");
    await wv.show("/b");
    assert.equal(fx.webviewActions().length, 3);
    await wv.show("/b");
    assert.equal(fx.webviewActions().length, 3);
    await Promise.all([wv.hide(), wv.hide()]);
    assert.equal(wv.shown, false);
    await wv.show("/b");
    await wv.show();
    await wv.show();
    assert.deepEqual(fx.webviewActions(), ["enter", "enter", "enter", "leave", "enter", "enter"]);
    const args = readFileSync(join(fx.dir, "ko.jsonl"), "utf8").trim().split("\n").map(line => JSON.parse(line));
    assert.deepEqual(args.filter(argv => argv[0] === "webview" && argv[1] === "enter"), [
      ["webview", "enter", "--path", "/page?q=1"],
      ["webview", "enter", "--path", "/a"],
      ["webview", "enter", "--path", "/b"],
      ["webview", "enter", "--path", "/b"],
      ["webview", "enter"],
    ]);
    process.env.KO_FAKE_SERVE_DROP = join(fx.dir, "serve-drop");
    const closingView = wv;
    let shutdownNotifications = 0;
    wv.on("supported", value => { if (!value) { shutdownNotifications++; void closingView.hide(); } });
    assert.equal(wv.supported, true);
    await wv.close();
    assert.equal(shutdownNotifications, 0);
    assert.equal(wv.shown, false);
    wv = await webview({ ko: join(fx.binDir, "ko") });
    assert.ok(wv);
    wv.on("supported", listener);
    changes.length = 0;
    writeFileSync(process.env.KO_FAKE_SERVE_DROP, "");
    await pollUntil(() => changes.includes(false) && changes.at(-1) === true);
    const socket = wv.socketPath;
    wv.off("supported", listener);
    await wv.close();
    assert.equal(existsSync(dirname(socket)), false);
    assert.equal(fx.webviewActions().at(-1), "leave");
    await wv.close();
  } finally {
    await wv?.close();
    Object.defineProperty(process.stdout, "isTTY", { configurable: true, value: tty });
    await fx.restore();
  }
});
