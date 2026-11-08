type RenderedBlock = { source: string; streaming: boolean; html?: string };
export function markdown(): (source: string, final?: boolean) => RenderedBlock[];
