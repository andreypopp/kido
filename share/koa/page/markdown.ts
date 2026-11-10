import { Marked, type Token, type TokensList, type MarkedExtension } from 'marked';
import remend from 'remend';

export type Mark = { offset: number; mark: string; side: 'open' | 'close' };
type RenderedBlock = { streaming: boolean; html?: string; marks: string };

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

export function markdown(user = false) {
  const selectedParser = user ? userParser : parser;
  let blocks: RenderedBlock[] = [];
  let raw: string[] = [];
  let links = '';
  return (source: string, final = false, marks: readonly Mark[] = []) => {
    if (marks.length && source.includes('\r')) {
      const offsets = [0];
      for (let index = 0; index < source.length; index++) offsets.push(offsets[index] + (source[index] === '\r' && source[index + 1] === '\n' ? 0 : 1));
      marks = marks.map(mark => ({ ...mark, offset: offsets[mark.offset] }));
    }
    source = source.replace(/\r\n?/g, '\n').replace(/[\uE010-\uE012]/g, '\uFFFD');
    const tokens = selectedParser.lexer(source);
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
      const local = marks.length ? marks.filter(mark => {
        const end = mark.side === 'close';
        return (mark.offset > start || mark.offset === start && (!end || index === 0)) && (mark.offset < offset || mark.offset === offset && (end || tail));
      }) : [];
      const signature = local.length ? JSON.stringify(local.map(mark => [mark.offset - start, mark.mark, mark.side])) : '';
      if (unchanged && old && previousRaw[index] === token.raw && old.streaming === streaming && old.marks === signature) return old;
      unchanged = false;
      let marked = token.raw;
      for (const mark of [...local].reverse()) marked = marked.slice(0, mark.offset - start) + mark.mark + marked.slice(mark.offset - start);
      let selected: TokensList;
      if (!streaming && !local.length) selected = Object.assign([token], { links: tokens.links });
      else {
        const lexer = new selectedParser.Lexer(selectedParser.defaults);
        lexer.tokens.links = tokens.links;
        selected = lexer.lex(streaming ? remend(marked) : marked);
      }
      return { streaming, html: selectedParser.parser(selected), marks: signature };
    });
    const result = blocks;
    if (final) { blocks = []; raw = []; links = ''; }
    return result;
  };
}
