import type { State, WireItem, Topic } from '../koa-records.ts';
import { parseTopicName, type TopicName } from '../records.ts';
import { topicTurn } from '../topic-turn.ts';
import { markdownLine } from '../markdown-line.ts';

type ComposerTopic = { type: 'topic'; name: TopicName } | { type: 'dropped' };
export type TopicsMemory = { filters: [scope: string, topic: TopicName][]; composerTopics: [scope: string, topic: ComposerTopic][] };
type Correction = { sessionId: string | undefined } & ({ kind: 'message'; seq: number; topic: TopicName } | { kind: 'move'; from: TopicName; to: TopicName } | { kind: 'archive'; name: TopicName; archived: boolean });
type TopicNamingTarget = { kind: 'composer' } | { kind: 'message'; seq: number; key: string };
type Interaction = { kind: 'naming'; scope: string; sessionId: string | undefined; target: TopicNamingTarget; chip: HTMLElement; input: HTMLInputElement } | { kind: 'rename'; cancel(): void } | { kind: 'drag'; cancel(): void };
const isRecord = (value: unknown): value is Record<string, unknown> => typeof value === 'object' && value !== null && !Array.isArray(value);
export function topicsMemory(stored: unknown): stored is TopicsMemory {
  return isRecord(stored) && ['filters', 'composerTopics'].every(key => { const entries = stored[key]; return Array.isArray(entries) && entries.every(entry => Array.isArray(entry) && entry.length === 2 && typeof entry[0] === 'string' && (key === 'composerTopics' ? isRecord(entry[1]) && (entry[1].type === 'dropped' || entry[1].type === 'topic' && parseTopicName(entry[1].name) !== undefined) : parseTopicName(entry[1]) !== undefined)); });
}
export function createTopics(deps: {
  state(): State; items: ReadonlyMap<number, WireItem>; unread(): ReadonlyMap<TopicName, number>;
  element(id: string): HTMLElement;
  node<K extends keyof HTMLElementTagNameMap>(tag: K, text?: string, className?: string): HTMLElementTagNameMap[K];
  timestamp(at: number): string; refreshComposer(): void; focus(): void; layout(element: HTMLElement): void;
  filterChanged(name: TopicName | undefined): void; correct(correction: Correction): Promise<void>;
}, memory?: TopicsMemory) {
  const { element, node, timestamp, refreshComposer, items } = deps;
  const scopes = new Map<string, { filter?: TopicName; composer?: ComposerTopic; move?: { from: TopicName; to: TopicName } }>();
  const scopeData = (scope: string) => { let value = scopes.get(scope); if (!value) { value = {}; scopes.set(scope, value); } return value; };
  for (const [scope, filter] of memory?.filters ?? []) scopeData(scope).filter = filter;
  for (const [scope, composer] of memory?.composerTopics ?? []) scopeData(scope).composer = composer;
  const interactions: Interaction[] = [];
  const interaction = {
    get naming() { return interactions.find((entry): entry is Extract<Interaction, { kind: 'naming' }> => entry.kind === 'naming'); },
    set naming(value: Extract<Interaction, { kind: 'naming' }> | undefined) { const index = interactions.findIndex(entry => entry.kind === 'naming'); if (index >= 0) interactions.splice(index, 1); if (value) interactions.push(value); },
    get rename() { return interactions.find((entry): entry is Extract<Interaction, { kind: 'rename' }> => entry.kind === 'rename'); },
    set rename(value: Extract<Interaction, { kind: 'rename' }> | undefined) { const index = interactions.findIndex(entry => entry.kind === 'rename'); if (index >= 0) interactions.splice(index, 1); if (value) interactions.push(value); },
    get drag() { return interactions.find((entry): entry is Extract<Interaction, { kind: 'drag' }> => entry.kind === 'drag'); },
    set drag(value: Extract<Interaction, { kind: 'drag' }> | undefined) { const index = interactions.findIndex(entry => entry.kind === 'drag'); if (index >= 0) interactions.splice(index, 1); if (value) interactions.push(value); },
  };
  const current = { get state() { return deps.state(); } };
  const filterKey = (record = current.state) => record.view.id + ':' + (record.sessionId ?? '');
  const topicFilter = () => current.state.view.type === 'root' ? scopes.get(filterKey())?.filter : undefined;
  const composerTopic = node('div', undefined, 'message-header composer-topic');
  const topicMeasure = node('span', '0', 'topic-measure');
  topicMeasure.setAttribute('aria-hidden', 'true'); document.body.append(topicMeasure);
  let topicCapsule: { view: HTMLDivElement; names: TopicName[]; selected?: TopicName; width?: number } | undefined;
  function setTopic(name: TopicName | undefined) {
    const previous = topicFilter(), next = previous === name ? undefined : name;
    if (!next && previous && composerTopicName() === previous) scopeData(filterKey()).composer = { type: 'dropped' };
    if (next) { scopeData(filterKey()).composer = { type: 'topic', name: next }; if (interaction.naming?.target.kind === 'composer') interaction.naming = undefined; }
    updateTopicFilter(next);
  }
  function updateTopicFilter(name: TopicName | undefined, scope = filterKey()) {
    if (name) scopeData(scope).filter = name; else delete scopeData(scope).filter;
    if (scope !== filterKey()) return;
    clearTimeout(topicClick); topicClick = undefined;
    deps.filterChanged(name);
  }
  function topicColour(name?: TopicName): string {
    const topics = 'topics' in current.state ? current.state.topics : [], index = topics.findIndex(topic => topic.name === name);
    return `var(--topic-${(index < 0 ? topics.length : index) % 6})`;
  }
  function topicName(name: TopicName) {
    const label = node('span', undefined, 'topic-name'); label.dataset.topic = name; label.title = name;
    label.style.setProperty('--topic-color', topicColour(name));
    label.append(node('span', '#', 'topic-hash'), node('span', name));
    return label;
  }
  function composerTopicName(): TopicName | undefined {
    if (current.state.view.type !== 'root') return undefined;
    const choice = scopes.get(filterKey())?.composer;
    return choice ? choice.type === 'topic' ? choice.name : undefined : topicFilter();
  }
  const clearableComposerTopic = () => interaction.naming?.target.kind === 'composer' ? undefined : composerTopicName();
  function dropComposer(): boolean {
    if (!clearableComposerTopic()) return false;
    setComposerTopic(undefined);
    return true;
  }
  function setComposerTopic(name: TopicName | undefined) {
    if (interaction.naming?.target.kind === 'composer') interaction.naming = undefined;
    scopeData(filterKey()).composer = name ? { type: 'topic', name } : { type: 'dropped' };
    refreshComposer();
  }
  function newTopicChip(target: TopicNamingTarget) {
    const chip = node('span', undefined, 'topic-chip topic-new'); chip.append(node('span', '+', 'topic-hash'), node('span', 'topic'));
    chip.setAttribute('role', 'button'); chip.tabIndex = -1; chip.setAttribute('aria-label', 'Name a topic');
    chip.onclick = () => startTopicNaming(chip, target);
    chip.onkeydown = event => { if (event.key === 'Enter' || event.key === ' ') { event.preventDefault(); event.stopPropagation(); startTopicNaming(chip, target); } };
    return chip;
  }
  function finishTopicNaming(commit: boolean) {
    const naming = interaction.naming;
    if (!naming) return;
    const name = commit ? parseTopicName(naming.input.value) : undefined;
    if (commit && !name) { naming.input.focus(); return; }
    interaction.naming = undefined;
    const replacement = newTopicChip(naming.target);
    naming.chip.replaceWith(replacement); deps.layout(replacement);
    if (naming.scope !== filterKey()) return;
    if (naming.target.kind === 'composer') { if (commit) setComposerTopic(name); deps.focus(); }
    else if (name) void deps.correct({ kind: 'message', sessionId: naming.sessionId, seq: naming.target.seq, topic: name }).catch(() => {});
  }
  function startTopicNaming(plus: HTMLElement, target: TopicNamingTarget) {
    finishTopicNaming(false);
    const chip = node('span', undefined, 'topic-chip topic-naming'), input = node('input', undefined, 'topic-input');
    input.placeholder = 'topic name'; input.spellcheck = false; input.setAttribute('aria-label', 'Topic name');
    const colour = () => {
      chip.style.setProperty('--topic-color', topicColour(parseTopicName(input.value)));
      input.style.width = Math.max(6, input.value.length || input.placeholder.length) + 'ch';
      deps.layout(chip);
    };
    input.oninput = colour; colour();
    input.onkeydown = event => {
      event.stopPropagation();
      if (event.isComposing) return;
      if (event.key === 'Enter' || event.key === 'Tab' && target.kind === 'composer') { event.preventDefault(); finishTopicNaming(true); }
      else if (event.key === 'Escape') { event.preventDefault(); finishTopicNaming(false); }
    };
    const cancel = node('button', '×', 'topic-clear'); cancel.type = 'button'; cancel.setAttribute('aria-label', 'Cancel topic name'); cancel.onclick = () => finishTopicNaming(false);
    chip.append(node('span', '#', 'topic-hash'), input, cancel); plus.replaceWith(chip); deps.layout(chip);
    interaction.naming = { kind: 'naming', target, scope: filterKey(), sessionId: current.state.sessionId, chip, input }; input.focus();
  }
  function topicChip(name: TopicName, clear = false) {
    const mark = node('span', undefined, 'topic-chip');
    mark.dataset.topic = name;
    mark.style.setProperty('--topic-color', topicColour(name));
    mark.title = name; mark.append(topicName(name));
    if (clear) {
      const button = node('button', '×', 'topic-clear'); button.type = 'button'; button.setAttribute('aria-label', 'Drop composer topic'); button.onclick = dropComposer; mark.append(button);
    } else {
      mark.setAttribute('role', 'button'); mark.tabIndex = -1;
      mark.setAttribute('aria-label', 'Compose in topic ' + name); mark.onclick = () => setComposerTopic(name);
      mark.onkeydown = event => { if (event.key === 'Enter' || event.key === ' ') { event.preventDefault(); event.stopPropagation(); setComposerTopic(name); } };
    }
    return mark;
  }
  function messageHeader(name: TopicName | undefined, at?: number, target?: Extract<TopicNamingTarget, { kind: 'message' }>) {
    if (target && interaction.naming?.scope === filterKey() && interaction.naming.target.kind === 'message' && interaction.naming.target.key === target.key && interaction.naming.chip.parentElement?.classList.contains('message-header')) return interaction.naming.chip.parentElement;
    const row = node('div', undefined, 'message-header');
    if (name && !topicFilter() && current.state.view.type === 'root') row.append(topicChip(name));
    if (target && current.state.view.type === 'root') row.append(interaction.naming?.scope === filterKey() && interaction.naming.target.kind === 'message' && interaction.naming.target.key === target.key ? interaction.naming.chip : newTopicChip(target));
    if (at !== undefined) { const time = node('time', timestamp(at)); time.dateTime = new Date(at).toISOString(); row.append(time); }
    return row;
  }
  let topicDragged = false;
  function dragTopic(event: PointerEvent, source: HTMLElement, from: TopicName) {
    if (event.button !== 0 || !event.isPrimary) return;
    interaction.drag?.cancel();
    const scope = filterKey(), sessionId = current.state.sessionId, startX = event.clientX, startY = event.clientY;
    let dragging = false, ended = false, target: HTMLElement | undefined, hovered: HTMLElement | undefined, eligible = false;
    const mark = (next: HTMLElement | undefined) => {
      target?.classList.remove('drop-target'); target?.style.removeProperty('--drop-color');
      target = next;
      target?.style.setProperty('--drop-color', topicColour(from)); target?.classList.add('drop-target');
    };
    const move = (moved: PointerEvent) => {
      if (!dragging && Math.hypot(moved.clientX - startX, moved.clientY - startY) < 5) return;
      if (!dragging) { dragging = true; source.classList.add('dragging'); document.body.classList.add('topic-dragging'); }
      moved.preventDefault();
      const scroller = element('scroll').getBoundingClientRect();
      if (moved.clientX >= scroller.left && moved.clientX <= scroller.right) element('scroll').scrollBy(0, moved.clientY < scroller.top + 48 ? -24 : moved.clientY > scroller.bottom - 48 ? 24 : 0);
      const under = document.elementFromPoint(moved.clientX, moved.clientY);
      const row = under?.closest<HTMLElement>('.topic-entry[data-topic]') ?? undefined;
      const message = row ? undefined : under?.closest<HTMLElement>('#items > [data-seq]') ?? undefined, item = message && items.get(Number(message.dataset.seq));
      if (message !== hovered) {
        hovered = message;
        const targets = item && topicTurn(items.values(), item.seq);
        eligible = !!targets?.every(target => target.final) && (topicFilter() !== undefined || targets.some(target => target.kind === 'user' ? target.topic !== from : target.blocks.some(block => block.topic !== from)));
      }
      mark(row ? row.dataset.topic !== from ? row : undefined : eligible ? message : undefined);
    };
    const cancel = (key: KeyboardEvent) => { if (key.key === 'Escape') { key.preventDefault(); key.stopImmediatePropagation(); end(); } };
    const end = (event?: PointerEvent) => {
      if (ended) return;
      ended = true; interaction.drag = undefined;
      document.removeEventListener('keydown', cancel, true);
      document.removeEventListener('pointermove', move); document.removeEventListener('pointerup', end); document.removeEventListener('pointercancel', end);
      source.classList.remove('dragging'); document.body.classList.remove('topic-dragging');
      const dropped = event?.type === 'pointerup' && scope === filterKey() ? target : undefined;
      mark(undefined);
      if (!dragging) return;
      topicDragged = true; setTimeout(() => { topicDragged = false; });
      const into = parseTopicName(dropped?.dataset.topic);
      if (into) void moveTopic(from, into, scope, sessionId);
      else if (dropped?.dataset.seq !== undefined) void deps.correct({ kind: 'message', sessionId, seq: Number(dropped.dataset.seq), topic: from }).catch(() => {});
    };
    interaction.drag = { kind: 'drag', cancel: () => end() };
    document.addEventListener('keydown', cancel, true);
    document.addEventListener('pointermove', move); document.addEventListener('pointerup', end); document.addEventListener('pointercancel', end);
  }
  async function moveTopic(from: TopicName, to: TopicName, scope: string, sessionId: string | undefined) {
    const filter = scopes.get(scope)?.filter, move = { from, to };
    scopeData(scope).move = move;
    try {
      await deps.correct({ kind: 'move', sessionId, from, to });
      const choice = scopes.get(scope)?.composer;
      if ((choice?.type === 'topic' ? choice.name : choice ? undefined : scopes.get(scope)?.filter) === from) scopeData(scope).composer = { type: 'topic', name: to };
      if (filter === from && scopes.get(scope)?.filter === from) {
        updateTopicFilter(to, scope);
      } else if (filterKey() === scope) refreshComposer();
    } catch {}
    finally { if (scopes.get(scope)?.move === move) delete scopeData(scope).move; }
  }
  let topicClick: number | undefined;
  function clickTopic(event: MouseEvent, entry: HTMLElement, name: TopicName) {
    if (topicDragged || interaction.rename) return;
    clearTimeout(topicClick);
    if (event.detail === 0) setTopic(name);
    else if (event.detail === 1) { const scope = filterKey(); topicClick = setTimeout(() => { topicClick = undefined; if (filterKey() === scope) setTopic(name); }, 250); }
    else renameTopic(entry, name);
  }
  function renameTopic(entry: HTMLElement, name: TopicName) {
    const label = entry.querySelector('.topic-name');
    if (!label) return;
    interaction.rename?.cancel();
    const scope = filterKey(), sessionId = current.state.sessionId;
  
    const input = node('input', undefined, 'topic-rename');
    input.value = name; input.spellcheck = false; input.setAttribute('aria-label', 'Topic name');
    let done = false;
    const finish = (commit: boolean) => {
      if (done) return;
      done = true; interaction.rename = undefined;
      const to = commit && scope === filterKey() ? parseTopicName(input.value) : undefined;
      row.remove(); renderTopics();
      if (to && to !== name) void moveTopic(name, to, scope, sessionId);
    };
    interaction.rename = { kind: 'rename', cancel: () => finish(false) };
    input.onkeydown = event => {
      event.stopPropagation();
      if (event.key === 'Enter') { event.preventDefault(); finish(true); }
      else if (event.key === 'Escape') { event.preventDefault(); finish(false); }
    };
    input.onkeyup = event => { event.stopPropagation(); event.preventDefault(); };
    input.onpointerdown = event => event.stopPropagation();
    input.onclick = event => event.stopPropagation();
    input.onblur = () => finish(true);
    const row = node('div', undefined, entry.className + ' renaming');
    const hash = node('span', '#', 'topic-name'); hash.style.setProperty('--topic-color', topicColour(name));
    row.append(hash, input);
    entry.replaceWith(row);
    input.focus(); input.select();
  }
  function topicMode(paneWidth: number, transcriptWidth: number, cellWidth: number): 'line' | 'block' {
    return paneWidth - transcriptWidth - 28 >= 30 * cellWidth ? 'block' : 'line';
  }
  function toggleTopics() {
    if (element('topics').dataset.mode === 'block') return;
    const panel = element('topics').querySelector<HTMLElement>('.topic-panel');
    if (panel) { const open = panel.hidden; renderTopics(); const current = element('topics').querySelector<HTMLElement>('.topic-panel'); if (current) current.hidden = !open; element('topics').querySelector(topicFilter() ? '.topic-open' : '.topic-overflow')?.setAttribute('aria-expanded', String(open)); }
  }
  function closeTopics() {
    const panel = element('topics').querySelector<HTMLElement>('.topic-panel');
    if (panel && element('topics').dataset.mode !== 'block') panel.hidden = true;
    element('topics').querySelector(topicFilter() ? '.topic-open' : '.topic-overflow')?.setAttribute('aria-expanded', 'false');
  }
  function topicAge(at: number, now: number): string {
    const minutes = Math.max(0, Math.floor((now - at) / 60000));
    return minutes < 1 ? 'now' : minutes < 60 ? minutes + 'm' : minutes < 1440 ? Math.floor(minutes / 60) + 'h' : Math.floor(minutes / 1440) + 'd';
  }
  function unreadBadge(name: TopicName, unread: ReadonlyMap<TopicName, number>) {
    const count = name === topicFilter() ? 0 : unread.get(name) ?? 0;
    return count ? node('span', count > 99 ? '99+' : String(count), 'topic-unread') : undefined;
  }
  function fitTopics(width = document.documentElement.clientWidth, unread = deps.unread()) {
    const capsule = topicCapsule;
    if (!capsule || capsule.selected || capsule.width === width) return;
    const button = capsule.view.querySelector<HTMLElement>('.topic-open');
    if (!button) return;
    button.classList.remove('single');
    const children: HTMLElement[] = [], labels = capsule.names.map(name => {
      const label = topicName(name); label.setAttribute('role', 'button'); label.tabIndex = -1;
      const badge = unreadBadge(name, unread); if (badge) label.append(badge);
      label.onclick = () => setTopic(name);
      label.onkeydown = event => { if (event.key === 'Enter' || event.key === ' ') { event.preventDefault(); setTopic(name); } };
      if (children.length) children.push(node('span', '·', 'topic-separator'));
      children.push(label);
      return label;
    });
    const more = node('button', '…', 'topic-overflow'); more.type = 'button'; more.setAttribute('aria-label', 'Choose topic'); more.setAttribute('aria-expanded', String(element('topics').querySelector<HTMLElement>('.topic-panel')?.hidden === false)); more.onclick = toggleTopics;
    button.replaceChildren(...children, more);
    const measured = button.scrollWidth + capsule.view.getBoundingClientRect().width - button.getBoundingClientRect().width;
    if (measured > Math.max(0, width - 16) && labels.length > 1) {
      const ends = labels.map(label => label.getBoundingClientRect().right), separator = children[1].getBoundingClientRect().width, gap = parseFloat(getComputedStyle(button).columnGap);
      const counts = labels.slice(1).map((_, index) => node('span', '+' + (labels.length - index - 1), 'topic-more'));
      button.append(...counts);
      const widths = counts.map(label => label.getBoundingClientRect().width);
      let count = labels.length - 1;
      while (count > 1 && measured - (ends[ends.length - 1] - ends[count - 1]) + separator + widths[count - 1] + 2 * gap > Math.max(0, width - 16)) count--;
      const separatorNode = node('span', '·', 'topic-separator');
      const fits = (count: number) => {
        button.replaceChildren(...children.slice(0, 2 * count - 1), separatorNode, counts[count - 1], more);
        return button.scrollWidth + capsule.view.getBoundingClientRect().width - button.getBoundingClientRect().width <= Math.max(0, width - 16);
      };
      while (count < labels.length - 1 && fits(count + 1)) count++;
      while (!fits(count) && count > 1) count--;
      button.classList.toggle('single', count === 1);
    } else button.classList.toggle('single', labels.length <= 1);
    capsule.width = width;
  }
  function refreshAge(entry: HTMLElement, topic: Topic, unread: ReadonlyMap<TopicName, number>) {
    const age = entry.querySelector('.topic-age');
    if (!age) return;
    const badge = unreadBadge(topic.name, unread);
    const archive = age.querySelector('.topic-archive');
    age.replaceChildren();
    if (badge) age.append(badge);
    else if (topic.last) {
      const time = node('time', topicAge(topic.last.at, Date.now())); time.dateTime = new Date(topic.last.at).toISOString(); age.append(time);
    }
    if (archive) age.append(archive);
  }
  function renderTopics() {
    const unread = deps.unread(), records = new Map(('topics' in current.state ? current.state.topics : []).map(topic => [topic.name, topic]));
    for (const entry of element('topics').querySelectorAll<HTMLElement>('.topic-panel>.topic-entry')) {
      const name = parseTopicName(entry.dataset.topic), topic = name && records.get(name);
      if (!topic) continue;
      if (entry.querySelector('.topic-unread')?.textContent !== unreadBadge(topic.name, unread)?.textContent && topicCapsule) topicCapsule.width = undefined;
      if (interaction.rename) refreshAge(entry, topic, unread);
    }
    if (interaction.rename) { fitTopics(undefined, unread); return; }
    const host = element('topics'), filter = topicFilter();
    host.hidden = current.state.view.type !== 'root' || !('topics' in current.state) || !current.state.topics.length;
    const column = element('transcript').getBoundingClientRect(), width = document.documentElement.clientWidth;
    const mode = topicMode(width, column.width, topicMeasure.getBoundingClientRect().width);
    const previousMode = host.dataset.mode; host.dataset.mode = mode;
    document.body.classList.toggle('with-topics', !host.hidden && mode === 'line');
    host.style.left = mode === 'block' ? column.left + column.width + 20 + 'px' : '';
    host.style.width = mode === 'block' ? Math.min(360, width - column.width - 28) + 'px' : '';
    if (!('topics' in current.state) || host.hidden) { host.replaceChildren(); topicCapsule = undefined; return; }
    const previousPanel = host.querySelector<HTMLElement>('.topic-panel'), open = previousMode === 'line' && previousPanel?.hidden === false;
    const scrollTop = previousPanel?.scrollTop ?? 0;
    const topics = current.state.topics.map((topic, index) => ({ ...topic, index })).sort((a, b) => Number(!!a.archived) - Number(!!b.archived) || (a.last && b.last ? b.last.at - a.last.at || b.index - a.index : a.last ? 1 : b.last ? -1 : b.index - a.index));
    const names = topics.filter(topic => !topic.archived).map(topic => topic.name), changed = !topicCapsule || topicCapsule.selected !== filter || names.length !== topicCapsule.names.length || names.some((name, index) => name !== topicCapsule?.names[index]);
    if (mode === 'block') topicCapsule = undefined;
    else if (changed) {
      const capsule = node('div', undefined, 'topic-capsule'), button = node(filter ? 'button' : 'div', undefined, 'topic-open');
      button.setAttribute('aria-label', 'Topics');
      if (filter) { button.setAttribute('type', 'button'); button.onclick = toggleTopics; }
      if (filter) { button.classList.add('single'); const label = topicName(filter); label.classList.toggle('archived', !!current.state.topics.find(topic => topic.name === filter)?.archived); button.append(label); }
      capsule.append(button);
      if (filter) { const clear = node('button', '×', 'topic-clear'); clear.type = 'button'; clear.setAttribute('aria-label', 'All topics'); clear.onclick = () => setTopic(undefined); capsule.append(clear); }
      topicCapsule = { view: capsule, names, selected: filter };
    }
    const capsule = topicCapsule?.view;
    if (filter) capsule?.querySelector('.topic-open')?.setAttribute('aria-expanded', String(open));
    const panel = node('div', undefined, 'topic-panel'); panel.hidden = mode === 'line' && !open; panel.setAttribute('aria-label', 'Choose topic');
    for (const topic of topics) {
      const entry = node('div', undefined, 'topic-entry'); entry.setAttribute('role', 'button'); entry.tabIndex = -1; entry.dataset.topic = topic.name;
      entry.classList.toggle('archived', !!topic.archived);
      entry.classList.toggle('current', topic.name === filter); entry.setAttribute('aria-pressed', String(topic.name === filter));
      const label = topicName(topic.name); label.classList.add('topic-toggle'); entry.append(label);
      const age = node('span', undefined, 'topic-age');
      if (topic.last) {
        entry.append(node('span', markdownLine(topic.last.summary), 'topic-summary'));
      }
      const archive = node('button', topic.archived ? '↺' : '×', 'topic-archive'); archive.type = 'button'; archive.setAttribute('aria-label', topic.archived ? 'Restore topic' : 'Archive topic');
      archive.onpointerdown = event => { if (interaction.naming?.target.kind === 'message') finishTopicNaming(false); event.stopPropagation(); };
      archive.onclick = event => { event.stopPropagation(); void deps.correct({ kind: 'archive', sessionId: current.state.sessionId, name: topic.name, archived: !topic.archived }).catch(() => {}); };
      age.append(archive); entry.append(age); refreshAge(entry, topic, unread);
      entry.onkeydown = event => { if (event.target === entry && (event.key === 'Enter' || event.key === ' ')) { event.preventDefault(); setTopic(topic.name); } };
      entry.onpointerdown = event => dragTopic(event, entry, topic.name);
      entry.onclick = event => clickTopic(event, entry, topic.name); panel.append(entry);
    }
    if (filter) { const all = node('button', 'All topics', 'topic-entry topic-all'); all.type = 'button'; all.onclick = () => setTopic(undefined); panel.append(all); }
    host.replaceChildren(...(capsule ? [capsule, panel] : [panel]));
    if (open || previousMode === 'block' && mode === 'block') panel.scrollTop = scrollTop;
    if (capsule && !filter) fitTopics(undefined, unread);
    for (const mark of [...element('items').querySelectorAll<HTMLElement>('.topic-chip,.topic-name'), ...host.querySelectorAll<HTMLElement>('.topic-name')]) {
      const name = parseTopicName(mark.dataset.topic), topic = name && records.get(name);
      if (topic) mark.style.setProperty('--topic-color', topicColour(topic.name));
    }
  }

  function cancel() { finishTopicNaming(false); interaction.rename?.cancel(); interaction.drag?.cancel(); }
  return {
    update(next: State, previousScope: string) {
      const scope = filterKey(next), filter = scopes.get(scope)?.filter, move = scopes.get(scope)?.move;
      const reconciled = (next.life.type === 'ready' || next.life.type === 'failed') && filter && 'topics' in next && !next.topics.some(topic => topic.name === filter)
        ? move?.from === filter && next.topics.some(topic => topic.name === move.to) ? move.to : undefined
        : filter;
      if (scope !== previousScope && reconciled !== filter) { if (reconciled) scopeData(scope).filter = reconciled; else delete scopeData(scope).filter; }
      if (scope !== previousScope) { cancel(); clearTimeout(topicClick); topicClick = undefined; }
      if (scope === previousScope && reconciled !== filter) updateTopicFilter(reconciled);
    },
    cancel, dropComposer, scope: filterKey, filter: topicFilter, composer: composerTopicName, render: renderTopics,
    renderComposer() {
      if (interaction.naming && interaction.naming.scope !== filterKey()) finishTopicNaming(false);
      const topic = clearableComposerTopic();
      if (interaction.naming?.target.kind !== 'composer' || !composerTopic.contains(interaction.naming.chip)) {
        composerTopic.remove(); composerTopic.replaceChildren();
        if (current.state.view.type === 'root') {
          if (interaction.naming?.target.kind === 'composer') composerTopic.append(interaction.naming.chip);
          else if (topic) composerTopic.append(topicChip(topic, true));
          else composerTopic.append(newTopicChip({ kind: 'composer' }));
          element('field').prepend(composerTopic);
        }
      }
    },
    header: messageHeader,
    cancelMessage(seq: number) { if (interaction.naming?.target.kind === 'message' && interaction.naming.target.seq === seq) finishTopicNaming(false); },
    namingChip: () => interaction.naming?.chip,
    pointerDown(event: PointerEvent) { if (interaction.naming?.target.kind === 'message' && !interaction.naming.chip.contains(event.target instanceof Node ? event.target : null)) finishTopicNaming(false); if (!element('topics').contains(event.target instanceof Node ? event.target : null)) closeTopics(); },
    close: closeTopics,
    resize(entries: ResizeObserverEntry[]) {
      if (entries.some(({ target }) => target === topicMeasure) && topicCapsule) delete topicCapsule.width;
      if (entries.some(({ target }) => target === element('scroll') || target === topicMeasure)) renderTopics();
    },
    measure: topicMeasure,
    memory(): TopicsMemory {
      const filters: TopicsMemory['filters'] = [], composerTopics: TopicsMemory['composerTopics'] = [];
      for (const [scope, value] of scopes) { if (value.filter) filters.push([scope, value.filter]); if (value.composer) composerTopics.push([scope, value.composer]); }
      return { filters, composerTopics };
    },
  };
}
