import assert from "node:assert/strict";
import { test } from "node:test";
import { deflateSync } from "node:zlib";
import { decode, encode, crop, References } from "./pixels.ts";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

function png(color: number, width: number, height: number, rows: number[]): Buffer {
  function chunk(type: string, data: Buffer): Buffer {
    const body = Buffer.concat([Buffer.from(type), data]);
    let crc = 0xffffffff;
    for (const byte of body) {
      crc ^= byte;
      for (let bit = 0; bit < 8; bit++) crc = crc & 1 ? 0xedb88320 ^ (crc >>> 1) : crc >>> 1;
    }
    const size = Buffer.alloc(4), checksum = Buffer.alloc(4);
    size.writeUInt32BE(data.length); checksum.writeUInt32BE((crc ^ 0xffffffff) >>> 0);
    return Buffer.concat([size, body, checksum]);
  }
  const header = Buffer.from([0, 0, 0, width, 0, 0, 0, height, 8, color, 0, 0, 0]);
  return Buffer.concat([Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]), chunk("IHDR", header), chunk("IDAT", deflateSync(Buffer.from(rows))), chunk("IEND", Buffer.alloc(0))]);
}
test("PNG filters reconstruct known RGB scanlines", () => {
  const expected = Buffer.from([10, 20, 30, 255, 40, 50, 60, 255, 15, 25, 35, 255, 60, 70, 80, 255]);
  const rows = [
    [0, 10, 20, 30, 40, 50, 60, 0, 15, 25, 35, 60, 70, 80],
    [1, 10, 20, 30, 30, 30, 30, 1, 15, 25, 35, 45, 45, 45],
    [2, 10, 20, 30, 40, 50, 60, 2, 5, 5, 5, 20, 20, 20],
    [3, 10, 20, 30, 35, 40, 45, 3, 10, 15, 20, 33, 33, 33],
    [4, 10, 20, 30, 30, 30, 30, 4, 5, 5, 5, 20, 20, 20],
  ];
  for (const row of rows) assert.deepEqual(decode(png(2, 2, 2, row)).rgba, expected);
});
test("PNG handles RGBA and grayscale without premultiplication", () => {
  const cases: [number, number[], number[]][] = [
    [6, [0, 200, 100, 50, 17], [200, 100, 50, 17]],
    [0, [0, 123], [123, 123, 123, 255]],
    [4, [0, 123, 17], [123, 123, 123, 17]],
  ];
  for (const [color, rows, rgba] of cases) assert.deepEqual(decode(png(color, 1, 1, rows)).rgba, Buffer.from(rgba));
});
test("PNG encoder and crop preserve exact pixels", () => {
  const image = { width: 2, height: 2, rgba: Buffer.from([1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16]) };
  assert.deepEqual(decode(encode(image)), image);
  assert.deepEqual(crop(image, 1, 0, 1, 2), { width: 1, height: 2, rgba: Buffer.from([5, 6, 7, 8, 13, 14, 15, 16]) });
  assert.throws(() => crop(image, -1, 0, 1, 1), /outside/);
  assert.throws(() => crop(image, 0, 0, 3, 1), /outside/);
});
test("comparison uses premultiplied channels with a maximum delta of one", t => {
  const root = mkdtempSync(join(tmpdir(), "koa-pixels-"));
  t.after(() => rmSync(root, { recursive: true, force: true }));
  const references = new References(root, join(root, "output"), false);
  writeFileSync(join(root, "owner.transparent.png"), encode({ width: 1, height: 1, rgba: Buffer.from([10, 20, 30, 0]) }));
  references.verify({ width: 1, height: 1, rgba: Buffer.from([200, 100, 50, 0]) }, "transparent", "owner", "fixture");
  writeFileSync(join(root, "owner.translucent.png"), encode({ width: 1, height: 1, rgba: Buffer.from([64, 64, 64, 128]) }));
  references.verify({ width: 1, height: 1, rgba: Buffer.from([66, 64, 64, 128]) }, "translucent", "owner", "fixture");
  assert.deepEqual([references.equal, references.different], [2, 0]);
  references.verify({ width: 1, height: 1, rgba: Buffer.from([68, 64, 64, 128]) }, "translucent", "owner", "fixture");
  assert.deepEqual([references.equal, references.different], [2, 1]);
});
test("PNG rejects corrupt and unsupported input", () => {
  const valid = png(6, 1, 1, [0, 1, 2, 3, 4]), corrupt = Buffer.from(valid);
  corrupt[40] ^= 1;
  assert.throws(() => decode(corrupt), /CRC/);
  assert.throws(() => decode(valid.subarray(0, -1)), /Truncated/);
  assert.throws(() => decode(png(3, 1, 1, [0, 1])), /Unsupported/);
  assert.throws(() => decode(png(6, 1, 1, [5, 1, 2, 3, 4])), /filter/);
});
