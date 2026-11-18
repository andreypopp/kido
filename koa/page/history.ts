export function promptHistory(load: () => Promise<string[]>) {
  let browsing: { entries: string[]; index: number; draft: { text: string; anchor: number; head: number } } | undefined;
  let generation = 0;
  let loading = false;
  return {
    reset() { browsing = undefined; generation++; },
    get active() { return browsing !== undefined; },
    async move(direction: -1 | 1, draft: { text: string; anchor: number; head: number }): Promise<{ text: string; anchor: number; head: number } | undefined> {
      if (loading || !browsing && direction === 1) return;
      if (!browsing) {
        const current = generation;
        loading = true;
        let entries: string[];
        try { entries = await load(); } finally { loading = false; }
        if (current !== generation || !entries.length) return;
        browsing = { entries, index: -1, draft };
      }
      const index = browsing.index - direction;
      if (index < -1 || index >= browsing.entries.length) return;
      browsing.index = index;
      if (index === -1) { const draft = browsing.draft; browsing = undefined; return draft; }
      const text = browsing.entries[index] ?? '';
      const cursor = direction === -1 ? 0 : text.length;
      return { text, anchor: cursor, head: cursor };
    },
  };
}
