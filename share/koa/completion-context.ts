export type CompletionContext = { type: 'host'; cwd: string } | { type: 'runtime'; name: string; cwd: string } | { type: 'unavailable' };
