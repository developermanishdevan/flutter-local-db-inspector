import { randomBytes } from 'node:crypto';
import * as os from 'node:os';

import * as vscode from 'vscode';

import type { ConnectionManager } from '../connection/connectionManager';
import { engineLabel, recordNoun } from '../providers/labels';
import { ErrorCodes, InspectorError, type DatabaseDescriptor } from '../protocol/types';
import type { InspectorClient } from '../services/inspectorClient';
import type { QueryStore } from '../services/queryStore';
import type { FullValue, HostMessage, InitMessage, TableTab, WebviewMessage, WebviewRequest } from './messages';

interface PanelContext {
  key: string;
  panel: vscode.WebviewPanel;
  init: InitMessage;
  ready: boolean;
  requests: number;
  errors: string[];
}

/** Diagnostics for one open panel (used by tests and troubleshooting). */
export interface PanelDiagnostics {
  ready: boolean;
  requests: number;
  errors: readonly string[];
}

export interface PanelHooks {
  log(message: string): void;
  /** Called after data changed, so trees can refresh row counts. */
  onDataChanged(databaseId: string): void;
  exportTable(database: DatabaseDescriptor, table: string): Promise<void>;
  settings(): { pageSize: number; confirmCellEdits: boolean };
}

/**
 * Hosts the webview screens (data grid, SQL console, statistics) and executes
 * their requests through the [InspectorClient].
 */
export class PanelManager implements vscode.Disposable {
  private readonly panels = new Map<string, PanelContext>();

  constructor(
    private readonly extensionUri: vscode.Uri,
    private readonly client: InspectorClient,
    private readonly manager: ConnectionManager,
    private readonly queries: QueryStore,
    private readonly hooks: PanelHooks,
  ) {
    manager.onDidChangeState((s) => this.broadcast({ type: 'connection', state: s.state, message: s.message }));
  }

  /** Panel keys: `table:<db>:<table>`, `sql:<db>`, `stats:<db>`. */
  diagnostics(key: string): PanelDiagnostics | undefined {
    const ctx = this.panels.get(key);
    return ctx && { ready: ctx.ready, requests: ctx.requests, errors: ctx.errors };
  }

  openTable(database: DatabaseDescriptor, table: string, entityKind: string, tab: TableTab = 'data'): void {
    const key = `table:${database.id}:${table}`;
    const existing = this.panels.get(key);
    if (existing) {
      existing.panel.reveal();
      this.post(existing, { type: 'showTab', tab });
      return;
    }
    this.create(key, `${table} — ${database.name}`, entityKind === 'table' || entityKind === 'view' ? 'table' : 'symbol-class', {
      type: 'init',
      view: 'table',
      database,
      table,
      entityKind,
      tab,
      pageSize: this.hooks.settings().pageSize,
      limits: this.manager.snapshot.status?.limits,
    });
  }

  /** [suggest]: [sql] only fills an empty editor and is never run. */
  openSql(database: DatabaseDescriptor, sql?: string, run = false, suggest = false): void {
    const key = `sql:${database.id}`;
    const existing = this.panels.get(key);
    if (existing) {
      existing.panel.reveal();
      if (sql !== undefined) this.post(existing, { type: 'setSql', sql, run: run && !suggest, ifEmpty: suggest });
      return;
    }
    this.create(key, `SQL — ${database.name}`, 'terminal', {
      type: 'init',
      view: 'sql',
      database,
      pageSize: this.hooks.settings().pageSize,
      limits: this.manager.snapshot.status?.limits,
      sql,
      runImmediately: run && !suggest,
    });
  }

  openStats(database: DatabaseDescriptor): void {
    const key = `stats:${database.id}`;
    const existing = this.panels.get(key);
    if (existing) {
      existing.panel.reveal();
      this.post(existing, { type: 'refresh' });
      return;
    }
    this.create(key, `Statistics — ${database.name}`, 'graph', {
      type: 'init',
      view: 'stats',
      database,
      pageSize: this.hooks.settings().pageSize,
    });
  }

  /** Asks every open screen to reload (after reconnect or a manual refresh). */
  refreshAll(databases?: readonly DatabaseDescriptor[]): void {
    for (const ctx of this.panels.values()) {
      const updated = databases?.find((d) => d.id === ctx.init.database.id);
      if (updated) ctx.init = { ...ctx.init, database: updated };
      this.post(ctx, { type: 'refresh' });
    }
  }

