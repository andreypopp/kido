import type { Annotation } from '../koa-records.ts';
import type { Mark } from './markdown.ts';
import { answer, current, plain, quote } from './answers.ts';
import type { composer } from './composer.ts';

export function update(text: string): void {
  for (const control of document.querySelectorAll<HTMLElement>('.ann-opt')) {
    const selected = current(text, control.dataset.quote ?? '');
    control.classList.toggle('sel', selected !== undefined && selected === control.dataset.answer);
  }
}

export function annotations(source: string, questions: Annotation[], editor: Pick<ReturnType<typeof composer>, 'text' | 'setText' | 'focus'>) {
  const points = Array.from(source), offsets = [0];
  for (const point of points) offsets.push(offsets[offsets.length - 1] + point.length);
  const marks: Mark[] = [];
  const actions: { quote: string; answer: string; overwrite: boolean }[] = [];
  const controls: { id: number; label: string }[][] = [];
  questions.forEach((question, index) => {
    const signature = encodeURIComponent(JSON.stringify(question));
    const text = quote(points.slice(...question.range).join(''));
    const action = (value: string, overwrite = false) => actions.push({ quote: text, answer: value, overwrite }) - 1;
    for (const [start, end] of question.kind === 'choice' ? question.options : []) {
      const id = action(plain(points.slice(start, end).join('')));
      marks.push({ offset: offsets[start], side: 'open', mark: `\uE010${id};${signature}\uE010` }, { offset: offsets[end], side: 'close', mark: '\uE011' });
    }
    const labels = question.kind === 'open' ? ['Answer'] : question.kind === 'yes_no' ? ['Yes', 'No', 'Other'] : question.options.length === 1 ? ['Yes', 'Other'] : ['Other'];
    controls[index] = labels.map(label => ({ id: action(label === 'Yes' || label === 'No' ? label : '', label === 'Other'), label }));
    marks.push({ offset: offsets[question.range[1]], side: 'close', mark: `\uE012${index};${signature}\uE012` });
  });
  marks.sort((a, b) => a.offset - b.offset);
  const button = (id: number, label?: string) => {
    const data = actions[id], result = document.createElement(label ? 'button' : 'span');
    if (result instanceof HTMLButtonElement) result.type = 'button';
    else {
      result.setAttribute('role', 'button'); result.tabIndex = 0;
      result.onkeydown = event => {
        if (event.key === 'Enter' || event.key === ' ') { event.preventDefault(); result.click(); }
      };
    }
    result.className = 'ann-opt';
    if (label) result.textContent = label;
    result.dataset.quote = data.quote; result.dataset.answer = data.answer;
    result.onclick = () => { editor.setText(answer(editor.text(), data.quote, data.answer, data.overwrite)); editor.focus(); };
    return result;
  };
  return { marks, decorate(root: DocumentFragment) {
    const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT), nodes: Text[] = [];
    while (walker.nextNode()) if (walker.currentNode instanceof Text) nodes.push(walker.currentNode);
    let opening: { node: Text; id: number } | undefined;
    for (let text of nodes) {
      for (;;) {
        const match = /\uE010(\d+);[^\uE010]*\uE010|\uE011|\uE012(\d+);[^\uE012]*\uE012/.exec(text.data);
        if (!match) break;
        const marker = text.splitText(match.index), rest = marker.splitText(match[0].length);
        if (match[1] !== undefined) opening = actions[Number(match[1])] ? { node: rest, id: Number(match[1]) } : undefined;
        else if (match[2] !== undefined && controls[Number(match[2])]) {
          const group = document.createElement('span'); group.className = 'ann-ctl';
          controls[Number(match[2])].forEach(({ id, label }) => group.append(button(id, label)));
          marker.before(group);
        } else if (match[2] === undefined && opening) {
          const range = document.createRange(); range.setStart(opening.node, 0); range.setEndBefore(marker);
          const option = button(opening.id); option.append(range.extractContents()); range.insertNode(option); opening = undefined;
        }
        marker.remove(); text = rest;
      }
    }
  } };
}
