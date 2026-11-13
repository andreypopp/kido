declare global {
  interface Window { ko?: { local: boolean; preview?: (url: string, rect: DOMRect) => void; focus?: (pane: string) => void }; }
}

let lightbox: { view: HTMLDivElement; target: HTMLElement; onChange: () => void } | undefined;
export function closeLightbox(): boolean {
  if (!lightbox) return false;
  const { view, target, onChange } = lightbox; lightbox = undefined; view.remove(); if (target.isConnected) target.focus(); else window.composer.focus(); onChange(); return true;
}
export function previewKey(event: KeyboardEvent): boolean {
  if (!lightbox) return false;
  if (!event.metaKey && !event.ctrlKey) {
    event.preventDefault(); event.stopPropagation();
    if (event.key === 'Escape') closeLightbox();
  }
  return true;
}
export function preview(url: string, target: HTMLElement, kind: 'image' | 'file', onChange: () => void, name = 'Image') {
  if (window.ko?.preview) { window.ko.preview(url, target.getBoundingClientRect()); return; }
  if (kind === 'file') { window.open(url, '_blank', 'noopener'); return; }
  closeLightbox();
  const view = document.createElement('div'); view.className = 'lightbox'; view.tabIndex = -1; lightbox = { view, target, onChange };
  view.setAttribute('role', 'dialog'); view.setAttribute('aria-label', 'Image preview'); view.setAttribute('aria-modal', 'true');
  const image = document.createElement('img'), caption = document.createElement('div'); image.alt = name; caption.className = 'cap';
  const label = name.split(/[\\/]/).at(-1) || 'Image';
  const describe = () => { caption.textContent = label + ' · ' + (image.naturalWidth && image.naturalHeight ? image.naturalWidth + '×' + image.naturalHeight + ' · ' : '') + 'click or ⎋ to close'; };
  image.onload = describe; describe(); image.src = url; view.append(image, caption);
  view.onclick = () => { closeLightbox(); };
  document.body.append(view); view.focus(); onChange();
}
