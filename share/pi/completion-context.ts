export type CompletionContext = { type: 'host'; cwd: string } | { type: 'runtime'; name: string; cwd: string } | { type: 'unavailable' };

declare global {
  var __koCompletionContext: { stop: AbortController; resolve?: (signal: AbortSignal) => Promise<CompletionContext> } | undefined;
}

export function setCompletionContext(resolve?: (signal: AbortSignal) => Promise<CompletionContext>) {
  globalThis.__koCompletionContext?.stop.abort();
  globalThis.__koCompletionContext = { stop: new AbortController(), resolve };
}

export async function resolveCompletionContext(signal: AbortSignal): Promise<CompletionContext> {
  const owner = globalThis.__koCompletionContext;
  if (!owner?.resolve) return { type: 'unavailable' };
  const current = AbortSignal.any([signal, owner.stop.signal]);
  try {
    const context = await owner.resolve(current);
    return current.aborted ? { type: 'unavailable' } : context;
  } catch { return { type: 'unavailable' }; }
}
