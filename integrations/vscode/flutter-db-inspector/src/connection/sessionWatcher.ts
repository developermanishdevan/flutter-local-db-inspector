import * as vscode from 'vscode';

import type { ConnectionManager, ConnectionTarget } from './connectionManager';
import { DebugAdapterTransport } from './dapTransport';
import { WebSocketTransport } from './wsTransport';

interface KnownSession {
  session: vscode.DebugSession;
  vmServiceUri?: string;
  startedAt: number;
}

/**
 * Discovers running Dart/Flutter apps from VS Code debug sessions (Dart-Code
 * publishes each session's VM service URI via `dart.debuggerUris`) and keeps
 * the connection manager attached to the most recent one.
 */
export class DebugSessionWatcher implements vscode.Disposable {
  private readonly sessions = new Map<string, KnownSession>();
  private readonly disposables: vscode.Disposable[] = [];

  constructor(
    private readonly manager: ConnectionManager,
    private readonly log: (message: string) => void,
    private readonly autoConnect: () => boolean,
  ) {
    this.disposables.push(
      vscode.debug.onDidStartDebugSession((session) => {
        if (isDart(session)) this.sessions.set(session.id, { session, startedAt: Date.now() });
      }),
      vscode.debug.onDidReceiveDebugSessionCustomEvent((e) => this.onCustomEvent(e)),
      vscode.debug.onDidTerminateDebugSession((session) => this.onTerminated(session)),
    );
    // Sessions that were already running when the extension activated.
    const active = vscode.debug.activeDebugSession;
    if (active && isDart(active)) this.sessions.set(active.id, { session: active, startedAt: Date.now() });
    if (this.autoConnect()) this.connectToLatest();
  }

  /** Debug sessions that can be inspected, newest first. */
  get candidates(): { session: vscode.DebugSession; vmServiceUri?: string }[] {
    return [...this.sessions.values()].sort((a, b) => b.startedAt - a.startedAt);
  }

  targetFor(known: { session: vscode.DebugSession; vmServiceUri?: string }): ConnectionTarget {
    const { session, vmServiceUri } = known;
    return {
      id: session.id,
      label: session.name,
      createTransport: vmServiceUri
        ? () => WebSocketTransport.connect(vmServiceUri)
        : async () => new DebugAdapterTransport(session),
    };
  }

  private onCustomEvent(e: vscode.DebugSessionCustomEvent): void {
    if (e.event !== 'dart.debuggerUris') return;
    const body = e.body as { vmServiceUri?: string; observatoryUri?: string } | undefined;
    const uri = body?.vmServiceUri ?? body?.observatoryUri;
    if (!uri) return;
    const known = this.sessions.get(e.session.id) ?? { session: e.session, startedAt: Date.now() };
    known.vmServiceUri = uri;
    this.sessions.set(e.session.id, known);
    // The URI's first path segment is the VM service auth token: keep it out of the log.
    this.log(`debug session "${e.session.name}" VM service: ${uri.replace(/^(\w+:\/\/[^/]+\/)[^/]+=\//, '$1***/')}`);
    if (!this.autoConnect()) return;
    // Prefer the newest app unless the user is connected to another live one by hand.
    const current = this.manager.currentTargetId;
    const manual = current !== undefined && !this.sessions.has(current);
    if (!manual || this.manager.snapshot.state !== 'connected') {
      void this.manager.connect(this.targetFor(known));
    }
  }

  private onTerminated(session: vscode.DebugSession): void {
    if (!this.sessions.delete(session.id)) return;
    if (this.manager.currentTargetId === session.id) {
      this.manager.disconnect();
      if (this.autoConnect()) this.connectToLatest();
    }
  }

  private connectToLatest(): void {
    const next = this.candidates[0];
    if (next) void this.manager.connect(this.targetFor(next));
  }

  dispose(): void {
    for (const d of this.disposables) d.dispose();
  }
}

function isDart(session: vscode.DebugSession): boolean {
  return session.type === 'dart' || session.type === 'flutter';
}
