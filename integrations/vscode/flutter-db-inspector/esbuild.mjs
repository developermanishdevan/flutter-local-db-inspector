import * as esbuild from 'esbuild';
import { cpSync, mkdirSync } from 'node:fs';

// The webview UI is shared with the Android Studio and DevTools integrations.
const webUi = '../../../shared/web-ui';

const production = process.argv.includes('--production');
const watch = process.argv.includes('--watch');

mkdirSync('dist/codicons', { recursive: true });
cpSync('node_modules/@vscode/codicons/dist/codicon.css', 'dist/codicons/codicon.css');
cpSync('node_modules/@vscode/codicons/dist/codicon.ttf', 'dist/codicons/codicon.ttf');
cpSync(`${webUi}/src/styles.css`, 'dist/webview.css');

const common = {
  bundle: true,
  minify: production,
  sourcemap: !production,
  logLevel: 'info',
};

const contexts = await Promise.all([
  esbuild.context({
    ...common,
    entryPoints: ['src/extension.ts'],
    outfile: 'dist/extension.js',
    platform: 'node',
    format: 'cjs',
    target: 'node18',
    external: ['vscode', 'bufferutil', 'utf-8-validate'],
  }),
  esbuild.context({
    ...common,
    entryPoints: [`${webUi}/src/main.ts`],
    tsconfig: `${webUi}/tsconfig.json`,
    outfile: 'dist/webview.js',
    platform: 'browser',
    format: 'iife',
    target: 'es2022',
  }),
]);

if (watch) {
  await Promise.all(contexts.map((c) => c.watch()));
} else {
  await Promise.all(contexts.map((c) => c.rebuild()));
  await Promise.all(contexts.map((c) => c.dispose()));
}
