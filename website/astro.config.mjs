import { defineConfig } from 'astro/config';
import { createCssVariablesTheme } from 'shiki';
import { deployment } from './site.config.mjs';

export default defineConfig({
  ...deployment,
  output: 'static',
  trailingSlash: 'always',
  markdown: { shikiConfig: { theme: createCssVariablesTheme({ name: 'kido', variablePrefix: '--code-' }) } },
});