  private create(key: string, title: string, icon: string, init: InitMessage): void {
    const panel = vscode.window.createWebviewPanel('flutterDbInspector.panel', title, vscode.ViewColumn.Active, {
      enableScripts: true,
      retainContextWhenHidden: true,
      localResourceRoots: [vscode.Uri.joinPath(this.extensionUri, 'dist')],
    });
    panel.iconPath = vscode.Uri.joinPath(this.extensionUri, 'media', `${icon}.svg`);
    panel.webview.html = this.html(panel.webview);
    const ctx: PanelContext = { key, panel, init, ready: false, requests: 0, errors: [] };
    this.panels.set(key, ctx);
    panel.onDidDispose(() => this.panels.delete(key));
    panel.webview.onDidReceiveMessage((message: WebviewMessage) => void this.onMessage(ctx, message));
  }

  private post(ctx: PanelContext, message: HostMessage): void {
    if (ctx.ready) void ctx.panel.webview.postMessage(message);
  }

  private broadcast(message: HostMessage): void {
    for (const ctx of this.panels.values()) this.post(ctx, message);
  }

  private async onMessage(ctx: PanelContext, message: WebviewMessage): Promise<void> {
    if (message.type === 'error') {
      ctx.errors.push(message.message);
      this.hooks.log(`webview ${ctx.key}: ${message.message}`);
      return;
    }
    if (message.type === 'ready') {
      ctx.ready = true;
      void ctx.panel.webview.postMessage(ctx.init);
      const s = this.manager.snapshot;
      this.post(ctx, { type: 'connection', state: s.state, message: s.message });
      return;
    }
    ctx.requests++;
    try {
      const result = await this.handle(ctx, message.request);
      void ctx.panel.webview.postMessage({ type: 'result', id: message.id, ok: true, result } satisfies HostMessage);
    } catch (error) {
      const e =
        error instanceof InspectorError
          ? { code: error.code, message: error.message }
          : { code: ErrorCodes.internalError, message: error instanceof Error ? error.message : String(error) };
      void ctx.panel.webview.postMessage({ type: 'result', id: message.id, ok: false, error: e } satisfies HostMessage);
    }
  }

  private async handle(ctx: PanelContext, request: WebviewRequest): Promise<unknown> {
    const db = ctx.init.database;
    const table = ctx.init.table ?? '';
    const noun = recordNoun(ctx.init.entityKind ?? 'table');
    switch (request.op) {
      case 'rows':
        return this.client.queryRows({ databaseId: db.id, table, ...request.params });
      case 'schema':
        return this.client.tableSchema(db.id, table);
      case 'update': {
        if (this.hooks.settings().confirmCellEdits) {
          const ok = await vscode.window.showWarningMessage(
            `Save changes to this ${noun} in ${table}?`,
            { modal: true, detail: Object.keys(request.values).join(', ') },
            'Save',
          );
          if (ok !== 'Save') return { cancelled: true };
        }
        const result = await this.client.updateRow(db.id, table, request.key, request.values);
        this.hooks.onDataChanged(db.id);
        return result;
      }
      case 'insert': {
        const result = await this.client.insertRow(db.id, table, request.values);
        this.hooks.onDataChanged(db.id);
        return result;
      }
      case 'delete': {
        const ok = await vscode.window.showWarningMessage(
          `Delete this ${noun}?`,
          { modal: true, detail: `${request.label}\n\nThis changes the running app's ${engineLabel(db.type)} data.` },
          'Delete',
        );
        if (ok !== 'Delete') return { cancelled: true };
        const result = await this.client.deleteRow(db.id, table, request.key);
        this.hooks.onDataChanged(db.id);
        return result;
      }
      case 'clear':
        return vscode.commands.executeCommand('flutterDbInspector.clearTable', { database: db, entity: { name: table, kind: ctx.init.entityKind } });
      case 'sql':
        return this.runSql(db, request.sql);
      case 'readValue':
        return this.readValue(db, table, request.key, request.column, request.maxBytes);
      case 'saveValue':
        return this.saveValue(db, table, request.key, request.column);
      case 'copy':
        await vscode.env.clipboard.writeText(request.text);
        vscode.window.setStatusBarMessage(`$(copy) Copied ${request.label ?? 'to clipboard'}`, 2000);
        return {};
      case 'export':
        await this.hooks.exportTable(db, table);
        return {};
      case 'stats':
        return this.client.stats(db.id);
      case 'openSql':
        this.openSql(db, request.sql, false, true);
        return {};
      case 'openTable': {
        const overview = await this.client.schema(db.id);
        const entity = overview.entities.find((e) => e.name === request.table);
        if (entity) this.openTable(db, entity.name, entity.kind);
        return {};
      }
      case 'saveQuery': {
        const name = await vscode.window.showInputBox({
          title: 'Save Query',
          prompt: 'Name for this query',
          value: request.sql.replace(/\s+/g, ' ').trim().slice(0, 40),
        });
        if (!name) return { cancelled: true };
        await this.queries.save(name, request.sql, db.type);
        return {};
      }
      default:
        // App-mode services (call, saveFile, notify) are not offered to VS Code panels.
        throw new InspectorError(ErrorCodes.invalidRequest, `Unsupported request "${request.op}"`);
    }
  }

