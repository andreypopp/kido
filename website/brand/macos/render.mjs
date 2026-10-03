import { chromium } from 'playwright';
import sharp from 'sharp';
import fs from 'node:fs';
const svg = fs.readFileSync('kido-appicon.svg', 'utf8');
const browser = await chromium.launch();
const page = await browser.newPage({ viewport: { width: 1024, height: 1024 } });
await page.setContent(`<html><body style="margin:0;background:transparent">${svg}</body></html>`);
const master = await page.locator('svg').screenshot({ omitBackground: true });
await browser.close();
fs.writeFileSync('kido-appicon-1024.png', master);
const set = 'AppIcon.appiconset', iconset = 'kido.iconset';
fs.mkdirSync(set, { recursive: true }); fs.mkdirSync(iconset, { recursive: true });
const images = [];
const buffers = new Map();
for (const s of [16, 32, 128, 256, 512]) for (const k of [1, 2]) {
  const px = s * k, name = `icon_${s}x${s}${k === 2 ? '@2x' : ''}.png`;
  if (!buffers.has(px)) buffers.set(px, await sharp(master).resize(px, px, { kernel: 'lanczos3' }).png().toBuffer());
  const buf = buffers.get(px);
  fs.writeFileSync(`${set}/${name}`, buf); fs.writeFileSync(`${iconset}/${name}`, buf);
  images.push({ size: `${s}x${s}`, idiom: 'mac', filename: name, scale: `${k}x` });
}
fs.writeFileSync(`${set}/Contents.json`, JSON.stringify({ images, info: { version: 1, author: 'xcode' } }, null, 2) + '\n');
