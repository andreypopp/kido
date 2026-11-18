import { test } from "node:test";
import assert from "node:assert/strict";
import { createOutput, type StyledLine } from "./page/job-output.ts";

const enc = new TextEncoder();
const run = (chunks: Uint8Array[], start = 0, dropPartial = false): StyledLine[] => {
  const output = createOutput(start, dropPartial);
  const lines: StyledLine[] = [];
  chunks.forEach((chunk, i) => {
    const out = output.append(chunk, i === chunks.length - 1);
    lines.length = out.replaceFrom;
    lines.push(...out.lines);
  });
  return lines;
};
const text = (lines: StyledLine[]) => lines.map(line => line.spans.map(span => span.text).join(""));
const whole = (source: string) => run([enc.encode(source)]);
const SAMPLE = "plain \x1b[1;31mred bold\x1b[0m é€😀 \x1b[2mdim\x1b[22m\x1b[38;5;200mx\x1b[48;2;1;2;3my\x1b[39;49m\n\x1b]0;title\x07\x1b[2K\x1b[3Aend\r\nlast \x1b[92mgreen\x1b[0m";

test("the output is the same split at every byte boundary", () => {
  const bytes = enc.encode(SAMPLE);
  const expected = whole(SAMPLE);
  for (let i = 0; i <= bytes.length; i++) assert.deepEqual(run([bytes.subarray(0, i), bytes.subarray(i)]), expected, `split at ${i}`);
  assert.deepEqual(run(Array.from(bytes, (_, i) => bytes.subarray(i, i + 1))), expected);
});

test("SGR sets bold, dim and the sixteen colours, and consumes extended colours", () => {
  const [line] = whole("\x1b[1;31ma\x1b[0mb\x1b[2;102mc\x1b[22;49;39md\x1b[38;5;196me\x1b[48;2;9;9;9mf\x1b[38:2::1:2:3mg");
  assert.deepEqual(line?.spans, [
    { text: "a", bold: true, dim: false, fg: 1 },
    { text: "b", bold: false, dim: false },
    { text: "c", bold: false, dim: true, bg: 10 },
    { text: "defg", bold: false, dim: false },
  ]);
});

test("other escapes and control characters disappear, and markup stays text", () => {
  assert.deepEqual(text(whole("a\x1b[2Kb\x1b]8;;http://x\x1b\\c\x1bP1;2zz\x1b\\d\x07\x00\x08\x7f\u0085e<b>&amp;")), ["abcde<b>&amp;"]);
});

test("a carriage return collapses the line, CRLF keeps it", () => {
  assert.deepEqual(text(whole("10%\r50%\r100%\ndone\r\nmore\r")), ["100%", "done", "more"]);
  assert.deepEqual(text(run([enc.encode("a\r"), enc.encode("\nb\r"), enc.encode("c")])), ["a", "c"]);
});

test("lines carry the byte offset of their first byte", () => {
  assert.deepEqual(whole("ab\ncd\n\nef").map(line => line.byte), [0, 3, 6, 7]);
  assert.deepEqual(run([enc.encode("ab\ncd")], 100).map(line => line.byte), [100, 103]);
});

test("replaceFrom names the first line that an append changes", () => {
  const output = createOutput();
  assert.deepEqual(output.append(enc.encode("ab")), { replaceFrom: 0, lines: [{ byte: 0, spans: [{ text: "ab", bold: false, dim: false }] }] });
  const next = output.append(enc.encode("c\nd"));
  assert.equal(next.replaceFrom, 0);
  assert.deepEqual(text(next.lines), ["abc", "d"]);
  const last = output.append(enc.encode("e\n"));
  assert.equal(last.replaceFrom, 1);
  assert.deepEqual(text(last.lines), ["de"]);
});

test("an unfinished multibyte character or escape at the end is dropped", () => {
  assert.deepEqual(text(run([enc.encode("ab\x1b[3"), new Uint8Array()])), ["ab"]);
  assert.deepEqual(text(run([enc.encode("ab").slice(), Uint8Array.of(0xe2, 0x82)])), ["ab�"]);
});

test("a window that starts mid-line drops its first partial line and equals the tail of the whole", () => {
  const source = "one\ntwo \x1b[31mred\n\x1b[0mthree\nfour";
  const bytes = enc.encode(source);
  const cut = source.indexOf("red") + 1;
  const window = run([bytes.subarray(cut)], cut, true);
  assert.deepEqual(text(window), ["three", "four"]);
  assert.deepEqual(window.map(line => line.byte), [source.indexOf("\x1b[0mthree"), source.indexOf("four")]);
  assert.deepEqual(text(run([Uint8Array.of(0x80, 0x80), enc.encode("a\nb")], 0, true)), ["b"]);
  assert.deepEqual(run([bytes.subarray(cut, cut + 1)], cut, true), []);
});

test("a prepended chunk joined to the window equals the whole decode", () => {
  const bytes = enc.encode(SAMPLE);
  const cut = 20;
  const joined = new Uint8Array(bytes.length - 5);
  joined.set(bytes.subarray(5));
  assert.deepEqual(text(run([joined], 5, true)), text(run([bytes.subarray(5, cut), bytes.subarray(cut)], 5, true)));
});
