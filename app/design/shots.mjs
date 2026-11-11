#!/usr/bin/env node
// Recaptures the thumbnails of index.html into shots/: one 16:10 crop of
// each mockup's main element, light theme, 720px wide. Needs Google Chrome
// (or CHROME=<path>) and Node 22 or newer; no packages.
//   node app/design/shots.mjs            all pages
//   node app/design/shots.mjs koa/bang   the pages whose path contains the text
import { spawn } from "node:child_process";
import { mkdirSync, renameSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
// [page, index of the main element to take when the first is not the best]
const pages = [
  ["sidebar/mockup.html"], ["sidebar/variants.html"], ["pane/mockup.html"], ["pane-focus/mockup.html"],
  ["palette/mockup.html"], ["copy-select/mockup.html"], ["notices/mockup.html"], ["mismatch/mockup.html"],
  ["runtime/mockup.html"], ["runtimes-section/mockup.html"], ["themes/ahrefs/mockup.html"],
  ["koa/mockup.html", 2], ["koa/blocks.html"], ["koa/thinking.html"], ["koa/user.html"], ["koa/working.html"],
  ["koa/composer.html"], ["koa/foot.html"], ["koa/complete.html"], ["koa/media.html"], ["koa/agents.html"],
  ["koa/questions.html"], ["koa/refine.html", 2], ["koa/bang.html"], ["koa/commands.html"], ["koa/sessions.html"],
];
const filter = process.argv[2] || "";
const chrome = process.env.CHROME || "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome";
const width = 1300, height = 1000, outWidth = 720;

// The element to show: the first of these selectors with a box of at least 300×120.
const find = (index) => `(() => {
  document.querySelectorAll('.controls').forEach(c => c.style.display = 'none');
  const sels = ['.app', '.phone', '.pane', '.frame', '.stage', '.window', '.sheet', '.card', 'section .grid>*', 'section>div', 'main>div', 'body>div'];
  let found = [];
  for (const s of sels) {
    for (const e of document.querySelectorAll(s)) { const b = e.getBoundingClientRect(); if (b.width >= 300 && b.height >= 120) found.push(e); }
    if (found.length) break;
  }
  const e = found[Math.min(${index}, found.length - 1)];
  e.scrollIntoView({ block: 'start' }); window.scrollBy(0, -2);
  const b = e.getBoundingClientRect();
  // Page.captureScreenshot's clip is in page coordinates, not viewport ones.
  return JSON.stringify([b.left + window.scrollX, b.top + window.scrollY, b.width, Math.min(b.height, b.width * 0.62, ${height - 10})]);
})()`;

const proc = spawn(chrome, ["--headless=new", "--remote-debugging-port=0", "--hide-scrollbars", `--window-size=${width},${height}`, "--no-first-run", "--user-data-dir=/tmp/kido-design-shots-profile", "about:blank"], { stdio: ["ignore", "ignore", "pipe"] });
const wsUrl = await new Promise((resolve, reject) => {
  let text = "";
  proc.stderr.on("data", (d) => { text += d; const m = text.match(/DevTools listening on (ws:\/\/\S+)/); if (m) resolve(m[1]); });
  proc.on("exit", () => reject(new Error("chrome exited before it listened")));
  setTimeout(() => reject(new Error("chrome did not listen within 15 s")), 15000);
});
const ws = new WebSocket(wsUrl);
await new Promise((r) => ws.addEventListener("open", r));
let seq = 0; const waiting = new Map(); const events = [];
ws.addEventListener("message", (m) => { const d = JSON.parse(m.data); if (d.id) { waiting.get(d.id)(d); waiting.delete(d.id); } else events.push(d); });
const call = (method, params = {}, sessionId) => new Promise((resolve, reject) => {
  const id = ++seq; waiting.set(id, (d) => d.error ? reject(new Error(method + ": " + d.error.message)) : resolve(d.result));
  ws.send(JSON.stringify({ id, method, params, sessionId }));
});
const { targetId } = await call("Target.createTarget", { url: "about:blank" });
const { sessionId } = await call("Target.attachToTarget", { targetId, flatten: true });
await call("Page.enable", {}, sessionId);
const loaded = () => new Promise((r) => { const t = setInterval(() => { const i = events.findIndex((e) => e.method === "Page.loadEventFired"); if (i >= 0) { events.splice(0, i + 1); clearInterval(t); r(); } }, 20); });

mkdirSync(join(here, "shots"), { recursive: true });
let done = 0;
for (const [page, index = 0] of pages) {
  if (!page.includes(filter)) continue;
  await call("Page.navigate", { url: pathToFileURL(join(here, page)).href }, sessionId);
  await loaded();
  await new Promise((r) => setTimeout(r, 300));
  const { result } = await call("Runtime.evaluate", { expression: find(index), returnByValue: true }, sessionId);
  const [x, y, w, h] = JSON.parse(result.value);
  const { data } = await call("Page.captureScreenshot", { format: "png", clip: { x, y, width: w, height: h, scale: outWidth / w } }, sessionId);
  const name = page.replace(/\/mockup\.html$/, "").replace(/\.html$/, "").replace(/\//g, "-");
  const file = join(here, "shots", name + ".png");
  writeFileSync(file + ".tmp", Buffer.from(data, "base64"));
  renameSync(file + ".tmp", file);
  done++;
  console.log(name, Math.round(w) + "×" + Math.round(h));
}
ws.close();
proc.kill();
console.log(done + " thumbnails in " + join(here, "shots"));
