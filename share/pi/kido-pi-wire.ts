export function frames(json: string, direction: "in" | "out", start = 1, client = "", msg = 1): string[] {
  const bytes = Buffer.from(json);
  const size = direction === "out" ? 3000 : 300;
  const result: string[] = [];
  for (let i = 0; i < bytes.length; i += size) {
    const index = i / size;
    const last = Number(i + size >= bytes.length);
    const header = direction === "out" ? `${start + index},${last}` : `${client},${msg},${index},${last}`;
    result.push(`\x1b]6767;${header};${bytes.subarray(i, i + size).toString("base64")}\x07`);
  }
  return result;
}

export function decoder(direction: "in" | "out", message: (value: Record<string, any>) => void, ack = (_value: Record<string, any>) => {}, plain = (_bytes: Buffer) => {}) {
  let pending = Buffer.alloc(0);
  const clients = new Map<string, { msg: number; index: number; chunks: Buffer[] }>();
  let outgoing: Buffer[] = [];
  const prefix = Buffer.from("\x1b]6767");
  return (bytes: Buffer) => {
    pending = Buffer.concat([pending, bytes]);
    if (!bytes.length && pending.length === 1 && pending[0] === 27) { plain(pending); pending = Buffer.alloc(0); }
    while (pending.length) {
      if (pending[0] !== 27) {
        const end = pending.indexOf(27);
        plain(pending.subarray(0, end < 0 ? pending.length : end));
        pending = end < 0 ? Buffer.alloc(0) : pending.subarray(end);
        continue;
      }
      if (pending.length < prefix.length && prefix.subarray(0, pending.length).equals(pending)) return;
      if (!pending.subarray(0, prefix.length).equals(prefix)) {
        plain(pending.subarray(0, 1)); pending = pending.subarray(1); continue;
      }
      const end = pending.indexOf(7);
      if (end < 0) return;
      const frame = pending.subarray(prefix.length, end).toString();
      pending = pending.subarray(end + 1);
      const match = /^;(.*);([A-Za-z0-9+/]*={0,2})$/.exec(frame);
      if (!match) continue;
      const header = match[1].split(",");
      const chunk = Buffer.from(match[2], "base64");
      if (chunk.toString("base64") !== match[2]) continue;
      if (direction === "out") {
        if (header.length !== 2 || !/^\d+$/.test(header[0]) || !/^[01]$/.test(header[1]) || chunk.length > 3000) continue;
        outgoing.push(chunk);
        if (header[1] === "1") { deliver(outgoing); outgoing = []; }
      } else {
        if (header.length !== 4 || !header[0] || !header.slice(1, 3).every(x => /^\d+$/.test(x)) || !/^[01]$/.test(header[3]) || chunk.length > 300) continue;
        const [client, m, i, last] = header;
        const msg = Number(m), index = Number(i);
        ack({ type: "ack", client, msg, index });
        const prior = clients.get(client);
        if (prior && (msg < prior.msg || (msg === prior.msg && index <= prior.index))) continue;
        if (index !== (prior && msg === prior.msg ? prior.index + 1 : 0)) continue;
        const state = { msg, index, chunks: prior && msg === prior.msg ? prior.chunks : [] };
        state.chunks.push(chunk); clients.set(client, state);
        if (last === "1") { deliver(state.chunks); state.chunks = []; }
      }
    }
  };
  function deliver(chunks: Buffer[]) {
    try { const value = JSON.parse(Buffer.concat(chunks).toString("utf8")); if (value && typeof value === "object" && !Array.isArray(value)) message(value); } catch {}
  }
}
