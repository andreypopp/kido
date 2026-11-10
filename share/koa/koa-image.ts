export const imageExtensions: Record<string, string | undefined> = { 'image/png': 'png', 'image/jpeg': 'jpg', 'image/gif': 'gif', 'image/webp': 'webp', 'image/bmp': 'bmp' };

const ascii = (bytes: Uint8Array, offset: number, text: string) => bytes.length >= offset + text.length && [...text].every((character, index) => bytes[offset + index] === character.charCodeAt(0));

export function imageInfo(bytes: Uint8Array): { mimeType: string; width?: number; height?: number } | undefined {
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  const size = (width: number, height: number) => width > 0 && height > 0 ? { width, height } : undefined;
  if (bytes[0] === 255 && bytes[1] === 216 && bytes[2] === 255) {
    if (bytes[3] === 247) return;
    const info = { mimeType: "image/jpeg" };
    for (let offset = 2; offset < bytes.length;) {
      if (bytes[offset++] !== 255) continue;
      while (offset < bytes.length && bytes[offset] === 255) offset++;
      const marker = bytes[offset++];
      if (marker === undefined || marker === 218 || marker === 217 || offset + 2 > bytes.length) break;
      if (marker === 216 || marker === 1 || (marker >= 208 && marker <= 215)) continue;
      const length = view.getUint16(offset);
      if (length < 2 || offset + length > bytes.length) break;
      if ([192, 193, 194, 195, 197, 198, 199, 201, 202, 203, 205, 206, 207].includes(marker)) return { ...info, ...(length >= 7 ? size(view.getUint16(offset + 5), view.getUint16(offset + 3)) : undefined) };
      offset += length;
    }
    return info;
  }
  if ([137, 80, 78, 71, 13, 10, 26, 10].every((byte, index) => bytes[index] === byte) && bytes.length >= 16 && view.getUint32(8) === 13 && ascii(bytes, 12, "IHDR")) {
    for (let offset = 8; offset + 8 <= bytes.length;) {
      if (ascii(bytes, offset + 4, "acTL")) return;
      if (ascii(bytes, offset + 4, "IDAT")) break;
      const next = offset + view.getUint32(offset) + 12;
      if (next > bytes.length) break;
      offset = next;
    }
    return { mimeType: "image/png", ...(bytes.length >= 24 ? size(view.getUint32(16), view.getUint32(20)) : undefined) };
  }
  if (ascii(bytes, 0, "GIF87a") || ascii(bytes, 0, "GIF89a")) return { mimeType: "image/gif", ...(bytes.length >= 10 ? size(view.getUint16(6, true), view.getUint16(8, true)) : undefined) };
  if (ascii(bytes, 0, "RIFF") && ascii(bytes, 8, "WEBP")) {
    const info = { mimeType: "image/webp" };
    for (let offset = 12; offset + 8 <= bytes.length;) {
      const length = view.getUint32(offset + 4, true), data = offset + 8;
      if (data + length > bytes.length) break;
      if (ascii(bytes, offset, "VP8X") && length >= 10) return { ...info, ...size(1 + view.getUint8(data + 4) + view.getUint16(data + 5, true) * 256, 1 + view.getUint8(data + 7) + view.getUint16(data + 8, true) * 256) };
      if (ascii(bytes, offset, "VP8L") && length >= 5 && bytes[data] === 47) {
        const bits = view.getUint32(data + 1, true);
        return { ...info, ...size((bits & 16383) + 1, ((bits >>> 14) & 16383) + 1) };
      }
      if (ascii(bytes, offset, "VP8 ") && length >= 10 && bytes[data + 3] === 157 && bytes[data + 4] === 1 && bytes[data + 5] === 42) return { ...info, ...size(view.getUint16(data + 6, true) & 16383, view.getUint16(data + 8, true) & 16383) };
      offset = data + length + (length % 2);
    }
    return info;
  }
  if (ascii(bytes, 0, "BM") && bytes.length >= 26) {
    const length = view.getUint32(2, true), pixels = view.getUint32(10, true), dib = view.getUint32(14, true);
    if ((length && length < 26) || pixels < 14 + dib || (length && pixels >= length)) return;
    const core = dib === 12;
    if (!core && (dib < 40 || dib > 124 || bytes.length < 30)) return;
    if (view.getUint16(core ? 22 : 26, true) !== 1 || ![1, 4, 8, 16, 24, 32].includes(view.getUint16(core ? 24 : 28, true))) return;
    return { mimeType: "image/bmp", ...(core ? size(view.getUint16(18, true), view.getUint16(20, true)) : size(view.getInt32(18, true), Math.abs(view.getInt32(22, true)))) };
  }
}
