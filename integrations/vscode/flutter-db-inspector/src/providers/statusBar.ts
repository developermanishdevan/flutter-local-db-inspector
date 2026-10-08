import * as vscode from 'vscode';

import type { ConnectionSnapshot } from '../connection/connectionManager';

/** Connection indicator in the status bar. */
export class ConnectionStatusBar implements vscode.Disposable {
  private readonly item = vscode.window.createStatusBarItem('flutterDbInspector.status', vscode.StatusBarAlignment.Left, 50);

  constructor() {
    this.item.name = 'Flutter DB Inspector';
    this.update({ state: 'disconnected' }, 0);
  }

  update(snapshot: ConnectionSnapshot, databaseCount: number): void {
    const item = this.item;
    item.backgroundColor = undefined;
    switch (snapshot.state) {
      case 'connected':
        item.text = `$(database) Flutter DB: ${databaseCount} ${databaseCount === 1 ? 'database' : 'databases'}`;
        item.tooltip = `Connected to ${snapshot.target?.label ?? 'app'}${
          snapshot.status ? ` (${snapshot.status.mode}, runtime ${snapshot.status.packageVersion})` : ''
        }`;
        item.command = 'flutterDbInspector.openInspector';
        item.show();
        break;
      case 'connecting':
      case 'reconnecting':
        item.text = `$(sync~spin) Flutter DB: ${snapshot.state === 'connecting' ? 'Connecting' : 'Reconnecting'}`;
        item.tooltip = snapshot.message;
        item.command = 'flutterDbInspector.openInspector';
        item.show();
        break;
      case 'error':
        item.text = '$(error) Flutter DB';
        item.tooltip = snapshot.message;
        item.backgroundColor = new vscode.ThemeColor('statusBarItem.errorBackground');
        item.command = 'flutterDbInspector.connect';
        item.show();
        break;
      default:
        item.hide();
    }
  }

  dispose(): void {
    this.item.dispose();
  }
}
