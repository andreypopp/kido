import { ATTACHMENT_LIMITS, isAttachment } from '../koa-records.ts';
import { fetchJSON } from './http.ts';
import { preview } from './preview.ts';
import type { Attachment } from '../koa-records.ts';

type Chip = { view: HTMLDivElement; icon: HTMLSpanElement; name: HTMLSpanElement; detail: HTMLSpanElement; body: HTMLButtonElement; controller: AbortController; state: { type: 'pending'; name: string; size: number; received: number; id?: string } | { type: 'ready'; file: Attachment } | { type: 'refused'; name: string; reason: string } };
const sizeLabel = (size: number) => size >= 1048576 ? (size / 1048576).toFixed(size >= 10 * 1048576 ? 0 : 1) + ' MB' : size >= 1024 ? Math.ceil(size / 1024) + ' KB' : size + ' B';

export function attach(host: HTMLElement, changed: () => void, displayPath: (value: string) => string) {
  const chips: Chip[] = [];
  const notice = document.createElement('div'); notice.className = 'attach-notice'; notice.hidden = true; host.append(notice);
  let timer: ReturnType<typeof setTimeout> | undefined, hover = false, depth = 0;
  const refresh = () => { host.hidden = chips.length === 0 && notice.hidden; changed(); };
  const hovering = (value: boolean) => { if (hover !== value) { hover = value; changed(); } };
  const beginDrop = () => { clearTimeout(timer); notice.hidden = true; depth = 0; hovering(false); refresh(); };
  const refuseFolders = () => { notice.textContent = 'Folders are not attached'; notice.hidden = false; clearTimeout(timer); timer = setTimeout(() => { notice.hidden = true; refresh(); }, 4000); refresh(); };
  const deleteFile = (id: string) => { void fetchJSON('/attachments/' + id + '/delete').catch(() => {}); };
  const remove = (chip: Chip, erase = true) => {
    const index = chips.indexOf(chip); if (index < 0) return;
    chips.splice(index, 1); chip.view.remove(); chip.controller.abort();
    const id = chip.state.type === 'ready' ? chip.state.file.id : chip.state.type === 'pending' ? chip.state.id : undefined;
    if (erase && id) deleteFile(id);
    refresh();
  };
  const render = (chip: Chip) => {
    const state = chip.state, file = state.type === 'ready' ? state.file : undefined;
    chip.name.textContent = file?.name ?? (state.type === 'ready' ? '' : state.name);
    chip.body.setAttribute('aria-label', chip.name.textContent);
    chip.body.disabled = state.type !== 'ready';
    chip.view.classList.toggle('refused', state.type === 'refused');
    chip.icon.className = state.type === 'pending' ? 'attach-icon spin' : 'attach-icon';
    chip.body.onclick = () => { if (chip.state.type === 'ready') preview('/attachments/' + chip.state.file.id, chip.body, chip.state.file.kind, chip.state.file.name); };
    if (file?.kind === 'image') { const image = document.createElement('img'); image.src = '/attachments/' + file.id; image.alt = ''; chip.icon.replaceChildren(image); }
    else chip.icon.innerHTML = state.type === 'pending' ? '' : '<svg viewBox="0 0 16 16"><path d="M4 1.5h5.5L13 5v9.5H4z"/><path d="M9.5 1.5V5H13"/></svg>';
    chip.detail.classList.toggle('path', file?.origin === 'path');
    chip.detail.textContent = state.type === 'refused' ? state.reason : state.type === 'pending' ? (state.size >= 1048576 ? Math.floor(state.received / 1048576) + ' / ' + Math.ceil(state.size / 1048576) + ' MB' : sizeLabel(state.received) + ' / ' + sizeLabel(state.size)) : state.file.origin === 'path' ? displayPath(state.file.path.slice(0, state.file.path.lastIndexOf('/') + 1)) : sizeLabel(state.file.size);
    refresh();
  };
  const create = (state: Chip['state']) => {
    const view = document.createElement('div'); view.className = 'attach-chip';
    const body = document.createElement('button'); body.type = 'button'; body.className = 'attach-body';
    const icon = document.createElement('span'), name = document.createElement('span'), detail = document.createElement('span');
    name.className = 'attach-name'; detail.className = 'attach-detail'; body.append(icon, name, detail);
    const close = document.createElement('button'); close.type = 'button'; close.className = 'attach-remove'; close.innerHTML = '<svg viewBox="0 0 10 10"><path d="m2 2 6 6m0-6-6 6"/></svg>'; close.setAttribute('aria-label', 'Remove attachment');
    view.append(body, close);
    const chip: Chip = { view, icon, name, detail, body, controller: new AbortController(), state };
    close.onclick = () => remove(chip);
    chips.push(chip); host.insertBefore(view, notice); render(chip);
    return chip;
  };
  const add = async (source: File) => {
    const name = source.name;
    if (chips.filter(chip => chip.state.type !== 'refused').length >= ATTACHMENT_LIMITS.files) { create({ type: 'refused', name, reason: 'too many' }); return; }
    if (source.size > ATTACHMENT_LIMITS.fileBytes) { create({ type: 'refused', name, reason: 'over ' + ATTACHMENT_LIMITS.fileBytes / 1048576 + ' MB' }); return; }
    const chip = create({ type: 'pending', name, size: source.size, received: 0 });
    try {
      const created = await fetchJSON('/attachments', { name, type: source.type, size: source.size });
      if (!chips.includes(chip)) { deleteFile(created.id); return; }
      chip.state = { type: 'pending', name, size: source.size, received: 0, id: created.id };
      let offset = 0;
      do {
        const bytes = new Uint8Array(await source.slice(offset, offset + ATTACHMENT_LIMITS.chunkBytes).arrayBuffer());
        const result = await fetchJSON(`/attachments/${created.id}/${offset}`, bytes, 'POST', chip.controller.signal);
        if (!chips.includes(chip)) return;
        if (result.received !== offset + bytes.length) throw Error('Upload offset does not match');
        offset = result.received;
        if (result.attachment) chip.state = { type: 'ready', file: result.attachment }; else chip.state = { type: 'pending', name, size: source.size, received: offset, id: created.id };
        render(chip);
      } while (offset < source.size);
      if (chip.state.type !== 'ready') throw Error('Upload did not finish');
    } catch (error) {
      if (!chips.includes(chip)) return;
      const id = chip.state.type === 'pending' ? chip.state.id : undefined;
      if (id) deleteFile(id);
      chip.state = { type: 'refused', name, reason: error instanceof Error ? error.name === 'TimeoutError' ? 'upload timed out' : error.message : 'not readable' }; render(chip);
    }
  };
  const drop = (event: DragEvent) => {
    if (event.defaultPrevented || !event.dataTransfer) return false;
    const transfer = event.dataTransfer;
    if (!transfer.files.length && !Array.from(transfer.items).some(item => item.webkitGetAsEntry?.()?.isDirectory)) return false;
    event.preventDefault();
    if (window.ko?.local) { depth = 0; hovering(false); return true; }
    beginDrop();
    const files: File[] = []; let refused = false;
    const items = Array.from(transfer.items).filter(item => item.kind === 'file');
    if (items.length) for (const item of items) { if (item.webkitGetAsEntry?.()?.isDirectory) refused = true; else { const file = item.getAsFile(); if (file) files.push(file); } }
    else files.push(...Array.from(transfer.files));
    if (refused) refuseFolders();
    for (const file of files.slice(0, ATTACHMENT_LIMITS.files + 1)) void add(file);
    return true;
  };
  const paste = (event: ClipboardEvent) => {
    if (event.defaultPrevented || !event.clipboardData?.files.length) return false;
    event.preventDefault();
    for (const file of Array.from(event.clipboardData.files).slice(0, ATTACHMENT_LIMITS.files + 1)) void add(file);
    return true;
  };
  document.addEventListener('drop', drop);
  document.addEventListener('paste', paste);
  document.addEventListener('dragenter', event => { if (event.dataTransfer?.types.includes('Files')) { depth++; hovering(true); } });
  document.addEventListener('dragover', event => { if (event.dataTransfer?.types.includes('Files')) { event.preventDefault(); hovering(true); } });
  document.addEventListener('dragleave', () => { depth = Math.max(0, depth - 1); if (!depth) hovering(false); });
  window.addEventListener('ko-drop', event => {
    if (!window.ko?.local || !(event instanceof CustomEvent)) return;
    const value: unknown = event.detail;
    if (!value || typeof value !== 'object' || !('files' in value) || !Array.isArray(value.files) || value.files.length > ATTACHMENT_LIMITS.files || !value.files.every(file => isAttachment(file) && file.origin === 'path') || !('refused' in value) || typeof value.refused !== 'boolean') return;
    beginDrop(); if (value.refused) refuseFolders();
    for (const file of value.files) create({ type: 'ready', file });
  });
  return {
    drop, paste,
    get hover() { return hover; },
    get busy() { return chips.some(chip => chip.state.type === 'pending'); },
    get count() { return chips.filter(chip => chip.state.type === 'ready').length; },
    get files() { return chips.flatMap(chip => chip.state.type === 'ready' ? [chip.state.file] : []); },
    sent(files: readonly Attachment[]) { const ids = new Set(files.map(file => file.id)); for (const chip of [...chips]) if (chip.state.type === 'ready' && ids.has(chip.state.file.id)) remove(chip, false); },
    restore(files: readonly Attachment[]) { for (const file of files) if (!chips.some(chip => chip.state.type === 'ready' && chip.state.file.id === file.id)) create({ type: 'ready', file }); },
  };
}
