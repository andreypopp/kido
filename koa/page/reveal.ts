import type { Token } from 'marked';
import type { Frontier } from './markdown.ts';

export type Unit = { bottom: number; complete: boolean };
type Line = { top: number; bottom: number };

const nested = (tokens: Token[]): boolean => tokens.some(token => token.type === 'code' || token.type === 'blockquote' || nested(('items' in token ? token.items : 'tokens' in token ? token.tokens : undefined) ?? []));

export function revealHeight(units: Unit[], shown: number, cap: number, expired: boolean): number | undefined {
  const base = (shown > .5 ? units.find(unit => unit.complete && unit.bottom >= shown - .5)?.bottom : undefined) ?? units.findLast(unit => unit.complete && unit.bottom <= shown + .5)?.bottom ?? 0;
  const next = (units.at(-1)?.bottom ?? 0) - base < cap && !expired ? undefined : units.findLast(unit => unit.complete && unit.bottom > base)?.bottom;
  const height = next ?? base;
  return Math.abs(height - shown) > .5 ? height : undefined;
}

function lines(rects: Line[]): Line[] {
  const result: Line[] = [];
  for (const rect of rects.toSorted((a, b) => a.top + a.bottom - b.top - b.bottom)) {
    const line = result.at(-1);
    if (line && (rect.top + rect.bottom) / 2 < line.bottom) { line.top = Math.min(line.top, rect.top); line.bottom = Math.max(line.bottom, rect.bottom); } else result.push({ ...rect });
  }
  return result;
}

function boxes(rects: Line[], complete: (index: number) => boolean): Unit[] {
  const found = lines(rects);
  let edge = 0;
  return found.map((line, index) => {
    const next = found[index + 1], bottom = next ? (line.bottom + next.top) / 2 : line.bottom + line.top - edge;
    edge = bottom;
    return { bottom, complete: complete(index) };
  });
}

export function unitsOf(wrapper: HTMLElement, token: Token, frontier: Frontier): Unit[] {
  if (frontier.kind === 'closed') return [];
  const root = wrapper.firstElementChild;
  if (!root) return [];
  const origin = root.getBoundingClientRect().top;
  const relative = (rect: DOMRect): Line => ({ top: rect.top - origin, bottom: rect.bottom - origin });
  const text = (element: Element) => { const range = document.createRange(); range.selectNodeContents(element); return [...range.getClientRects()].map(relative); };
  switch (token.type) {
    case 'paragraph': {
      const result = boxes(text(root), () => true);
      const last = result.at(-1);
      if (last) last.complete = false;
      return result;
    }
    case 'code': {
      const code = root.querySelector('code');
      if (!code) return [];
      const done = frontier.kind === 'lines' ? frontier.count : 0, result = boxes(text(code), index => index < done), last = result.at(-1);
      if (last?.complete) last.bottom = Math.max(last.bottom, relative(root.getBoundingClientRect()).bottom);
      return result;
    }
    case 'list': {
      if ('items' in token && nested(token.items)) return [];
      const result = [...root.children].map((item): Unit => ({ bottom: relative(item.getBoundingClientRect()).bottom, complete: true }));
      const last = result.at(-1);
      if (last) last.complete = false;
      return result;
    }
    default: return [];
  }
}
