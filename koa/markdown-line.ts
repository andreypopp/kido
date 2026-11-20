import { Marked, type Token } from 'marked';

const parser = new Marked();

export function markdownLine(source: string): string {
  const lines = source.split(/\r\n?|\n/);
  const lexer = new parser.Lexer(parser.defaults), first = lexer.lex(source)[0];
  if (first?.type === 'code') return first.text.split('\n')[0].replace(/\s+/g, ' ').trim();
  const line = lines[0].replace(/^\s*(?:>\s*|(?:#{1,6}|[-+*]|\d+[.)])\s+|\[[ xX]\]\s+)*/g, '');
  const plain = (tokens: Token[]): string => tokens.map(token => 'tokens' in token && token.tokens ? plain(token.tokens) : 'text' in token ? token.text : token.raw).join('');
  return plain(lexer.inlineTokens(line)).replace(/\s+/g, ' ').trim();
}

