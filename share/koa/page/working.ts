const CYCLE = 1100, STAGGER = 180;
const BOUNCE = [
  { transform: 'none', opacity: .55, offset: 0 },
  { transform: 'translateY(-2px)', opacity: 1, offset: .3 },
  { transform: 'none', opacity: .55, offset: .6 },
  { transform: 'none', opacity: .55, offset: 1 },
];

export function dots(since: number) {
  const view = document.createElement('span');
  view.className = 'dots';
  view.setAttribute('role', 'img');
  view.setAttribute('aria-label', 'working');
  const still = matchMedia('(prefers-reduced-motion: reduce)').matches;
  for (let index = 0; index < 3; index++) {
    const dot = document.createElement('i');
    view.append(dot);
    if (still) continue;
    const bounce = dot.animate(BOUNCE, { duration: CYCLE, iterations: Infinity });
    bounce.startTime = Number(document.timeline.currentTime) - (Date.now() - since) + index * STAGGER;
  }
  return view;
}
