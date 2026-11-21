import type { Page } from "playwright";
import { crop, decode, type Pixels } from "./pixels.ts";
import { deadline } from "./deadline.ts";

export async function js<T = unknown>(page: Page, source: string, seconds = 10): Promise<T> {
  return deadline(`JavaScript: ${source}`, seconds, page.evaluate<T>(`(async()=>await (${source}))()`));
}
export async function ready(page: Page, seconds = 5): Promise<void> {
  await js(page, `new Promise((resolve, reject) => {
    let stopped = false, events = 0, previous = "", stable = 0, last = "", turnTimer;
    const bump = () => { events += 1; };
    document.addEventListener("scroll", bump, true);
    const finish = (done, value) => { if (stopped) return; stopped = true; clearTimeout(timer); clearTimeout(turnTimer); document.removeEventListener("scroll", bump, true); done(value); };
    const timer = setTimeout(() => finish(reject, Error("Capture still changing: " + last)), ${seconds * 1000});
    const signature = () => JSON.stringify([innerWidth, innerHeight, scrollX, scrollY, Array.from(document.querySelectorAll("*")).map(element => { const r = element.getBoundingClientRect(); return [r.x, r.y, r.width, r.height].map(Math.round); })]);
    const decoded = Promise.all(Array.from(document.images).map(image => new Promise(done => {
      const ready = () => image.naturalWidth > 0 ? image.decode().catch(() => {}).then(done) : done();
      if (image.complete) ready(); else { image.addEventListener("load", ready, { once: true }); image.addEventListener("error", done, { once: true }); }
    })));
    async function turn() {
      await document.fonts.ready; await decoded;
      if (stopped) return;
      const seen = events, now = signature();
      await new Promise(done => { turnTimer = setTimeout(done, 0); });
      if (stopped) return;
      last = "images=" + Array.from(document.images).filter(image => !image.complete).length + " events=" + (events - seen) + " bounds=" + (now === previous ? "unchanged" : "changed");
      stable = events === seen && now === previous ? stable + 1 : 0; previous = now;
      if (stable >= 2) finish(resolve, true); else turnTimer = setTimeout(turn, 0);
    }
    turn();
  })`, seconds);
}
export type Insets = { top: number; left: number; bottom: number; right: number };
export async function snapshot(page: Page, selector?: string, padding: Insets = { top: 0, left: 0, bottom: 0, right: 0 }, paintRetry?: (src: string) => Promise<void>): Promise<Pixels> {
  const deadline = performance.now() + 5000;
  let image: Pixels;
  let bounds: { left: number; top: number; right: number; bottom: number } | null = null;
  const rectangle = selector ? `(()=>{const rects=Array.from(document.querySelectorAll(${JSON.stringify(selector)}),e=>e.getBoundingClientRect());if(!rects.length||!rects.every(r=>[r.x,r.y,r.width,r.height].every(Number.isFinite)&&r.width>0&&r.height>0))throw Error('Missing or invalid crop rectangles');return{left:Math.min(...rects.map(r=>r.left)),top:Math.min(...rects.map(r=>r.top)),right:Math.max(...rects.map(r=>r.right)),bottom:Math.max(...rects.map(r=>r.bottom))}})()` : "null";
  for (;;) {
    await js(page, "Promise.all(document.getAnimations().filter(animation=>animation.animationName==='dots-bounce'||animation.animationName==='burn').map(animation=>{animation.pause();animation.currentTime=0;return animation.ready}))");
    await ready(page, Math.max(0.1, (deadline - performance.now()) / 1000));
    const rects: { src: string; x: number; y: number; w: number; h: number }[] = await page.evaluate(`Array.from(document.images).filter(i=>i.complete&&i.naturalWidth>0).map(i=>{let r=i.getBoundingClientRect(),box={l:r.left,t:r.top,r:r.right,b:r.bottom};for(let n=i.parentElement;n;n=n.parentElement){if(getComputedStyle(n).overflow==='visible')continue;const c=n.getBoundingClientRect();box={l:Math.max(box.l,c.left),t:Math.max(box.t,c.top),r:Math.min(box.r,c.right),b:Math.min(box.b,c.bottom)}}box={l:Math.max(box.l,0),t:Math.max(box.t,0),r:Math.min(box.r,innerWidth),b:Math.min(box.b,innerHeight)};const w=box.r-box.l,h=box.b-box.t;return{src:i.src,x:box.l+w/4,y:box.t+h/4,w:w/2,h:h/2,ok:w>=16&&h>=16&&document.elementFromPoint(box.l+w/2,box.t+h/2)===i}}).filter(r=>r.ok)`);
    const before: typeof bounds = await js(page, rectangle);
    image = decode(await page.screenshot({ type: "png", scale: "device", timeout: 10000 }));
    bounds = await js(page, rectangle);
    if (JSON.stringify(before) !== JSON.stringify(bounds)) {
      if (performance.now() >= deadline) throw Error(`Snapshot crop ${selector} moved: before=${JSON.stringify(before)} after=${JSON.stringify(bounds)}`);
      continue;
    }
    const captured = image;
    const empty = rects.find(rect => {
      let first: string | undefined;
      for (let y = Math.floor(rect.y * 2); y < Math.floor((rect.y + rect.h) * 2); y += 3) for (let x = Math.floor(rect.x * 2); x < Math.floor((rect.x + rect.w) * 2); x += 3) {
        const color = captured.rgba.subarray((y * captured.width + x) * 4, (y * captured.width + x) * 4 + 4).toString("hex");
        first ??= color;
        if (color !== first) return false;
      }
      return true;
    });
    if (!empty) break;
    if (performance.now() >= deadline) throw Error(`Image not painted in the snapshot: ${empty.src}`);
    await paintRetry?.(empty.src);
  }
  if (!bounds) return image;
  if (!Object.values(padding).every(value => Number.isFinite(value) && value >= 0)) throw Error("Invalid crop padding");
  const left = bounds.left - padding.left, top = bounds.top - padding.top;
  const right = bounds.right + padding.right, bottom = bounds.bottom + padding.bottom;
  const viewport = page.viewportSize();
  if (!viewport || left < 0 || top < 0 || right > viewport.width || bottom > viewport.height) throw Error(`Snapshot crop ${selector}: padded rectangle is outside the page`);
  const x = Math.floor(left * 2), y = Math.floor(top * 2);
  return crop(image, x, y, Math.ceil(right * 2) - x, Math.ceil(bottom * 2) - y);
}
