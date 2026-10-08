import { spawn, type ChildProcessWithoutNullStreams } from 'node:child_process';
import * as path from 'node:path';
import * as readline from 'node:readline';

/** Repository root (tests run from out/test/integration). */
export const repoRoot = path.resolve(__dirname, '../../../../../..');

/**
 * Runs the Dart demo server (a real Dart VM with the inspector and a seeded
 * SQLite database) and exposes its VM service URI.
 */
export class DemoServer {
  private constructor(
    private readonly process: ChildProcessWithoutNullStreams,
    readonly uri: string,
    private readonly lines: readline.Interface,
  ) {}

  static async start(options: { restartable?: boolean } = {}): Promise<DemoServer> {
    const cwd = path.join(repoRoot, 'packages', 'flutter_db_inspector_sqlite');
    const args = ['run', '--enable-vm-service=0', 'example/inspector_server.dart'];
    if (options.restartable) args.push('--restartable');
    const child = spawn('dart', args, { cwd });
    child.stderr.on('data', (d: Buffer) => process.stderr.write(d));
    const lines = readline.createInterface({ input: child.stdout });
    const uri = await new Promise<string>((resolve, reject) => {
      const timer = setTimeout(() => reject(new Error('demo server did not start')), 120_000);
      lines.on('line', (line) => {
        const match = /VM service is listening on (\S+)/.exec(line);
        if (match) {
          clearTimeout(timer);
          resolve(match[1]);
        }
      });
      child.once('exit', (code) => reject(new Error(`demo server exited with ${code}`)));
    });
    return new DemoServer(child, uri, lines);
  }

  /** Simulates a hot restart (restartable mode only). */
  restart(): void {
    this.process.stdin.write('restart\n');
  }

  waitForLine(pattern: RegExp, timeoutMs = 60_000): Promise<string> {
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => reject(new Error(`timed out waiting for ${pattern}`)), timeoutMs);
      const onLine = (line: string) => {
        if (pattern.test(line)) {
          clearTimeout(timer);
          this.lines.off('line', onLine);
          resolve(line);
        }
      };
      this.lines.on('line', onLine);
    });
  }

  async stop(): Promise<void> {
    if (this.process.exitCode !== null) return;
    const exited = new Promise((resolve) => this.process.once('exit', resolve));
    this.process.kill('SIGINT');
    await exited;
  }
}
