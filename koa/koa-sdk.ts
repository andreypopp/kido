import { realpathSync } from 'node:fs';
import { createRequire, registerHooks } from 'node:module';
import { join } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

export type Sdk = {
  pi: typeof import('@earendil-works/pi-coding-agent');
  builtInExtensions: import('@earendil-works/pi-coding-agent').ExtensionFactory[];
  resolveProjectTrusted(options: object): Promise<boolean>;
  createProjectTrustContext(options: object): import('@earendil-works/pi-coding-agent').ProjectTrustContext;
  isLocalPath(value: string): boolean;
  resolvePath(value: string, cwd: string): string;
  theme: import('@earendil-works/pi-coding-agent').ExtensionUIContext['theme'];
};

// The installed koa has no node_modules.
export async function loadSdk(root: string): Promise<Sdk> {
  const dist = (file: string) => pathToFileURL(join(root, 'dist', file)).href;
  const pi = dist('index.js');
  const require = createRequire(join(realpathSync(root), 'package.json'));
  const typebox = pathToFileURL(require.resolve('typebox')).href;
  const marked = pathToFileURL(require.resolve('marked')).href;
  const real = realpathSync(fileURLToPath(new URL('.', import.meta.url))), own = pathToFileURL(real.endsWith('/') ? real : real + '/').href;
  registerHooks({
    resolve(specifier, context, next) {
      if (context.parentURL?.startsWith(own)) {
        if (specifier === '@earendil-works/pi-coding-agent') return { url: pi, shortCircuit: true };
        if (specifier === 'typebox') return { url: typebox, shortCircuit: true };
        if (specifier === 'marked') return { url: marked, shortCircuit: true };
      }
      return next(specifier, context);
    },
  });
  const [index, extensions, trust, cliTrust, paths, theme] = await Promise.all(['index.js', 'extensions/index.js', 'core/project-trust.js', 'cli/project-trust.js', 'utils/paths.js', 'modes/interactive/theme/theme.js'].map(file => import(dist(file))));
  return { pi: index, builtInExtensions: extensions.builtInExtensions, resolveProjectTrusted: trust.resolveProjectTrusted, createProjectTrustContext: cliTrust.createProjectTrustContext, isLocalPath: paths.isLocalPath, resolvePath: paths.resolvePath, theme: theme.theme };
}
