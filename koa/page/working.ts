export function dots() {
  const view = document.createElement('span');
  view.className = 'dots';
  view.setAttribute('role', 'img');
  view.setAttribute('aria-label', 'working');
  for (let index = 0; index < 3; index++) view.append(document.createElement('i'));
  return view;
}
