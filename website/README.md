# kido website

Astro, built as static files. Requires Node 22.12+ (Node 24 recommended).

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

## Media

Put recordings in `public/media/`:

- `tmux.mp4`, `tmux.webm`, `tmux.jpg`
- `subagents.mp4`, `subagents.webm`, `subagents.jpg`
- `async.mp4`, `async.webm`, `async.jpg`

Each recording also has `-mobile` MP4, WebM, and JPG variants. Desktop
recordings are 5:3; mobile recordings are 4:5. Media paths live in
`src/lib/site.ts`. Videos are muted and looping, have a pause control,
and don't autoplay for reduced motion. Feature videos start near the viewport.
The `demo/` directory is managed separately by the recording workstream.
