import { createWriteStream } from 'node:fs';
import * as path from 'node:path';
import * as vscode from 'vscode';

import type { ConnectionManager } from '../connection/connectionManager';
import type { DebugSessionWatcher } from '../connection/sessionWatcher';
import { toWebSocketUri, WebSocketTransport } from '../connection/wsTransport';
import type { PanelManager } from '../panels/panelManager';
import { DatabaseNode, EntityNode, type DatabaseTreeProvider, type TreeNode } from '../providers/databaseTree';
import { engineLabel, entityIcon, recordNoun } from '../providers/labels';
import type { QueryNode } from '../providers/queriesTree';
import type { DatabaseDescriptor, EntitySummary } from '../protocol/types';
import { formatCount } from '../protocol/values';
import { exportEntity, type ExportFormat, type ExportSummary } from '../services/exporter';
import type { InspectorClient } from '../services/inspectorClient';
import type { QueryStore } from '../services/queryStore';

export interface CommandDeps {
  client: InspectorClient;
  manager: ConnectionManager;
  watcher: DebugSessionWatcher;
  tree: DatabaseTreeProvider;
  panels: PanelManager;
  queries: QueryStore;
  refresh(): Promise<void>;
  log(message: string): void;
}

/** Entity reference passed by tree items and webviews. */
type EntityArg = EntityNode | { database: DatabaseDescriptor; entity: Pick<EntitySummary, 'name' | 'kind'> };

