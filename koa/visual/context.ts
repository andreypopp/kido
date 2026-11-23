import { spawn, type ChildProcess } from "node:child_process";
import { readFileSync, mkdirSync, rmSync } from "node:fs";
import { join } from "node:path";
import { isDeepStrictEqual } from "node:util";
import type { Browser, BrowserContext, Page } from "playwright";
import { js, snapshot, type Insets } from "./capture.ts";
import type { Pixels, References } from "./pixels.ts";
import { deadline } from "./deadline.ts";

export const koaIdle = "!document.querySelector('#field').inert&&document.querySelector('#transcript [aria-label=working]')===null";
export const koaWorking = "document.querySelector('#transcript [aria-label=working]')!==null";
export const paneFocus = "window.koaFocused=true;";
export const hideLatest = "document.addEventListener('DOMContentLoaded',()=>{const style=document.createElement('style');style.textContent='#latest{display:none!important}';document.head.append(style)});";
export function require(condition: unknown, message = "Condition failed"): asserts condition { if (!condition) throw Error(message); }
export function equal(actual: unknown, expected: unknown, message = ""): void { require(isDeepStrictEqual(actual, expected), `${message}: ${JSON.stringify(actual)} != ${JSON.stringify(expected)}`); }
export class Context {
  readonly root: string;
  readonly fixture: string;
  readonly selection: Set<string> | undefined;
  readonly pixels: References;
  readonly captured = new Set<string>();
  readonly cleanup: (() => Promise<void>)[] = [];
  browserContext?: BrowserContext;
  browser?: Page;
  documents = 0;
  paintRetry?: (src: string) => Promise<void>;
  private replay?: ChildProcess;
  private replayExited?: Promise<void>;
  private assets?: string;
  constructor(root: string, fixture: string, selection: Set<string> | undefined, pixels: References) {
    this.root = root; this.fixture = fixture; this.selection = selection; this.pixels = pixels;
  }
  get name(): string { return `testKoaWebview${this.fixture}`; }
  themeScript(theme: "light" | "dark"): string {
    const json = readFileSync(join(this.root, `koa/testdata/theme-${theme}.json`), "utf8");
    JSON.parse(json);
    return `(()=>{window.ko=${json};const apply=()=>{for(const [k,v] of Object.entries(ko.theme))document.documentElement.style.setProperty(k,v)};if(document.documentElement)apply();else{const observer=new MutationObserver(()=>{if(document.documentElement){apply();observer.disconnect()}});observer.observe(document,{childList:true,subtree:true})}})()`;
  }
  async setTheme(theme: "light" | "dark"): Promise<void> {
    require(this.browser);
    await this.browser.emulateMedia({ colorScheme: theme });
    await js(this.browser, `(()=>{${this.themeScript(theme)};window.dispatchEvent(new Event('ko-theme'));return true})()`);
  }
  replayRoot(): string {
    require(!this.assets, "A fixture has only one replay root");
    let hash = 2166136261;
    for (const byte of Buffer.from(this.name)) hash = Math.imul(hash ^ byte, 16777619) >>> 0;
    const alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789";
    let suffix = "";
    for (let index = 0; index < 6; index++) { suffix += alphabet[hash % 62]; hash = (Math.floor(hash / 62) + Math.imul(hash, 7)) >>> 0; }
    const overrides: Record<string, string> = { testKoaWebviewCommandsNarrow: "obuV5x", testKoaWebviewComposerFootExitedWide: "C1oE9w", testKoaWebviewFailed: "27aE7O" };
    this.assets = `/tmp/ko-vt-${overrides[this.name] ?? suffix}`;
    rmSync(this.assets, { recursive: true, force: true });
    mkdirSync(this.assets, { recursive: true });
    return this.assets;
  }
  async start(browser: Browser, module: string, key: string, assets: string, viewport: { width: number; height: number }, scripts: string[]): Promise<Page> {
    const context = await browser.newContext({ viewport, deviceScaleFactor: 2, timezoneId: "America/Los_Angeles", colorScheme: "light" });
    this.browserContext = context;
    const locale = "for(const method of ['toLocaleTimeString','toLocaleDateString']){const native=Date.prototype[method];Date.prototype[method]=function(locale,options){return native.call(this,locale,{...options,timeZone:'America/Los_Angeles'})}};Date.prototype.toDateString=function(){return this.toLocaleDateString('en-US')};";
    await context.addInitScript({ content: [locale, this.themeScript("light"), ...scripts].join(";\n") });
    const page = await context.newPage();
    this.browser = page;
    page.on("load", () => { this.documents++; });
    let stderr = Buffer.alloc(0);
    const child = spawn(process.execPath, [join(this.root, "koa/testdata/replay.ts"), "--browser", "--headless", module, key, assets], {
      cwd: this.root, env: { ...process.env, TZ: "America/Los_Angeles", PATH: `${join(this.root, "koa/node_modules/.bin")}:${process.env.PATH ?? "/usr/bin:/bin"}` }, stdio: ["ignore", "pipe", "pipe"],
    });
    this.replay = child;
    this.replayExited = new Promise(resolve => { child.once("exit", () => resolve()); child.once("error", () => resolve()); });
    child.stderr.on("data", (chunk: Buffer) => { stderr = Buffer.concat([stderr, chunk]).subarray(-65536); });
    const url = await deadline("replay URL", 15, new Promise<string>((resolve, reject) => {
      let address = Buffer.alloc(0), published = false;
      child.stdout.on("data", (chunk: Buffer) => {
        if (published) return;
        address = Buffer.concat([address, chunk]);
        const newline = address.indexOf(10);
        if (newline > 65536 || (newline < 0 && address.length > 65536)) { published = true; reject(Error("Replay URL line is too long")); return; }
        if (newline < 0) return;
        published = true;
        try {
          const value: unknown = JSON.parse(address.subarray(0, newline).toString());
          require(typeof value === "object" && value !== null && "url" in value && typeof value.url === "string", "Invalid replay URL");
          resolve(value.url);
        } catch (error) { reject(error); }
      });
      child.once("error", reject);
      child.once("exit", () => { if (!published) reject(Error(`Replay exited early: ${stderr.toString()}`)); });
    }));
    this.cleanup.push(async () => {
      const response = await fetch(new URL("/replay/status", url), { signal: AbortSignal.timeout(10000) });
      require(response.ok, `Replay status: HTTP ${response.status}`);
      const status: unknown = await response.json();
      require(typeof status === "object" && status !== null && "step" in status && "total" in status && "mismatches" in status && "pending" in status, "Invalid replay status");
      equal(status.step, status.total, "The script ran to its end");
      equal(status.mismatches, 0, "No request left the script");
      require(Array.isArray(status.pending) && status.pending.length === 0, "No reply stays held");
    });
    await page.goto(url, { timeout: 15000, waitUntil: "load" });
    return page;
  }
  async finish(): Promise<void> {
    const failures: unknown[] = [];
    for (const block of this.cleanup.reverse()) try { await block(); } catch (error) { failures.push(error); }
    try { await deadline("browser context shutdown", 5, this.browserContext?.close() ?? Promise.resolve()); } catch (error) { failures.push(error); }
    const child = this.replay;
    if (child && child.exitCode === null && child.signalCode === null) {
      child.kill("SIGTERM");
      try { await deadline("replay termination", 5, this.replayExited ?? Promise.resolve()); }
      catch (error) {
        child.kill("SIGKILL");
        try { await deadline("replay forced termination", 5, this.replayExited ?? Promise.resolve()); } catch (forced) { failures.push(forced); }
        failures.push(error);
      }
    }
    if (this.assets) rmSync(this.assets, { recursive: true, force: true });
    if (failures.length) throw new AggregateError(failures, "Fixture cleanup failed");
  }
  async until(page: Page, condition: string, seconds = 10): Promise<void> {
    try { await page.waitForFunction(condition, undefined, { polling: 100, timeout: seconds * 1000 }); }
    catch (error) {
      const details = await js(page, "({latest:document.querySelector('#latest')?.textContent,field:document.querySelector('#prompt .cm-placeholder')?.textContent,items:(document.querySelector('#items')?.textContent||'').slice(-400)})").catch(() => undefined);
      throw Error(`Webview condition deadline: ${condition} | ${JSON.stringify(details)}`, { cause: error });
    }
  }
  async measured(page: Page, selector: string, seconds = 5): Promise<void> {
    await js(page, `new Promise((resolve,reject)=>{const targets=[...document.querySelectorAll(${JSON.stringify(selector)})];if(!targets.length){reject(Error('Koa measurement target missing: '+${JSON.stringify(selector)}));return}const timer=setTimeout(()=>{observer.disconnect();reject(Error('Koa measurement deadline: '+${JSON.stringify(selector)}))},${seconds * 1000});const observer=new ResizeObserver(()=>{clearTimeout(timer);observer.disconnect();resolve(true)});targets.forEach(target=>observer.observe(target))})`, seconds);
  }
  async pageSnapshot(capture: string, owner: string, selector?: string, padding?: Insets): Promise<Pixels> {
    require(this.browser);
    const image = await snapshot(this.browser, selector, padding, this.paintRetry);
    if (this.selection && !this.selection.has(capture)) return image;
    this.pixels.verify(image, capture, owner, this.fixture);
    this.captured.add(capture);
    return image;
  }
}