  /**
   * Runs SQL; statements the app classifies as writes are confirmed with a
   * modal before being re-sent with `allowWrite`.
   */
  async runSql(db: DatabaseDescriptor, sql: string): Promise<unknown> {
    const record = (ok: boolean, extra: { elapsedMs?: number; rowCount?: number } = {}) =>
      this.queries.record({ sql, databaseId: db.id, databaseName: db.name, ok, ...extra });
    try {
      let result;
      try {
        result = await this.client.executeSql(db.id, sql);
      } catch (error) {
        if (!(error instanceof InspectorError && error.requiresConfirmation)) throw error;
        const statement = String(error.details['statement'] ?? 'This statement');
        const choice = await vscode.window.showWarningMessage(
          'This query may modify application data.',
          {
            modal: true,
            detail: `${statement} on "${db.name}":\n\n${sql.length > 500 ? `${sql.slice(0, 500)}…` : sql}`,
          },
          'Execute',
        );
        if (choice !== 'Execute') return { cancelled: true };
        result = await this.client.executeSql(db.id, sql, { allowWrite: true });
        this.hooks.onDataChanged(db.id);
      }
      await record(true, { elapsedMs: result.elapsedMs, rowCount: result.rowCount });
      return result;
    } catch (error) {
      await record(false);
      throw error;
    }
  }

  private async readValue(
    db: DatabaseDescriptor,
    table: string,
    key: Parameters<InspectorClient['readValue']>[1]['key'],
    column: string,
    maxBytes: number,
  ): Promise<FullValue> {
    const full = await this.client.readFullValue(db.id, { table, key, column }, { maxBytes });
    const buffer = Buffer.from(full.bytes);
    return full.isText
      ? { text: buffer.toString('utf8'), isText: true, totalBytes: full.totalBytes, complete: full.complete }
      : { base64: buffer.toString('base64'), isText: false, totalBytes: full.totalBytes, complete: full.complete };
  }

  private async saveValue(
    db: DatabaseDescriptor,
    table: string,
    key: Parameters<InspectorClient['readValue']>[1]['key'],
    column: string,
  ): Promise<unknown> {
    const target = await vscode.window.showSaveDialog({
      title: `Save ${table}.${column}`,
      defaultUri: vscode.Uri.joinPath(vscode.workspace.workspaceFolders?.[0]?.uri ?? vscode.Uri.file(os.homedir()), `${table}_${column}.bin`),
    });
    if (!target) return { cancelled: true };
    await vscode.window.withProgress(
      { location: vscode.ProgressLocation.Notification, title: `Saving ${column}`, cancellable: true },
      async (progress, token) => {
        let last = 0;
        const full = await this.client.readFullValue(
          db.id,
          { table, key, column },
          {
            isCancelled: () => token.isCancellationRequested,
            onProgress: (read, total) => {
              const pct = total ? (read / total) * 100 : 0;
              progress.report({ increment: pct - last, message: `${Math.round(pct)}%` });
              last = pct;
            },
          },
        );
        if (token.isCancellationRequested) return;
        await vscode.workspace.fs.writeFile(target, full.bytes);
      },
    );
    return {};
  }

  private html(webview: vscode.Webview): string {
    const asset = (name: string) => webview.asWebviewUri(vscode.Uri.joinPath(this.extensionUri, 'dist', name));
    const nonce = randomBytes(16).toString('base64');
    return `<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src ${webview.cspSource}; font-src ${webview.cspSource}; img-src ${webview.cspSource} data:; script-src 'nonce-${nonce}';">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<link rel="stylesheet" href="${asset('codicons/codicon.css')}">
<link rel="stylesheet" href="${asset('webview.css')}">
<title>Flutter DB Inspector</title>
</head>
<body>
<div id="app" role="application" aria-label="Flutter DB Inspector"></div>
<script nonce="${nonce}" src="${asset('webview.js')}"></script>
</body>
</html>`;
  }

  dispose(): void {
    for (const ctx of this.panels.values()) ctx.panel.dispose();
    this.panels.clear();
  }
}
