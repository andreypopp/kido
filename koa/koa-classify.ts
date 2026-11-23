import type { Context } from '@earendil-works/pi-ai';
import type { ModelRuntime } from '@earendil-works/pi-coding-agent';
import { parseTopicName, type TopicName } from './records.ts';
import { contentText, utf8Prefix, cleanLine } from './text.ts';
import type { Item, QueuedPrompt } from './koa-records.ts';

export type TopicContext = { name: TopicName; messages: { from: 'user' | 'assistant'; text: string }[] }[];

export function topicContext(items: readonly Item[], indexed: readonly TopicName[], queued: readonly QueuedPrompt[], archived: ReadonlySet<TopicName>): { topics: TopicContext; others: TopicName[] } {
  const messages = new Map<TopicName, TopicContext[number]['messages']>();
  const add = (name: TopicName | undefined, from: 'user' | 'assistant', text: string) => {
    if (!name || archived.has(name) || !text.trim()) return;
    const previous = messages.get(name) ?? [];
    messages.delete(name);
    messages.set(name, [...previous, { from, text }].slice(-3));
  };
  for (const item of items) {
    if (item.kind === 'user') add(item.topic, 'user', item.text);
    else if (item.kind === 'assistant') for (const block of item.blocks) if (block.type === 'text') add(block.topic, 'assistant', block.text);
  }
  for (const prompt of queued) add(prompt.topic, 'user', prompt.text);
  const topics = [...messages].slice(-5).map(([name, messages]) => ({ name, messages: messages.map(message => ({ ...message, text: cleanLine(message.text, 300) })) }));
  return { topics, others: indexed.filter(name => !archived.has(name) && !topics.some(topic => topic.name === name)) };
}

const quoteText = (text: string): string => text.replace(/[*_`]/g, '').replace(/\s+/g, ' ').trim();

export function topicQuotes(text: string): string[] {
  const quotes: string[] = [];
  let open = false;
  for (const line of text.split(/\r?\n/)) {
    const quoted = /^\s*>+\s?(.*)$/.exec(line);
    if (quoted && open) quotes[quotes.length - 1] += '\n' + quoted[1];
    else if (quoted) quotes.push(quoted[1]);
    open = !!quoted;
  }
  return quotes.map(quoteText).filter(quote => quote.length >= 12);
}

export function quotedTopic(items: readonly Item[], wanted: readonly string[], archived: ReadonlySet<TopicName>, project: (item: Item) => Item = item => item): TopicName | undefined {
  if (!wanted.length) return;
  const sections = items.filter(item => item.kind === 'assistant').slice(-20).map(project).flatMap(item => item.kind === 'assistant' ? item.blocks.flatMap(block => block.type === 'text' && block.topic && !archived.has(block.topic) ? [{ topic: block.topic, text: quoteText(block.text) }] : []) : []);
  const found = new Set<TopicName>();
  for (const quote of wanted) {
    const topics = new Set(sections.filter(section => section.text.includes(quote)).map(section => section.topic));
    if (topics.size !== 1) return;
    for (const topic of topics) found.add(topic);
  }
  return found.size === 1 ? [...found][0] : undefined;
}

export function classifierPrompt(topics: TopicContext, others: TopicName[], text: string): Context {
  return {
    systemPrompt: [
      'Answer with one topic name and nothing else.',
      'A message with no subject of its own (yes, continue, why?, ok restarted, done and so on) belongs to the current topic: answer with its name exactly as written.',
      'Use an existing topic if one fits the new user message.',
      'Make a new topic when the user starts a new topic or discussion. But check that this message is not a response to the previous topics.',
      'If the user asks for something to be worked on "in parallel", that might be a new topic.',
      'Name its subject as a short, clear topic of 2 to 6 words and at most 60 characters, without ] and without a final period, for example Reload UI open items or Pane resize bug.',
      'We want to replicate how Zulip organizes conversations with topics.',
      'The motivation to mark messages with topics is to track parallel topics of work within the conversation.',
    ].join('\n'),
    messages: [{ role: 'user', content: ['Topics of this session, oldest first. The last one is the current topic.', ...topics.flatMap(topic => [`## ${topic.name}`, ...topic.messages.map(message => `${message.from}: ${message.text}`)]), 'Other topics:', ...others.map(name => `- ${name}`), 'New message:', utf8Prefix(text, 2000)].join('\n'), timestamp: Date.now() }],
  };
}

export function parseClassification(reply: string): TopicName | undefined {
  const line = reply.split('\n').map(text => text.trim()).find(Boolean) ?? '';
  const value = (/^\[topic: ([^\]]*)\]$/.exec(line)?.[1] ?? line).replace(/^(["'`*]+)(.*)\1$/, '$2').replace(/^(?:topic:\s*)?#?/i, '').replace(/\.$/, '').trim();
  const words = value.split(' ');
  while (words.length > 1 && words.join(' ').length > 200) words.pop();
  return parseTopicName(words.join(' '));
}

export async function classify(runtime: ModelRuntime, model: { provider: string; id: string }, topics: TopicContext, others: TopicName[], text: string, signal: AbortSignal): Promise<TopicName> {
  const found = runtime.getModel(model.provider, model.id);
  if (!found) throw Error(`unknown topic model ${model.provider}/${model.id}`);
  const reply = await runtime.completeSimple(found, classifierPrompt(topics, others, text), { maxRetries: 0, signal });
  if (signal.aborted) throw signal.reason;
  if (reply.stopReason === 'error' || reply.stopReason === 'aborted') throw Error(reply.errorMessage ?? reply.stopReason);
  const answer = contentText(reply.content), name = parseClassification(answer);
  if (!name || reply.content.some(block => block.type === 'toolCall')) throw Error(`invalid topic classification (stop: ${reply.stopReason}, blocks: ${reply.content.map(block => block.type).join(', ') || 'none'}): ${JSON.stringify(utf8Prefix(answer, 200))}`);
  return name;
}