export function registerCommands(context: vscode.ExtensionContext, deps: CommandDeps): void {
  const { client, manager, watcher, tree, panels, queries } = deps;

  const register = (id: string, fn: (...args: never[]) => unknown) =>
    context.subscriptions.push(
      vscode.commands.registerCommand(id, async (...args: never[]) => {
        try {
          return await fn(...args);
        } catch (error) {
          const message = error instanceof Error ? error.message : String(error);
          deps.log(`${id} failed: ${message}`);
          void vscode.window.showErrorMessage(`Flutter DB: ${message}`);
        }
      }),
    );

  async function pickDatabase(predicate: (d: DatabaseDescriptor) => boolean = () => true): Promise<DatabaseDescriptor | undefined> {
    if (!manager.isConnected) {
      void vscode.window.showWarningMessage('Flutter DB: no app is connected.');
      return undefined;
    }
    if (tree.current.length === 0) await tree.refresh();
    const candidates = tree.current.filter(predicate);
    if (candidates.length === 0) {
      void vscode.window.showWarningMessage('Flutter DB: no matching database is registered.');
      return undefined;
    }
    if (candidates.length === 1) return candidates[0];
    const picked = await vscode.window.showQuickPick(
      candidates.map((d) => ({ label: d.name, description: engineLabel(d.type), database: d })),
      { title: 'Select database' },
    );
    return picked?.database;
  }

  async function databaseFrom(arg: unknown, predicate?: (d: DatabaseDescriptor) => boolean) {
    if (arg instanceof DatabaseNode) return arg.database;
    if (arg && typeof arg === 'object' && 'database' in arg) return (arg as { database: DatabaseDescriptor }).database;
    return pickDatabase(predicate);
  }

  async function entityFrom(arg: unknown): Promise<{ database: DatabaseDescriptor; entity: Pick<EntitySummary, 'name' | 'kind'> } | undefined> {
    if (arg && typeof arg === 'object' && 'entity' in arg && 'database' in arg) return arg as EntityArg;
    const database = await pickDatabase();
    if (!database) return undefined;
    const overview = await tree.overview(database);
    const picked = await vscode.window.showQuickPick(
      overview.entities.map((e) => ({ label: e.name, description: e.kind, entity: e })),
      { title: `Select from ${database.name}` },
    );
    return picked && { database, entity: picked.entity };
  }

  register('flutterDbInspector.openInspector', async () => {
    await vscode.commands.executeCommand('flutterDbInspector.databases.focus');
    if (manager.snapshot.state === 'disconnected' || manager.snapshot.state === 'error') {
      const latest = watcher.candidates[0];
      if (latest) await manager.connect(watcher.targetFor(latest));
    }
  });

  register('flutterDbInspector.refresh', () => deps.refresh());

  register('flutterDbInspector.connect', async (uriArg?: string) => {
    // Programmatic use (links, tasks, tests): connect straight to a URI.
    if (typeof uriArg === 'string') {
      const uri = toWebSocketUri(uriArg);
      await manager.connect({ id: uri, label: new URL(uri).host, createTransport: () => WebSocketTransport.connect(uri) });
      return;
    }
    type Item = vscode.QuickPickItem & { run(): Promise<void> };
    const items: Item[] = watcher.candidates.map((c) => ({
      label: `$(debug-alt) ${c.session.name}`,
      description: c.vmServiceUri ?? 'via debug adapter',
      run: () => manager.connect(watcher.targetFor(c)),
    }));
    items.push({
      label: '$(link) Enter VM Service URI…',
      description: 'From `flutter run`, `dart run --enable-vm-service` or a DevTools link',
      run: async () => {
        const input = await vscode.window.showInputBox({
          title: 'Connect to VM Service',
          prompt: 'Paste the VM service URI (http://127.0.0.1:PORT/TOKEN=/ or ws://…/ws)',
          placeHolder: 'http://127.0.0.1:50300/abcdefg=/',
          ignoreFocusOut: true,
          validateInput: (value) => {
            try {
              toWebSocketUri(value);
              return undefined;
            } catch (error) {
              return error instanceof Error ? error.message : String(error);
            }
          },
        });
        if (!input) return;
        const uri = toWebSocketUri(input);
        await manager.connect({ id: uri, label: new URL(uri).host, createTransport: () => WebSocketTransport.connect(uri) });
      },
    });
    const picked =
      items.length === 1 ? items[0] : await vscode.window.showQuickPick(items, { title: 'Connect Flutter DB Inspector' });
    await picked?.run();
  });

  register('flutterDbInspector.disconnect', () => manager.disconnect());

  register('flutterDbInspector.filterTables', () => {
    // Live filter: the tree narrows as the user types.
    const input = vscode.window.createInputBox();
    input.title = 'Filter tables, collections and boxes';
    input.placeholder = 'Part of a name, e.g. "order"';
    input.value = tree.filter;
    const before = tree.filter;
    let accepted = false;
    input.onDidChangeValue((value) => tree.setFilter(value));
    input.onDidAccept(() => {
      accepted = true;
      input.hide();
    });
    input.onDidHide(() => {
      if (!accepted) tree.setFilter(before); // Escape restores the previous filter
      input.dispose();
    });
    input.show();
  });

  register('flutterDbInspector.clearFilter', () => tree.setFilter(''));

  register('flutterDbInspector.goToTable', async () => {
    if (!manager.isConnected) {
      void vscode.window.showWarningMessage('Flutter DB: no app is connected.');
      return;
    }
    if (tree.current.length === 0) await tree.refresh();
    type Item = vscode.QuickPickItem & { database: DatabaseDescriptor; entity: EntitySummary };
    const picker = vscode.window.createQuickPick<Item>();
    picker.title = 'Go to Table';
    picker.placeholder = 'Type a table, collection or box name';
    picker.matchOnDescription = true;
    picker.busy = true;
    picker.show();
    const items: Item[] = [];
    for (const database of tree.current) {
      try {
        const overview = await tree.overview(database);
        for (const entity of overview.entities) {
          items.push({
            label: `$(${entityIcon(entity.kind)}) ${entity.name}`,
            description: `${database.name} · ${engineLabel(database.type)} ${entity.kind}`,
            detail: entity.rowCount === undefined ? undefined : `${formatCount(entity.rowCount)} ${recordNoun(entity.kind, true)}`,
            database,
            entity,
          });
        }
      } catch {
        // A database that fails to list is simply left out.
      }
    }
    picker.items = items;
    picker.busy = false;
    const picked = await new Promise<Item | undefined>((resolve) => {
      picker.onDidAccept(() => resolve(picker.selectedItems[0]));
      picker.onDidHide(() => resolve(undefined));
    });
    picker.dispose();
    if (picked) panels.openTable(picked.database, picked.entity.name, picked.entity.kind, 'data');
  });

  register('flutterDbInspector.openTable', async (arg?: EntityArg) => {
    const target = await entityFrom(arg);
    if (target) panels.openTable(target.database, target.entity.name, target.entity.kind, 'data');
  });

  register('flutterDbInspector.openSchema', async (arg?: EntityArg) => {
    const target = await entityFrom(arg);
    if (target) panels.openTable(target.database, target.entity.name, target.entity.kind, 'schema');
  });

  const hasSql = (d: DatabaseDescriptor) => d.capabilities.includes('sql');

  register('flutterDbInspector.openSqlConsole', async (arg?: TreeNode) => {
    const db = await databaseFrom(arg, hasSql);
    if (!db) return;
    if (!hasSql(db)) {
      void vscode.window.showInformationMessage(`${engineLabel(db.type)} databases have no query console.`);
      return;
    }
    panels.openSql(db);
  });

  register('flutterDbInspector.runQuery', async () => {
    const editor = vscode.window.activeTextEditor;
    const db = await pickDatabase(hasSql);
    if (!db) return;
    if (editor && editor.document.languageId === 'sql') {
      const sql = editor.selection.isEmpty ? editor.document.getText() : editor.document.getText(editor.selection);
      panels.openSql(db, sql.trim(), true);
    } else {
      panels.openSql(db);
    }
  });

  register('flutterDbInspector.showStatistics', async (arg?: TreeNode) => {
    const db = await databaseFrom(arg);
    if (db) panels.openStats(db);
  });

  register('flutterDbInspector.copyName', async (arg?: TreeNode) => {
    const name =
      arg?.kind === 'entity'
        ? arg.entity.name
        : arg?.kind === 'index'
          ? arg.index.name
          : arg?.kind === 'trigger'
            ? arg.trigger.name
            : undefined;
    if (name) await vscode.env.clipboard.writeText(name);
  });

  register('flutterDbInspector.clearTable', async (arg?: EntityArg) => {
    const target = await entityFrom(arg);
    if (!target) return { cancelled: true };
    const { database, entity } = target;
    const count = await client.countRows({ databaseId: database.id, table: entity.name }).catch(() => undefined);
    const noun = recordNoun(entity.kind, true);
    const choice = await vscode.window.showWarningMessage(
      `Delete all ${count === undefined ? '' : `${formatCount(count)} `}${noun} from "${entity.name}"?`,
      { modal: true, detail: `This permanently changes the running app's ${engineLabel(database.type)} data.` },
      'Clear',
    );
    if (choice !== 'Clear') return { cancelled: true };
    const result = await client.clearTable(database.id, entity.name);
    void vscode.window.showInformationMessage(`Deleted ${formatCount(result.affectedRows)} ${noun} from ${entity.name}.`);
    tree.invalidate(database.id);
    panels.refreshAll();
    return result;
  });

  function formatsFor(db: DatabaseDescriptor): { label: string; format: ExportFormat }[] {
    const formats: { label: string; format: ExportFormat }[] = [
      { label: 'JSON', format: 'json' },
      { label: 'CSV', format: 'csv' },
    ];
    if (db.dataModel === 'relational') formats.push({ label: 'SQL (INSERT statements)', format: 'sql' });
    return formats;
  }

  async function exportTo(
    db: DatabaseDescriptor,
    table: string,
    format: ExportFormat,
    file: string,
    token: vscode.CancellationToken,
    progress: (rows: number, total?: number) => void,
    append = false,
  ): Promise<ExportSummary> {
    const stream = createWriteStream(file, { flags: append ? 'a' : 'w' });
    const write = (chunk: string) =>
      new Promise<void>((resolve, reject) => stream.write(chunk, (e) => (e ? reject(e) : resolve())));
    try {
      return await exportEntity(client, {
        databaseId: db.id,
        table,
        format,
        write,
        isCancelled: () => token.isCancellationRequested,
        onProgress: (p) => progress(p.rows, p.total),
      });
    } finally {
      await new Promise<void>((resolve) => stream.end(resolve));
    }
  }

  function reportExport(what: string, summaries: ExportSummary[]): void {
    const rows = summaries.reduce((n, s) => n + s.rows, 0);
    const masked = [...new Set(summaries.flatMap((s) => s.maskedColumns))];
    const notes = [
      masked.length ? `masked columns exported as null: ${masked.join(', ')}` : '',
      summaries.some((s) => s.cancelled) ? 'cancelled — the file is incomplete' : '',
    ].filter(Boolean);
    void vscode.window.showInformationMessage(
      `Exported ${formatCount(rows)} records from ${what}.${notes.length ? ` (${notes.join('; ')})` : ''}`,
    );
  }

  register('flutterDbInspector.exportTable', async (arg?: EntityArg) => {
    const target = await entityFrom(arg);
    if (!target) return;
    const { database, entity } = target;
    const picked = await vscode.window.showQuickPick(formatsFor(database), { title: `Export ${entity.name}` });
    if (!picked) return;
    const uri = await vscode.window.showSaveDialog({
      title: `Export ${entity.name}`,
      defaultUri: vscode.Uri.file(path.join(defaultFolder(), `${entity.name}.${picked.format}`)),
      filters: { [picked.label]: [picked.format] },
    });
    if (!uri) return;
    const summary = await vscode.window.withProgress(
      { location: vscode.ProgressLocation.Notification, title: `Exporting ${entity.name}`, cancellable: true },
      (progress, token) =>
        exportTo(database, entity.name, picked.format, uri.fsPath, token, (rows, total) =>
          progress.report({ message: `${formatCount(rows)}${total ? ` / ${formatCount(total)}` : ''}` }),
        ),
    );
    reportExport(entity.name, [summary]);
  });

  register('flutterDbInspector.exportDatabase', async (arg?: TreeNode) => {
    const database = await databaseFrom(arg, (d) => d.capabilities.includes('export'));
    if (!database) return;
    const picked = await vscode.window.showQuickPick(formatsFor(database), { title: `Export ${database.name}` });
    if (!picked) return;
    const overview = await client.schema(database.id);
    const entities = overview.entities.filter((e) => picked.format !== 'sql' || e.kind === 'table');
    const summaries: ExportSummary[] = [];

    if (picked.format === 'sql') {
      const uri = await vscode.window.showSaveDialog({
        defaultUri: vscode.Uri.file(path.join(defaultFolder(), `${database.id}.sql`)),
        filters: { SQL: ['sql'] },
      });
      if (!uri) return;
      await vscode.window.withProgress(
        { location: vscode.ProgressLocation.Notification, title: `Exporting ${database.name}`, cancellable: true },
        async (progress, token) => {
          await vscode.workspace.fs.writeFile(uri, Buffer.from(`-- ${database.name} exported by Flutter DB Inspector\nBEGIN TRANSACTION;\n\n`));
          for (const e of entities) {
            if (token.isCancellationRequested) break;
            summaries.push(
              await exportTo(database, e.name, 'sql', uri.fsPath, token, (rows) =>
                progress.report({ message: `${e.name}: ${formatCount(rows)}` }), true),
            );
          }
          await new Promise<void>((resolve, reject) =>
            createWriteStream(uri.fsPath, { flags: 'a' }).end('\nCOMMIT;\n', () => resolve()).on('error', reject),
          );
        },
      );
    } else {
      const folders = await vscode.window.showOpenDialog({
        title: `Export ${database.name} — choose a folder`,
        canSelectFiles: false,
        canSelectFolders: true,
        defaultUri: vscode.Uri.file(defaultFolder()),
      });
      if (!folders?.[0]) return;
      const dir = vscode.Uri.joinPath(folders[0], database.id);
      await vscode.workspace.fs.createDirectory(dir);
      await vscode.window.withProgress(
        { location: vscode.ProgressLocation.Notification, title: `Exporting ${database.name}`, cancellable: true },
        async (progress, token) => {
          for (const e of entities) {
            if (token.isCancellationRequested) break;
            const file = vscode.Uri.joinPath(dir, `${e.name}.${picked.format}`).fsPath;
            summaries.push(
              await exportTo(database, e.name, picked.format, file, token, (rows) =>
                progress.report({ message: `${e.name}: ${formatCount(rows)}` })),
            );
          }
        },
      );
    }
    reportExport(database.name, summaries);
  });

  // Queries view -------------------------------------------------------------

  const sqlOf = (node: QueryNode) =>
    node.kind === 'saved' ? node.query.sql : node.kind === 'history' ? node.entry.sql : undefined;

  async function openQuery(node: QueryNode, run: boolean): Promise<void> {
    const sql = sqlOf(node);
    if (sql === undefined) return;
    const preferred = node.kind === 'history' ? tree.current.find((d) => d.id === node.entry.databaseId) : undefined;
    const db = preferred ?? (await pickDatabase(hasSql));
    if (db) panels.openSql(db, sql, run);
  }

  register('flutterDbInspector.query.open', (node: QueryNode) => openQuery(node, false));
  register('flutterDbInspector.query.run', (node: QueryNode) => openQuery(node, true));
  register('flutterDbInspector.query.copy', async (node: QueryNode) => {
    const sql = sqlOf(node);
    if (sql !== undefined) await vscode.env.clipboard.writeText(sql);
  });
  register('flutterDbInspector.query.save', async (node: QueryNode) => {
    const sql = sqlOf(node);
    if (sql === undefined) return;
    const name = await vscode.window.showInputBox({ title: 'Save Query', prompt: 'Name', value: sql.replace(/\s+/g, ' ').slice(0, 40) });
    if (name) await queries.save(name, sql);
  });
  register('flutterDbInspector.query.delete', async (node: QueryNode) => {
    if (node.kind === 'saved') await queries.deleteSaved(node.query.id);
    if (node.kind === 'history') await queries.deleteHistory(node.entry.id);
  });
  register('flutterDbInspector.query.clearHistory', async () => {
    const ok = await vscode.window.showWarningMessage('Clear query history?', { modal: true }, 'Clear');
    if (ok === 'Clear') await queries.clearHistory();
  });
}

function defaultFolder(): string {
  return vscode.workspace.workspaceFolders?.[0]?.uri.fsPath ?? require('node:os').homedir();
}
