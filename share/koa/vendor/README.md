# Vendored page modules

- marked 18.1.3, MIT: `lib/marked.esm.js` from
  https://registry.npmjs.org/marked/-/marked-18.1.3.tgz,
  copied as `marked.js`. License: `marked.LICENSE`.
- remend 1.4.0, Apache-2.0: `dist/index.js` from
  https://registry.npmjs.org/remend/-/remend-1.4.0.tgz,
  copied as `remend.js`. Source:
  https://github.com/vercel/streamdown/tree/main/packages/remend.
  License: `remend.LICENSE`.

To fetch each archive again, use `curl -fSL URL -o source.tgz` in
its own new empty directory under `/tmp`. Extract and inspect the
archive. Do not run package scripts. Copy only the ESM file and its
license. Keep these files identical to the archive. For an update,
change the pinned version and URL here and run the markdown and page
assembly tests.
