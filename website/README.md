# kido website

Astro, built as static files. Requires Node 22.12+ (Node 24 recommended).
`make website` from the repository root installs dependencies and starts
the dev server.

```sh
cd website
npm ci
npm run dev
npm run build
npm run preview
```

The landing page is `src/pages/index.astro`.

## Deployment

`site.config.mjs` is the one-place site/base configuration. Defaults:
`https://kido.tools`, base `/`. For a project Pages preview, build with
`SITE_URL=https://andreypopp.github.io SITE_BASE=/kido npm run build`.
Internal links and media follow the base. For a domain change, update
the config and `public/CNAME`.

`.github/workflows/website.yml` deploys to GitHub Pages (GitHub Actions
source, custom domain `kido.tools`). It builds on pushes to main touching
the website, or on manual dispatch, then deploys `dist/`. The CNAME is
copied into the output.

## Design

The page is one composition in the style of Kandinsky's geometric
works. `src/components/Canvas.astro` draws it over the whole page at a
fixed width of 1440 units; `src/lib/art.ts` holds its drawing helpers,
and `src/components/Symbols.astro` holds the logo, the status marks and
the section drawings. From 1100 px the text blocks sit at fixed
positions on that canvas (`--x`, `--y`, `--w` on each `.b` block);
below 1100 px the page is one column. `src/components/Shot.astro` shows
a screenshot of `src/assets/` on a plane of the canvas, one file for
light and one for dark mode, and enlarges it on a click.
The texture is two tiled SVG noise layers in `src/styles/site.css`:
the grain and the pigment clouds, with their sizes and strengths as
custom properties on `:root`. The font is Jost, from
`@fontsource-variable/jost`.

The documentation is the markdown pages in `src/pages/docs/`, in the
layout `src/layouts/Docs.astro`: the sidebar at the left, the page in
the middle and the headings of the page at the right. A page names its
`title`, its `group` and its `order` in its frontmatter;
`src/lib/docs.ts` holds the groups and builds the sidebar from the
pages. `src/styles/base.css` holds what the landing page and the
documentation share: the colours, the font and the texture. The
documentation pages are placeholders, and the landing page does not
link to them yet.

`brand/kandinsky/` holds the app icon in this style, light and dark. The
recordings in `public/media/` and the `demo/` directory belong to the
recording workstream; the page does not use them.
