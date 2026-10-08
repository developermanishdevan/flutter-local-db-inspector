// Builds the standalone UI for hosts other than VS Code (Android Studio via
// JCEF, DevTools via an iframe) into dist/:
//
//   dist/index.html      page skeleton (loads everything below)
//   dist/inspector.js    the UI
//   dist/inspector.css   styles.css + theme.css (default light/dark tokens)
//   dist/codicons/       icon font
//
// The VS Code extension builds the same sources itself (see its esbuild.mjs),
// because its page is generated with a CSP nonce and takes theme tokens from
// VS Code.
import * as esbuild from 'esbuild';
import { cpSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';

const production = process.argv.includes('--production');

mkdirSync('dist/codicons', { recursive: true });
cpSync('node_modules/@vscode/codicons/dist/codicon.css', 'dist/codicons/codicon.css');
cpSync('node_modules/@vscode/codicons/dist/codicon.ttf', 'dist/codicons/codicon.ttf');
writeFileSync(
  'dist/inspector.css',
  `${readFileSync('src/theme.css', 'utf8')}\n${readFileSync('src/styles.css', 'utf8')}`,
);
cpSync('src/index.html', 'dist/index.html');

await esbuild.build({
  entryPoints: ['src/main.ts'],
  outfile: 'dist/inspector.js',
  bundle: true,
  platform: 'browser',
  format: 'iife',
  target: 'es2022',
  minify: production,
  sourcemap: !production,
  logLevel: 'info',
});
