import assert from "node:assert/strict";
import { test } from "node:test";
import { imageInfo } from "./koa-image.ts";

const png = Buffer.from("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aWQAAAABJRU5ErkJggg==", "base64");

test("image headers identify pi's formats and dimensions without decoding pixels", () => {
  assert.deepEqual(imageInfo(png), { mimeType: "image/png", width: 1, height: 1 });
  const gif = Buffer.from("47494638396120001000", "hex");
  assert.deepEqual(imageInfo(gif), { mimeType: "image/gif", width: 32, height: 16 });
  const jpeg = Buffer.from("ffd8ffe000040000ffc00008080012003400", "hex");
  assert.deepEqual(imageInfo(jpeg), { mimeType: "image/jpeg", width: 52, height: 18 });
  const webp = Buffer.from("524946461600000057454250565038580a000000000000003f00001f0000", "hex");
  assert.deepEqual(imageInfo(webp), { mimeType: "image/webp", width: 64, height: 32 });
  const lossless = Buffer.from("5249464616000000574542505650384c050000002f3f000800", "hex");
  assert.deepEqual(imageInfo(lossless), { mimeType: "image/webp", width: 64, height: 33 });
  const lossy = Buffer.from("524946461600000057454250565038200a0000000000009d012a40002000", "hex");
  assert.deepEqual(imageInfo(lossy), { mimeType: "image/webp", width: 64, height: 32 });
  const bmp = Buffer.alloc(54);
  bmp.write("BM"); bmp.writeUInt32LE(58, 2); bmp.writeUInt32LE(54, 10); bmp.writeUInt32LE(40, 14); bmp.writeInt32LE(13, 18); bmp.writeInt32LE(-7, 22); bmp.writeUInt16LE(1, 26); bmp.writeUInt16LE(24, 28);
  assert.deepEqual(imageInfo(bmp), { mimeType: "image/bmp", width: 13, height: 7 });
  for (const bytes of [png, gif, jpeg, webp, lossless, lossy, bmp]) for (let length = 0; length < bytes.length; length++) assert.doesNotThrow(() => imageInfo(bytes.subarray(0, length)));
  assert.deepEqual(imageInfo(Buffer.concat([Buffer.alloc(5), png]).subarray(5)), { mimeType: "image/png", width: 1, height: 1 });
});

test("animated PNG and JPEG-LS are outside pi's supported image set", () => {
  const animated = Buffer.concat([png.subarray(0, 33), Buffer.from("000000086163544c000000010000000000000000", "hex")]);
  assert.equal(imageInfo(animated), undefined);
  assert.equal(imageInfo(Buffer.from("ffd8fff70000", "hex")), undefined);
  assert.equal(imageInfo(Buffer.from("<svg/>")), undefined);
  assert.equal(imageInfo(Buffer.from("unknown")), undefined);
});
