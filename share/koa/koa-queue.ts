import type { Attachment, QueuedPrompt } from './koa-records.ts';
import { promptText } from './prompt.ts';

type Sent = { text: string; mode: 'prompt' | 'steer' | 'followUp'; attachments: Attachment[] };
type Queue = { steering: readonly string[]; followUp: readonly string[] };

export function prompts() {
  const sent: Sent[] = [];
  let queue: Queue = { steering: [], followUp: [] };
  let next: { text: string; entry?: Sent } | undefined;
  let phase: 'live' | 'clearing' = 'live';
  // pi does not remove an empty message from its queue (agent-session.js:747).
  const usedEmpty = { steer: 0, followUp: 0 };
  const freshTexts = (texts: readonly string[], mode: 'steer' | 'followUp') => {
    let skip = usedEmpty[mode];
    return texts.filter(text => { if (text || !skip) return true; skip--; return false; });
  };
  const take = (mode: Sent['mode'], text: string, skip?: Sent) => {
    const index = sent.findIndex(entry => entry !== skip && entry.mode === mode && entry.text === text);
    return index < 0 ? [] : sent.splice(index, 1)[0]?.attachments ?? [];
  };
  const entries = (texts: readonly string[], mode: 'steer' | 'followUp'): QueuedPrompt[] => {
    const available = sent.filter(entry => entry.mode === mode && entry !== next?.entry);
    return freshTexts(texts, mode).map(text => {
      const index = available.findIndex(entry => entry.text === text);
      const attachments = index < 0 ? [] : available.splice(index, 1)[0]?.attachments ?? [];
      return { text: promptText(text, attachments), attachments };
    }).filter(entry => entry.text !== '' || entry.attachments.length > 0);
  };
  return {
    add(text: string, mode: Sent['mode'], attachments: Attachment[]) { const entry = { text, mode, attachments }; sent.push(entry); return entry; },
    reject(entry: Sent) { const index = sent.indexOf(entry); if (index >= 0) sent.splice(index, 1); },
    start(text: string) {
      const mark = next; next = undefined;
      if (mark) {
        const index = text === mark.text && mark.entry ? sent.indexOf(mark.entry) : -1;
        return index < 0 ? [] : sent.splice(index, 1)[0]?.attachments ?? [];
      }
      if (text) return take('prompt', text);
      const entry = sent.find(entry => entry.text === '' && entry.mode === 'steer') ?? sent.find(entry => entry.text === '' && entry.mode === 'followUp') ?? sent.find(entry => entry.text === '' && entry.mode === 'prompt');
      const steering = freshTexts(queue.steering, 'steer'), followUp = freshTexts(queue.followUp, 'followUp');
      const mode = steering.includes('') ? 'steer' : followUp.includes('') ? 'followUp' : entry?.mode ?? 'prompt';
      if (mode !== 'prompt' && (mode === 'steer' ? steering : followUp).includes('')) usedEmpty[mode]++;
      return take(mode, '');
    },
    update(value: Queue) {
      if (phase === 'live') for (const [old, fresh, mode] of [[queue.steering, value.steering, 'steer'], [queue.followUp, value.followUp, 'followUp']] as const) {
        const previous = freshTexts(old, mode);
        usedEmpty[mode] = Math.min(usedEmpty[mode], fresh.filter(text => text === '').length);
        const remaining = freshTexts(fresh, mode);
        for (const text of previous) { const index = remaining.indexOf(text); if (index < 0) next = { text, entry: sent.find(entry => entry.mode === mode && entry.text === text) }; else remaining.splice(index, 1); }
      }
      queue = value;
    },
    view() { return { steering: entries(queue.steering, 'steer'), followUp: entries(queue.followUp, 'followUp') }; },
    beginClear() { if (phase === 'clearing') throw Error('Queue take-back is in progress'); phase = 'clearing'; },
    endClear() { phase = 'live'; usedEmpty.steer = Math.min(usedEmpty.steer, queue.steering.filter(text => text === '').length); usedEmpty.followUp = Math.min(usedEmpty.followUp, queue.followUp.filter(text => text === '').length); },
    takeBack(value: Queue) {
      const result = { steering: entries(value.steering, 'steer'), followUp: entries(value.followUp, 'followUp') };
      for (const text of freshTexts(value.steering, 'steer')) take('steer', text, next?.entry);
      for (const text of freshTexts(value.followUp, 'followUp')) take('followUp', text, next?.entry);
      queue = { steering: [], followUp: [] }; usedEmpty.steer = 0; usedEmpty.followUp = 0;
      return result;
    },
    reset() { sent.length = 0; next = undefined; queue = { steering: [], followUp: [] }; usedEmpty.steer = 0; usedEmpty.followUp = 0; },
  };
}
