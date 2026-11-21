import { crc32, deflateSync, inflateSync } from "node:zlib";
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";

export type Pixels = { width: number; height: number; rgba: Buffer };
const signature = Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]);
function premultiplied(image: Pixels, index: number): number {
  return index % 4 === 3 ? image.rgba[index] : Math.round(image.rgba[index] * image.rgba[index - index % 4 + 3] / 255);
}
function chunk(type: string, data: Buffer): Buffer {
  const body = Buffer.concat([Buffer.from(type), data]);
  const result = Buffer.alloc(body.length + 8);
  result.writeUInt32BE(data.length);
  body.copy(result, 4);
  result.writeUInt32BE(crc32(body), result.length - 4);
  return result;
}
function dimensions(width: number, height: number): void {
  if (!Number.isSafeInteger(width) || !Number.isSafeInteger(height) || width <= 0 || height <= 0 || width * height > 100_000_000) throw Error("Invalid PNG dimensions");
}
export function encode(image: Pixels): Buffer {
  const { width, height, rgba } = image;
  dimensions(width, height);
  if (rgba.length !== width * height * 4) throw Error("Invalid RGBA length");
  const header = Buffer.alloc(13);
  header.writeUInt32BE(width);
  header.writeUInt32BE(height, 4);
  header[8] = 8;
  header[9] = 6;
  const rows = Buffer.alloc(height * (width * 4 + 1));
  for (let y = 0; y < height; y++) rgba.copy(rows, y * (width * 4 + 1) + 1, y * width * 4, (y + 1) * width * 4);
  return Buffer.concat([signature, chunk("IHDR", header), chunk("IDAT", deflateSync(rows)), chunk("IEND", Buffer.alloc(0))]);
}
export function decode(png: Buffer): Pixels {
  if (!png.subarray(0, 8).equals(signature)) throw Error("Invalid PNG signature");
  let width = 0, height = 0, channels = 0, ended = false, offset = 8;
  const compressed: Buffer[] = [];
  while (offset < png.length) {
    if (offset + 12 > png.length) throw Error("Truncated PNG chunk");
    const length = png.readUInt32BE(offset), end = offset + length + 12;
    if (end > png.length) throw Error("Truncated PNG data");
    const type = png.toString("ascii", offset + 4, offset + 8), data = png.subarray(offset + 8, end - 4);
    if (crc32(png.subarray(offset + 4, end - 4)) !== png.readUInt32BE(end - 4)) throw Error("Invalid PNG CRC");
    if (offset === 8 && type !== "IHDR") throw Error("PNG header is missing");
    if (type === "IHDR") {
      if (offset !== 8 || length !== 13) throw Error("Invalid PNG header");
      width = data.readUInt32BE(0); height = data.readUInt32BE(4);
      dimensions(width, height);
      const color = data[9];
      channels = color === 0 ? 1 : color === 2 ? 3 : color === 4 ? 2 : color === 6 ? 4 : 0;
      if (data[8] !== 8 || !channels || data[10] !== 0 || data[11] !== 0 || data[12] !== 0) throw Error("Unsupported PNG format");
    } else if (type === "IDAT") compressed.push(data);
    else if (type === "IEND") {
      if (length !== 0 || end !== png.length) throw Error("Invalid PNG end");
      ended = true; break;
    } else if (type === "tRNS" || type.charCodeAt(0) < 97) throw Error(`Unsupported PNG chunk: ${type}`);
    offset = end;
  }
  if (!ended || !compressed.length) throw Error("Incomplete PNG");
  const stride = width * channels, size = height * (stride + 1);
  const rows = inflateSync(Buffer.concat(compressed), { maxOutputLength: size });
  if (rows.length !== size) throw Error("Invalid PNG scanline length");
  const raw = Buffer.alloc(height * stride);
  for (let y = 0; y < height; y++) {
    const filter = rows[y * (stride + 1)];
    if (filter > 4) throw Error("Unsupported PNG filter");
    for (let x = 0; x < stride; x++) {
      const index = y * stride + x, left = x >= channels ? raw[index - channels] : 0;
      const up = y ? raw[index - stride] : 0, corner = y && x >= channels ? raw[index - stride - channels] : 0;
      const p = left + up - corner, a = Math.abs(p - left), b = Math.abs(p - up), c = Math.abs(p - corner);
      const predictor = filter === 0 ? 0 : filter === 1 ? left : filter === 2 ? up : filter === 3 ? Math.floor((left + up) / 2) : a <= b && a <= c ? left : b <= c ? up : corner;
      raw[index] = (rows[y * (stride + 1) + x + 1] + predictor) & 255;
    }
  }
  const rgba = Buffer.alloc(width * height * 4);
  for (let pixel = 0; pixel < width * height; pixel++) {
    const source = pixel * channels, target = pixel * 4, gray = channels <= 2;
    rgba[target] = raw[source];
    rgba[target + 1] = raw[source + (gray ? 0 : 1)];
    rgba[target + 2] = raw[source + (gray ? 0 : 2)];
    rgba[target + 3] = channels === 2 || channels === 4 ? raw[source + channels - 1] : 255;
  }
  return { width, height, rgba };
}
export function crop(image: Pixels, x: number, y: number, width: number, height: number): Pixels {
  dimensions(width, height);
  if (![x, y].every(Number.isSafeInteger) || x < 0 || y < 0 || x + width > image.width || y + height > image.height) throw Error("Crop is outside the image");
  const rgba = Buffer.alloc(width * height * 4);
  for (let row = 0; row < height; row++) image.rgba.copy(rgba, row * width * 4, ((y + row) * image.width + x) * 4, ((y + row) * image.width + x + width) * 4);
  return { width, height, rgba };
}
export class References {
  equal = 0;
  different = 0;
  missing = 0;
  readonly references: string;
  readonly output: string;
  readonly record: boolean;
  constructor(references: string, output: string, record: boolean) {
    this.references = references; this.output = output; this.record = record;
    mkdirSync(output, { recursive: true });
  }
  verify(actual: Pixels, capture: string, owner: string, fixture: string): void {
    const name = `${owner.split("(")[0]}.${capture}.png`, reference = join(this.references, name), label = `${fixture}/${capture}`;
    if (this.record) { writeFileSync(reference, encode(actual)); console.log(`RECORD ${label}`); return; }
    if (!existsSync(reference)) {
      this.missing++; writeFileSync(join(this.output, name), encode(actual)); console.log(`MISSING ${label}`); return;
    }
    const old = decode(readFileSync(reference)), sameSize = old.width === actual.width && old.height === actual.height;
    let delta = 0;
    if (sameSize) for (let index = 0; index < actual.rgba.length; index++) delta = Math.max(delta, Math.abs(premultiplied(actual, index) - premultiplied(old, index)));
    if (sameSize && delta <= 1) { this.equal++; return; }
    this.different++;
    writeFileSync(join(this.output, name), encode(actual));
    const width = Math.max(old.width, actual.width), height = Math.max(old.height, actual.height), rgba = Buffer.alloc(width * height * 4);
    for (let y = 0; y < height; y++) for (let x = 0; x < width; x++) for (let channel = 0; channel < 4; channel++) {
      const before = x < old.width && y < old.height ? premultiplied(old, (y * old.width + x) * 4 + channel) : 0;
      const after = x < actual.width && y < actual.height ? premultiplied(actual, (y * actual.width + x) * 4 + channel) : 0;
      rgba[(y * width + x) * 4 + channel] = channel === 3 ? 255 : Math.abs(before - after);
    }
    writeFileSync(join(this.output, name.replace(/\.png$/, ".diff.png")), encode({ width, height, rgba }));
    console.log(`DIFF ${label} max_delta=${sameSize ? delta : "dimension-change"} actual=${actual.width}x${actual.height} reference=${old.width}x${old.height}`);
  }
}
