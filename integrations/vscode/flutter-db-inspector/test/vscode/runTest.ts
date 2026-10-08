import { existsSync, mkdtempSync } from 'node:fs';
import { tmpdir } from 'node:os';
import * as path from 'node:path';

import { runTests } from '@vscode/test-electron';

/** Launches VS Code with the extension under development and runs the suite. */
async function main(): Promise<void> {
  const extensionDevelopmentPath = path.resolve(__dirname, '../../..');
  const extensionTestsPath = path.resolve(__dirname, 'suite/index');
  // Prefer a locally installed VS Code (no download); otherwise test-electron fetches one.
  const local = '/Applications/Visual Studio Code.app/Contents/MacOS/Code';
  await runTests({
    extensionDevelopmentPath,
    extensionTestsPath,
    vscodeExecutablePath: process.env.VSCODE_EXECUTABLE ?? (existsSync(local) ? local : undefined),
    launchArgs: [
      '--disable-extensions',
      '--skip-welcome',
      '--skip-release-notes',
      `--user-data-dir=${mkdtempSync(path.join(tmpdir(), 'fdi-vscode-'))}`,
    ],
  });
}

main().catch((error: unknown) => {
  console.error(error);
  process.exit(1);
});
