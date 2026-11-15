type Span = { text: string; bold: boolean; dim: boolean; fg?: number; bg?: number };
export type StyledLine = { byte: number; spans: Span[] };
type Style = Omit<Span, 'text'>;
type Mode = { kind: 'text' } | { kind: 'escape' } | { kind: 'csi'; params: string } | { kind: 'string'; escape: boolean } | { kind: 'intermediate' };

const ESC = 0x1b, BEL = 0x07;

function sgr(style: Style, params: string): Style {
  const codes = params.split(/[;:]/).map(code => code === '' ? 0 : Number(code));
  const next = { ...style };
  for (let i = 0; i < codes.length; i++) {
    const code = codes[i];
    if (code === 0) { next.bold = false; next.dim = false; delete next.fg; delete next.bg; }
    else if (code === 1) next.bold = true;
    else if (code === 2) next.dim = true;
    else if (code === 22) { next.bold = false; next.dim = false; }
    else if (code >= 30 && code <= 37) next.fg = code - 30;
    else if (code === 39) delete next.fg;
    else if (code >= 40 && code <= 47) next.bg = code - 40;
    else if (code === 49) delete next.bg;
    else if (code >= 90 && code <= 97) next.fg = code - 82;
    else if (code >= 100 && code <= 107) next.bg = code - 92;
    else if (code === 38 || code === 48) i += codes[i + 1] === 5 ? 2 : codes[i + 1] === 2 ? 4 : codes.length;
  }
  return next;
}

export function createOutput(start = 0, dropPartial = false) {
  const decoder = new TextDecoder('utf-8');
  let mode: Mode = { kind: 'text' };
  let style: Style = { bold: false, dim: false };
  let completed = 0, offset = start, dropping = dropPartial;
  let line: StyledLine = { byte: start, spans: [] };
  let returned = false, run: number[] = [];

  const add = (text: string) => {
    const clean = text.replace(/[\u0000-\u0008\u000b\u000c\u000e-\u001f\u007f-\u009f]/g, '');
    if (!clean) return;
    if (returned) { line.spans = []; returned = false; }
    const last = line.spans.at(-1);
    if (last && last.bold === style.bold && last.dim === style.dim && last.fg === style.fg && last.bg === style.bg) last.text += clean;
    else line.spans.push({ ...style, text: clean });
  };
  const flushText = (final: boolean) => {
    if (dropping) { run = []; if (final) decoder.decode(); return; }
    const bytes = Uint8Array.from(run);
    run = [];
    add(decoder.decode(bytes, { stream: !final }));
  };
  const newline = (lines: StyledLine[], next: number) => {
    lines.push(line);
    completed++;
    line = { byte: next, spans: [] };
    returned = false;
  };

  return {
    append(bytes: Uint8Array, final = false): { replaceFrom: number; lines: StyledLine[] } {
      const replaceFrom = completed, done: StyledLine[] = [];
      for (const byte of bytes) {
        offset++;
        if (mode.kind === 'text') {
          if (byte === ESC) { flushText(false); mode = { kind: 'escape' }; }
          else if (byte === 0x0a) {
            flushText(false);
            if (dropping) { dropping = false; line = { byte: offset, spans: [] }; returned = false; }
            else newline(done, offset);
          } else if (byte === 0x0d) { flushText(false); returned = true; }
          else if (!dropping) run.push(byte);
          continue;
        }
        if (mode.kind === 'escape') {
          if (byte === 0x5b) mode = { kind: 'csi', params: '' };
          else if (byte === 0x5d || byte === 0x50 || byte === 0x5f || byte === 0x5e || byte === 0x58) mode = { kind: 'string', escape: false };
          else if (byte >= 0x20 && byte <= 0x2f) mode = { kind: 'intermediate' };
          else mode = { kind: 'text' };
        } else if (mode.kind === 'intermediate') {
          if (byte < 0x20 || byte > 0x2f) mode = { kind: 'text' };
        } else if (mode.kind === 'csi') {
          if (byte >= 0x40 && byte <= 0x7e) {
            if (byte === 0x6d) style = sgr(style, mode.params);
            mode = { kind: 'text' };
          } else mode = { kind: 'csi', params: mode.params + String.fromCharCode(byte) };
        } else if (byte === BEL || mode.escape && byte === 0x5c) mode = { kind: 'text' };
        else mode = { kind: 'string', escape: byte === ESC };
      }
      flushText(final);
      const lines = [...done];
      if (line.spans.length) lines.push({ byte: line.byte, spans: line.spans.map(span => ({ ...span })) });
      return { replaceFrom, lines };
    },
  };
}
