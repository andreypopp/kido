import { Marked } from './vendor/marked.js';
import remend from './vendor/remend.js';

const escape = text => text.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;').replaceAll('"', '&quot;');
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
  let blocks = [];
  let raw = [];
  let links = '';
  return (source, final = false) => {
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
      const selected = streaming ? parser.lexer(remend(token.raw)) : [token];
      selected.links = tokens.links;
      return { streaming, html: parser.parser(selected) };
    });
    return blocks;
  };
}
