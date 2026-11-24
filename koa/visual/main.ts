import { rmSync } from "node:fs";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { webkit } from "playwright";
import { fixtures } from "./cases.ts";
import { Context, require } from "./context.ts";
import { References } from "./pixels.ts";
import { run } from "./driver.ts";
import { deadline } from "./deadline.ts";

const root = resolve(fileURLToPath(new URL("../..", import.meta.url)));
const selected = new Map<string, Set<string> | undefined>();
for (const item of (process.env.ONLY ?? "").split(/\s+/).filter(Boolean)) {
  const slash = item.indexOf("/"), fixture = slash < 0 ? item : item.slice(0, slash), capture = slash < 0 ? undefined : item.slice(slash + 1);
  require(fixtures.some(value => value.name === fixture), `Unknown fixture: ${fixture}`);
  if (capture === undefined) selected.set(fixture, undefined);
  else {
    require(capture.length > 0, "Capture name is empty");
    if (selected.has(fixture) && selected.get(fixture) === undefined) continue;
    const names = selected.get(fixture) ?? new Set<string>();
    names.add(capture); selected.set(fixture, names);
  }
}
rmSync(resolve(root, "build/koa-visual/output"), { recursive: true, force: true });
const pixels = new References(resolve(root, "koa/visual/__Snapshots__"), resolve(root, "build/koa-visual/output"), process.env.RECORD === "1");
const failures: string[] = [];
const browser = await webkit.launch({ headless: true, timeout: 15000 });
function message(error: unknown): string {
  if (error instanceof AggregateError) return `${error.message}: ${error.errors.map(message).join("; ")}`;
  return error instanceof Error ? error.stack ?? error.message : String(error);
}
async function finish(context: Context): Promise<void> {
  try { await context.finish(); }
  catch (error) {
    const failure = `${context.fixture} cleanup: ${message(error)}`;
    failures.push(failure); console.log(`FAIL ${failure}`);
  }
}
let shared: Context | undefined;
try {
  for (const fixture of fixtures) {
    if (selected.size && !selected.has(fixture.name)) continue;
    if (!fixture.setup && shared) { const previous = shared; shared = undefined; await finish(previous); }
    const started = performance.now();
    await new Promise<void>(resolve => process.stdout.write(`FIXTURE ${fixture.name}\n`, () => resolve()));
    const context = new Context(root, fixture.name, selected.get(fixture.name), pixels);
    const differences = pixels.different + pixels.missing;
    let failed = false;
    try {
      await run(context, browser, fixture.setup ? shared?.browser : undefined);
      if (context.selection) for (const capture of context.selection) require(context.captured.has(capture), `Unknown capture selection: ${capture}`);
    } catch (error) {
      failed = true;
      const failure = `${fixture.name}: ${message(error)}`;
      failures.push(failure); console.log(`FAIL ${failure}`);
    } finally {
      failed ||= pixels.different + pixels.missing !== differences;
      if (fixture.setup && !shared && !failed) shared = context;
      if (failed && shared) { const previous = shared; shared = undefined; await finish(previous); }
      if (context !== shared) await finish(context);
      console.log(`TIME ${fixture.name} ${((performance.now() - started) / 1000).toFixed(3)}s`);
    }
  }
} finally {
  try { if (shared) { const previous = shared; shared = undefined; await finish(previous); } }
  finally { await deadline("browser shutdown", 5, browser.close()); }
}
console.log(`VISUAL pass=${pixels.equal} diff=${pixels.different} missing=${pixels.missing} errors=${failures.length}`);
if (failures.length || pixels.different || pixels.missing) process.exitCode = 1;
