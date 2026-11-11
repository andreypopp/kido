import { Marked, type Token, type TokensList, type MarkedExtension } from 'marked';
import remend from 'remend';

export type Mark = { offset: number; mark: string; side: 'open' | 'close' };
export type Tail = { start: number; end: number; token: Token; html(end: number): string };
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

export function markdownLine(source: string): string {
  const lines = source.split(/\r\n?|\n/);
  const lexer = new parser.Lexer(parser.defaults), first = lexer.lex(source)[0];
  if (first?.type === 'code') return first.text.split('\n')[0].replace(/\s+/g, ' ').trim();
  const line = lines[0].replace(/^\s*(?:>\s*|(?:#{1,6}|[-+*]|\d+[.)])\s+|\[[ xX]\]\s+)*/g, '');
  const plain = (tokens: Token[]): string => tokens.map(token => 'tokens' in token && token.tokens ? plain(token.tokens) : 'text' in token ? token.text : token.raw).join('');
  return plain(lexer.inlineTokens(line)).replace(/\s+/g, ' ').trim();
}

const nested = (tokens: Token[]): boolean => tokens.some(token => token.type === 'code' || token.type === 'blockquote' || nested(('items' in token ? token.items : 'tokens' in token ? token.tokens : undefined) ?? []));

export function sliceEnd(token: Token, height: (end: number) => number): number {
  const { type, raw } = token;
  if (type === 'code' || type === 'table') {
    const whole = raw.slice(0, raw.lastIndexOf('\n') + 1);
    return whole.split('\n').length > (type === 'table' ? 3 : 2) ? whole.length : 0;
  }
  if (type === 'list' && 'items' in token) {
    const { items } = token;
    return nested(items) ? 0 : items.slice(0, -1).reduce((end: number, item: Token) => end + item.raw.length, 0);
  }
  if (type !== 'paragraph') return 0;
  const breaks = [...raw.matchAll(/\s+/g)].map(match => match.index), full = height(raw.length);
  let low = 0, high = breaks.length;
  while (low < high) {
    const middle = (low + high) >> 1;
    if (height(breaks[middle]) < full) low = middle + 1; else high = middle;
  }
  return low ? breaks[low - 1] : 0;
}

export function markdown(user = false) {
  const selectedParser = user ? userParser : parser;
  let blocks: RenderedBlock[] = [];
  let raw: string[] = [];
  let links = '';
  return (source: string, final = false, marks: readonly Mark[] = [], shown?: Pick<Tail, 'start' | 'end'>) => {
    if (marks.length && source.includes('\r')) {
      const offsets = [0];
      for (let index = 0; index < source.length; index++) offsets.push(offsets[index] + (source[index] === '\r' && source[index + 1] === '\n' ? 0 : 1));
      marks = marks.map(mark => ({ ...mark, offset: offsets[mark.offset] }));
    }
    source = source.replace(/\r\n?/g, '\n').replace(/[\uE010-\uE012]/g, '\uFFFD');
    const tokens = selectedParser.lexer(source);
    const lex = (text: string) => { const lexer = new selectedParser.Lexer(selectedParser.defaults); lexer.tokens.links = tokens.links; return lexer.lex(text); };
    const references = JSON.stringify(tokens.links);
    const previous = references === links ? blocks : [];
    const previousRaw = raw;
    raw = tokens.map(token => token.raw);
    links = references;
    let offset = 0, unchanged = true;
    blocks = tokens.map((token, index) => {
      const tail = index === tokens.length - 1;
      const streaming = tail && !final;
      const old = previous[index];
      const start = offset; offset += token.raw.length;
      const end = streaming && shown ? shown.start === start ? Math.min(shown.end, token.raw.length) : 0 : token.raw.length;
      const cut: Tail | undefined = streaming ? { start, end, token, html: at => selectedParser.parser(lex(remend(token.raw.slice(0, at)))) } : undefined;
      const local = marks.length ? marks.filter(mark => {
        const end = mark.side === 'close';
        return (mark.offset > start || mark.offset === start && (!end || index === 0)) && (mark.offset < offset || mark.offset === offset && (end || tail));
      }) : [];
      const signature = local.length ? JSON.stringify(local.map(mark => [mark.offset - start, mark.mark, mark.side])) : '';
      if (unchanged && old && previousRaw[index] === token.raw && old.streaming === streaming && old.tail?.end === cut?.end && old.marks === signature) return old;
      unchanged = false;
      let marked = token.raw.slice(0, end);
      for (const mark of [...local].reverse()) marked = marked.slice(0, mark.offset - start) + mark.mark + marked.slice(mark.offset - start);
      const selected: TokensList = !streaming && !local.length ? Object.assign([token], { links: tokens.links }) : lex(streaming ? remend(marked) : marked);
      return { streaming, html: selectedParser.parser(selected), marks: signature, ...cut && { tail: cut } };
    });
    const result = blocks;
    if (final) { blocks = []; raw = []; links = ''; }
    return result;
  };
}
