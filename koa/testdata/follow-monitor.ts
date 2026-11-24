export type FollowSample = {
  scope: string;
  viewport: number;
  width: number;
  dock: number;
  following: boolean;
  covered: boolean;
  max: number;
  exemption?: 'completion' | 'source' | 'fold';
  rows: { key: string; top: number; bottom: number }[];
  bottomSpace: number;
};

export function followMonitor() {
  let previous: FollowSample | undefined;
  return (sample: FollowSample) => {
    const before = previous;
    previous = sample.following && !sample.covered && !sample.exemption && sample.max > 1 ? sample : undefined;
    if (!previous || !before || before.scope !== sample.scope || before.viewport !== sample.viewport || before.width !== sample.width || before.dock !== sample.dock) return;
    const known = new Map(before.rows.filter(row => row.bottom > 0 && row.top < before.dock).map(row => [row.key, row]));
    for (const row of sample.rows) {
      const old = known.get(row.key);
      if (old && row.bottom > 0 && row.top < sample.dock && row.top > old.top + .75) throw Error(`following row ${row.key} moved down: ${old.top} -> ${row.top}`);
    }
    if (Math.abs(sample.bottomSpace - before.bottomSpace) > .75) throw Error(`following bottom space changed: ${before.bottomSpace} -> ${sample.bottomSpace}`);
  };
}
