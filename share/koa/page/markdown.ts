import { Marked, type TokensList } from 'marked';
import remend from 'remend';

type RenderedBlock = { streaming: boolean; html?: string }; 

const escape = (text: string) => text.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;').replaceAll('"', '&quot;');
const parser = new Marked({ renderer: {
  html: ({ text }) => escape(text),
  image: ({ text }) => escape(text),
  link({ href, tokens }) {
    const text = this.parser.parseInline(tokens);
    try {
      const url = new URL(href);
      return ['http:', 'https:', 'mailto:'].includes(url.protocol) ? `<a href="${escape(href)}">${text}</a>` : text;
    } catch { return text; }
  },
} });

export function markdown() {
  let blocks: RenderedBlock[] = [];
  let raw: string[] = [];
  let links = '';
  return (source: string, final = false) => {
    const tokens = parser.lexer(source);
    const references = JSON.stringify(tokens.links);
    const previous = references === links ? blocks : [];
    const previousRaw = raw;
    raw = tokens.map(token => token.raw);
    links = references;
    let unchanged = true;
    blocks = tokens.map((token, index) => {
      const tail = index === tokens.length - 1;
      const streaming = tail && !final;
      const old = previous[index];
      if (unchanged && old && previousRaw[index] === token.raw && old.streaming === streaming) return old;
      unchanged = false;
      const selected: TokensList = streaming ? parser.lexer(remend(token.raw)) : Object.assign([token], { links: tokens.links });
      selected.links = tokens.links;
      return { streaming, html: parser.parser(selected) };
    });
    const result = blocks;
    if (final) { blocks = []; raw = []; links = ''; }
    return result;
  };
}
