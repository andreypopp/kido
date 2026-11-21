import type { Context } from '@earendil-works/pi-ai';
import type { ModelRuntime } from '@earendil-works/pi-coding-agent';
import { parseThreadName, type ThreadName } from './records.ts';
import { contentText, utf8Prefix, cleanLine } from './text.ts';
import type { Item, QueuedPrompt } from './koa-records.ts';

export type ThreadContext = { name: ThreadName; messages: { from: 'user' | 'assistant'; text: string }[] }[];

export function threadContext(items: readonly Item[], indexed: readonly ThreadName[], queued: readonly QueuedPrompt[]): { threads: ThreadContext; others: ThreadName[] } {
  const messages = new Map<ThreadName, ThreadContext[number]['messages']>();
  const add = (name: ThreadName | undefined, from: 'user' | 'assistant', text: string) => {
    if (!name || !text.trim()) return;
    const previous = messages.get(name) ?? [];
    messages.delete(name);
    messages.set(name, [...previous, { from, text }].slice(-3));
  };
  for (const item of items) {
    if (item.kind === 'user') add(item.thread, 'user', item.text);
    else if (item.kind === 'assistant') for (const block of item.blocks) if (block.type === 'text') add(block.thread, 'assistant', block.text);
  }
  for (const prompt of queued) add(prompt.thread, 'user', prompt.text);
  const threads = [...messages].slice(-5).map(([name, messages]) => ({ name, messages: messages.map(message => ({ ...message, text: cleanLine(message.text, 300) })) }));
  return { threads, others: indexed.filter(name => !threads.some(thread => thread.name === name)) };
}

const quoteText = (text: string): string => text.replace(/[*_`]/g, '').replace(/\s+/g, ' ').trim();

export function quotedThread(items: readonly Item[], text: string): ThreadName | undefined {
  const quotes: string[] = [];
  let open = false;
  for (const line of text.split(/\r?\n/)) {
    const quoted = /^\s*>+\s?(.*)$/.exec(line);
    if (quoted && open) quotes[quotes.length - 1] += '\n' + quoted[1];
    else if (quoted) quotes.push(quoted[1]);
    open = !!quoted;
  }
  const wanted = quotes.map(quoteText).filter(quote => quote.length >= 12);
  if (!wanted.length) return;
  const sections = items.filter(item => item.kind === 'assistant').slice(-20).flatMap(item => item.blocks.flatMap(block => block.type === 'text' && block.thread ? [{ thread: block.thread, text: quoteText(block.text) }] : []));
  const found = new Set<ThreadName>();
  for (const quote of wanted) {
    const threads = new Set(sections.filter(section => section.text.includes(quote)).map(section => section.thread));
    if (threads.size !== 1) return;
    for (const thread of threads) found.add(thread);
  }
  return found.size === 1 ? [...found][0] : undefined;
}

export function classifierPrompt(threads: ThreadContext, others: ThreadName[], text: string): Context {
  return {
    systemPrompt: [
      'Answer with one thread name and nothing else.',
      'A message with no subject of its own (yes, continue, why?, ok restarted, done and so on) belongs to the current thread: answer with its name exactly as written.',
      'Use an existing thread if one fits the new user message.',
      'Make a new thread when the user starts a new topic or discussion. But check that this message is not a response to the previous threads.',
      'If the user asks for something to be worked on "in parallel", that might be a new thread.',
      'Name its subject as a short, clear topic of 2 to 6 words and at most 60 characters, without ] and without a final period, for example Reload UI open items or Pane resize bug.',
      'We want to replicate how Zulip organizes conversations with threads.',
      'The motivation to mark messages with threads is to track parallel threads of work within the conversation.',
    ].join('\n'),
    messages: [{ role: 'user', content: ['Threads of this session, oldest first. The last one is the current thread.', ...threads.flatMap(thread => [`## ${thread.name}`, ...thread.messages.map(message => `${message.from}: ${message.text}`)]), 'Other threads:', ...others.map(name => `- ${name}`), 'New message:', utf8Prefix(text, 2000)].join('\n'), timestamp: Date.now() }],
  };
}

export function parseClassification(reply: string): ThreadName | undefined {
  const line = reply.split('\n').map(text => text.trim()).find(Boolean) ?? '';
  const value = (/^\[thread: ([^\]]*)\]$/.exec(line)?.[1] ?? line).replace(/^(["'`*]+)(.*)\1$/, '$2').replace(/^(?:thread:\s*)?#?/i, '').replace(/\.$/, '').trim();
  const words = value.split(' ');
  while (words.length > 1 && words.join(' ').length > 200) words.pop();
  return parseThreadName(words.join(' '));
}

export async function classify(runtime: ModelRuntime, model: { provider: string; id: string }, threads: ThreadContext, others: ThreadName[], text: string, signal: AbortSignal): Promise<ThreadName> {
  const found = runtime.getModel(model.provider, model.id);
  if (!found) throw Error(`unknown thread model ${model.provider}/${model.id}`);
  const reply = await runtime.completeSimple(found, classifierPrompt(threads, others, text), { reasoning: 'low', maxRetries: 0, signal });
  if (signal.aborted) throw signal.reason;
  if (reply.stopReason === 'error' || reply.stopReason === 'aborted') throw Error(reply.errorMessage ?? reply.stopReason);
  const answer = contentText(reply.content), name = parseClassification(answer);
  if (!name || reply.content.some(block => block.type === 'toolCall')) throw Error(`invalid thread classification (stop: ${reply.stopReason}, blocks: ${reply.content.map(block => block.type).join(', ') || 'none'}): ${JSON.stringify(utf8Prefix(answer, 200))}`);
  return name;
}
