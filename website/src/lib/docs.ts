import { url } from './site';

export const groups = [
  { name: 'Start', mark: 's-ok' },
  { name: 'ko', mark: 's-fail' },
  { name: 'Kido.app', mark: 's-run' },
  { name: 'koa', mark: 's-wait' },
] as const;
export type Group = (typeof groups)[number]['name'];
export type Frontmatter = { title: string; group: Group; order: number };

const files = import.meta.glob<Frontmatter>('../pages/docs/*.{md,astro}', { import: 'frontmatter' });
export const loadPages = async () =>
  (await Promise.all(Object.entries(files).map(async ([file, load]) => {
    const slug = file.slice(file.lastIndexOf('/') + 1, file.lastIndexOf('.'));
    return { ...(await load()), href: url(slug === 'index' ? 'docs/' : `docs/${slug}/`) };
  }))).sort((a, b) =>
    groups.findIndex((g) => g.name === a.group) - groups.findIndex((g) => g.name === b.group) || a.order - b.order);
