type Point = readonly [number, number];
const points = (list: Point[]) => list.map(([x, y]) => `${x.toFixed(1)} ${y.toFixed(1)}`).join(' ');
const normal = (p: Point, q: Point): Point => {
  const dx = q[0] - p[0], dy = q[1] - p[1], length = Math.hypot(dx, dy);
  return [-dy / length, dx / length];
};
const radians = (degrees: number) => (degrees * Math.PI) / 180;

export const taper = (p: Point, q: Point, from: number, to: number) => {
  const [nx, ny] = normal(p, q);
  return `<path d="M${points([
    [p[0] + (nx * from) / 2, p[1] + (ny * from) / 2],
    [q[0] + (nx * to) / 2, q[1] + (ny * to) / 2],
    [q[0] - (nx * to) / 2, q[1] - (ny * to) / 2],
    [p[0] - (nx * from) / 2, p[1] - (ny * from) / 2],
  ])}Z" fill="var(--ink)"/>`;
};

export const checks = (x: number, y: number, rotation: number, columns = 6, rows = 4, size = 13) => {
  let cells = '';
  for (let r = 0; r < rows; r++) for (let c = 0; c < columns; c++) {
    if ((r + c) % 2 === 0) cells += `<rect x="${c * size}" y="${r * size}" width="${size}" height="${size}"/>`;
  }
  return `<g transform="translate(${x} ${y}) rotate(${rotation})" fill="var(--ink)"><rect width="${columns * size}" height="${rows * size}" fill="var(--paper)"/>${cells}</g>`;
};

export const target = (x: number, y: number, scale = 1) =>
  `<g transform="translate(${x} ${y}) scale(${scale})"><circle r="38" fill="none" stroke="var(--ink)" stroke-width="12" stroke-dasharray="1.5 4.5" opacity=".7"/><circle r="22" fill="var(--paper)" stroke="var(--ink)" stroke-width="9"/><circle r="7" fill="var(--ink)"/></g>`;

export const planet = (x: number, y: number, r: number) =>
  `<g transform="translate(${x} ${y}) scale(${r / 50})"><circle r="50" fill="var(--blue)"/><path d="M-40-38 46 46" stroke="var(--sky)" stroke-width="4"/><circle cx="-14" cy="18" r="5" fill="var(--yellow)"/><circle cx="24" cy="14" r="5" fill="var(--red)"/><circle cx="6" cy="36" r="6" fill="var(--green)"/><circle cx="12" cy="-24" r="4" fill="var(--paper)"/><circle cx="-24" cy="-12" r="3" fill="var(--paper)"/></g>`;
