import { defineConfig } from 'astro/config';
import { deployment } from './site.config.mjs';

export default defineConfig({
  ...deployment,
  output: 'static',
  trailingSlash: 'always',
});
