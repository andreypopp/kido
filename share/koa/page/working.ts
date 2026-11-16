const CYCLE = 1100, STAGGER = 180;
const BOUNCE = [
  { transform: 'translateY(0)', opacity: .55, offset: 0, easing: 'ease-out' },
  { transform: 'translateY(-2px)', opacity: 1, offset: .3, easing: 'ease-in' },
  { transform: 'translateY(0)', opacity: .55, offset: .6 },
  { transform: 'translateY(0)', opacity: .55, offset: 1 },
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
    const bounce = dot.animate(BOUNCE, { duration: CYCLE, iterations: Infinity, delay: index * STAGGER });
    bounce.startTime = Number(document.timeline.currentTime) - (Date.now() - since);
  }
  return view;
}
