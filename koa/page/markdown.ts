import { Marked, type Token, type TokensList, type MarkedExtension } from 'marked';
import remend from 'remend';

export type Mark = { offset: number; mark: string; side: 'open' | 'close' };
export type Tail = { start: number; token: Token };
type RenderedBlock = { streaming: boolean; html?: string; marks: string; tail?: Tail };

const escape = (text: string) => text.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;').replaceAll('"', '&quot;');
const rendering: MarkedExtension = { renderer: {
  html: ({ text }) => escape(text),
  image: ({ text }) => escape(text),
  link({ href, tokens }) {
    const text = this.parser.parseInline(tokens);
    try {
      const url = new URL(href);
      return ['http:', 'https:', 'mailto:'].includes(url.protocol) ? `<a href="${escape(href)}">${text}</a>` : text;
    } catch { return text; }
  },
} };
const parser = new Marked(rendering);

const userParser = new Marked(rendering, { tokenizer: {
  blockquote(source) {
    const raw = source.match(/^(?: {0,3}>[^\n]*(?:\n|$))+/)?.[0];
    if (!raw) return;
    const text = raw.replace(/^ {0,3}> ?/gm, '');
    return { type: 'blockquote', raw, text, tokens: this.lexer.blockTokens(text) };
  },
} });

type Plain = { text: string; fence?: { block: number; ordinal: number } };
export function markdownPlain(source: string, fold: number, user = false): Plain[] {
  const plain = (token: Token): string => {
    if ('items' in token && Array.isArray(token.items)) return token.items.map(plain).join('\n');
    if (token.type === 'table') return [token.header, ...token.rows].map((row: { tokens: Token[] }[]) => row.map(cell => cell.tokens.map(plain).join('')).join('\t')).join('\n');
    if ('tokens' in token && token.tokens) return token.tokens.map(plain).join(token.type === 'blockquote' ? '\n' : '');
    return token.type === 'space' || token.type === 'hr' || token.type === 'def' ? '' : 'text' in token ? token.text : token.raw;
  };
  return (user ? userParser : parser).lexer(source.replace(/\r\n?/g, '\n')).flatMap((token, block): Plain[] => {
    if (token.type === 'code') {
      const lines = token.text.split('\n');
      return lines.length > fold ? [{ text: lines.slice(0, fold).join('\n') }, { text: lines.slice(fold).join('\n'), fence: { block, ordinal: 0 } }] : [{ text: token.text }];
    }
    const text = plain(token).trim();
    return text ? [{ text }] : [];
  });
}

const lexing: { boundary: number; references: number; around?: <T>(source: string, body: () => T) => T } = { boundary: 0, references: 0 };
export const instrument = (around: typeof lexing.around) => { lexing.around = around; };
export const fallbacks = () => lexing.boundary + lexing.references;
const defines = (tokens: readonly Token[]): boolean => tokens.some(token => token.type === 'def' || defines(('items' in token ? token.items : 'tokens' in token ? token.tokens : undefined) ?? []));

type Lexed = { source: string; tokens: TokensList; starts: number[] };

export function markdown(user = false) {
  const selectedParser = user ? userParser : parser;
  let blocks: RenderedBlock[] = [];
  let raw: string[] = [];
  let links = '';
  let lexed: Lexed | undefined;
  let input: string | undefined;
  const incremental = (old: Lexed, source: string, changed: number): { tokens: TokensList; references: string } | undefined => {
    const index = old.starts.findLastIndex(start => start <= changed), first = Math.max(0, index - 2);
    if (first === 0) return;
    if (links !== '{}' && defines(old.tokens.slice(first))) { lexing.references++; return; }
    const lexer = new selectedParser.Lexer(selectedParser.defaults), from = old.starts[first];
    lexer.tokens.links = Object.assign(Object.create(null), old.tokens.links);
    const added = lexer.lex(source.slice(from));
    if (added[0]?.raw !== old.tokens[first].raw || from + added.reduce((sum, token) => sum + token.raw.length, 0) !== source.length) { lexing.boundary++; return; }
    const references = JSON.stringify(added.links);
    if (references !== links) { lexing.references++; return; }
    return { tokens: Object.assign(old.tokens.slice(0, first).concat(added), { links: added.links }), references };
  };
  const render = (source: string, final: boolean, marks: readonly Mark[], changed: number) => {
    if (marks.length && source.includes('\r')) {
      const offsets = [0];
      for (let index = 0; index < source.length; index++) offsets.push(offsets[index] + (source[index] === '\r' && source[index + 1] === '\n' ? 0 : 1));
      marks = marks.map(mark => ({ ...mark, offset: offsets[mark.offset] }));
    }
    if (changed && source.includes('\r')) {
      let pairs = 0;
      for (let at = source.indexOf('\r\n'); at >= 0 && at + 1 < changed; at = source.indexOf('\r\n', at + 2)) pairs++;
      changed -= pairs;
    }
    source = source.replace(/\r\n?/g, '\n').replace(/[\uE010-\uE012]/g, '\uFFFD');
    const reused = lexed?.source === source ? { tokens: lexed.tokens, references: links } : lexed && changed ? incremental(lexed, source, changed) : undefined;
    const tokens = reused?.tokens ?? selectedParser.lexer(source);
    const lex = (text: string) => { const lexer = new selectedParser.Lexer(selectedParser.defaults); lexer.tokens.links = tokens.links; return lexer.lex(text); };
    const references = reused?.references ?? JSON.stringify(tokens.links);
    const previous = references === links ? blocks : [];
    const previousRaw = raw;
    raw = tokens.map(token => token.raw);
    links = references;
    let offset = 0, unchanged = true;
    const starts: number[] = [];
    blocks = tokens.map((token, index) => {
      const tail = index === tokens.length - 1;
      const streaming = tail && !final;
      const old = previous[index];
      const start = offset; offset += token.raw.length; starts.push(start);
      const local = marks.length ? marks.filter(mark => {
        const end = mark.side === 'close';
        return (mark.offset > start || mark.offset === start && (!end || index === 0)) && (mark.offset < offset || mark.offset === offset && (end || tail));
      }) : [];
      const signature = local.length ? JSON.stringify(local.map(mark => [mark.offset - start, mark.mark, mark.side])) : '';
      if (unchanged && old && previousRaw[index] === token.raw && old.streaming === streaming && old.marks === signature) return old;
      unchanged = false;
      let marked = token.raw;
      for (const mark of [...local].reverse()) marked = marked.slice(0, mark.offset - start) + mark.mark + marked.slice(mark.offset - start);
      const selected: TokensList = !streaming && !local.length ? Object.assign([token], { links: tokens.links }) : lex(streaming ? remend(marked) : marked);
      return { streaming, html: selectedParser.parser(selected), marks: signature, ...streaming && { tail: { start, token } } };
    });
    const result = blocks;
    if (final) { blocks = []; raw = []; links = ''; lexed = undefined; }
    else lexed = offset === source.length ? { source, tokens, starts } : undefined;
    return result;
  };
  return (source: string, final = false, marks: readonly Mark[] = [], changed = 0) => {
    const around = lexing.around;
    if (!around) return render(source, final, marks, changed);
    const unchanged = source === input;
    input = final ? undefined : source;
    return unchanged ? render(source, final, marks, changed) : around(source, () => render(source, final, marks, changed));
  };
}
