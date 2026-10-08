import assert from 'node:assert/strict';
import { test } from 'node:test';

import { ConnectionManager, type ConnectionSnapshot } from '../../src/connection/connectionManager';
import { Emitter } from '../../src/connection/emitter';
import { RpcError, type VmStreamEvent, type VmTransport } from '../../src/connection/transport';
import { SERVICE_EXTENSION } from '../../src/protocol/types';

/** Scripted VM: isolates, extension registration and protocol answers. */
class ScriptedVm implements VmTransport {
  readonly description = 'scripted';
  readonly supportsStreams = true;
  readonly events = new Emitter<VmStreamEvent>();
  readonly closes = new Emitter<{ reason: string }>();
  readonly onEvent = this.events.event;
  readonly onClose = this.closes.event;
  isolates: { id: string; extensions: string[] }[] = [];
  protocolVersions = [1];
  /** Answer the next N extension calls with a Sentinel (isolate dying). */
  sentinels = 0;
  calls: string[] = [];

  async call(method: string, params: Record<string, unknown> = {}): Promise<unknown> {
    switch (method) {
      case 'streamListen':
        return {};
      case 'getVM':
        return { isolates: this.isolates.map((i) => ({ id: i.id })) };
      case 'getIsolate':
        return { extensionRPCs: this.isolates.find((i) => i.id === params.isolateId)?.extensions ?? [] };
      case SERVICE_EXTENSION: {
        const isolate = this.isolates.find((i) => i.id === params.isolateId);
        if (!isolate?.extensions.includes(SERVICE_EXTENSION)) throw new RpcError(-32601, 'Method not found');
        const request = JSON.parse(params.request as string) as { requestId: string; method: string };
        this.calls.push(request.method);
        if (this.sentinels > 0 && request.method !== 'inspector.status') {
          this.sentinels--;
          const dying = this.isolates.find((i) => i.id === params.isolateId)!.id;
          setTimeout(() => {
            this.exit(dying);
            this.register(`${dying}-restarted`);
          }, 5);
          return { type: 'Sentinel', kind: 'Collected', valueAsString: '<collected>' };
        }
        if (request.method === 'inspector.status') {
          return {
            version: 1,
            requestId: request.requestId,
            success: true,
            result: { protocolVersion: this.protocolVersions[0], supportedVersions: this.protocolVersions, packageVersion: 't', mode: 'fullAccess', methods: [], limits: {} },
          };
        }
        if (request.method === 'boom') {
          return { version: 1, requestId: request.requestId, success: false, error: { code: 'TABLE_NOT_FOUND', message: 'gone', details: {} } };
        }
        return { version: 1, requestId: request.requestId, success: true, result: { echo: request.method } };
      }
    }
    throw new RpcError(-32601, `unknown ${method}`);
  }

  register(id: string): void {
    this.isolates.push({ id, extensions: [SERVICE_EXTENSION] });
    this.events.fire({ streamId: 'Isolate', event: { kind: 'ServiceExtensionAdded', extensionRPC: SERVICE_EXTENSION, isolate: { id } } });
  }

  exit(id: string): void {
    this.isolates = this.isolates.filter((i) => i.id !== id);
    this.events.fire({ streamId: 'Isolate', event: { kind: 'IsolateExit', isolate: { id } } });
  }

  dispose(): void {}
}

function next(manager: ConnectionManager, state: string): Promise<ConnectionSnapshot> {
  if (manager.snapshot.state === state) return Promise.resolve(manager.snapshot);
  return new Promise((resolve) => {
    const sub = manager.onDidChangeState((s) => {
      if (s.state === state) {
        sub.dispose();
        resolve(s);
      }
    });
  });
}

const target = (vm: ScriptedVm) => ({ id: 'vm', label: 'test', createTransport: async () => vm });

test('waits for the extension, then connects', async () => {
  const vm = new ScriptedVm();
  vm.isolates.push({ id: 'isolates/1', extensions: [] });
  const manager = new ConnectionManager({ rescanIntervalMs: 20 });
  await manager.connect(target(vm));
  assert.equal(manager.snapshot.state, 'connecting');
  let databasesChanged = 0;
  manager.onDidChangeDatabases(() => databasesChanged++);
  vm.register('isolates/2');
  const s = await next(manager, 'connected');
  assert.equal(s.isolateId, 'isolates/2');
  assert.equal(databasesChanged, 1);
  assert.deepEqual(await manager.request('database.list'), { echo: 'database.list' });
  manager.dispose();
});

test('hot restart: reconnecting → connected on the new isolate', async () => {
  const vm = new ScriptedVm();
  vm.register('isolates/1');
  const manager = new ConnectionManager({ rescanIntervalMs: 20 });
  await manager.connect(target(vm));
  await next(manager, 'connected');
  vm.exit('isolates/1');
  assert.equal(manager.snapshot.state, 'reconnecting');
  const pending = manager.request('schema.list');
  vm.register('isolates/2');
  assert.deepEqual(await pending, { echo: 'schema.list' });
  assert.equal(manager.snapshot.isolateId, 'isolates/2');
  manager.dispose();
});

test('databasesChanged events from the active isolate are forwarded', async () => {
  const vm = new ScriptedVm();
  vm.register('isolates/1');
  const manager = new ConnectionManager();
  await manager.connect(target(vm));
  await next(manager, 'connected');
  let fired = 0;
  manager.onDidChangeDatabases(() => fired++);
  vm.events.fire({ streamId: 'Extension', event: { kind: 'Extension', extensionKind: 'flutter_db_inspector.databasesChanged', isolate: { id: 'isolates/1' } } });
  vm.events.fire({ streamId: 'Extension', event: { kind: 'Extension', extensionKind: 'flutter_db_inspector.databasesChanged', isolate: { id: 'other' } } });
  assert.equal(fired, 1);
  manager.dispose();
});

test('protocol errors become InspectorError with the code', async () => {
  const vm = new ScriptedVm();
  vm.register('isolates/1');
  const manager = new ConnectionManager();
  await manager.connect(target(vm));
  await next(manager, 'connected');
  await assert.rejects(manager.request('boom'), { code: 'TABLE_NOT_FOUND', message: 'gone' });
  manager.dispose();
});

test('incompatible protocol versions are reported, not used', async () => {
  const vm = new ScriptedVm();
  vm.protocolVersions = [2];
  vm.register('isolates/1');
  const manager = new ConnectionManager();
  await manager.connect(target(vm));
  const s = await next(manager, 'error');
  assert.match(s.message ?? '', /protocol v2/);
  manager.dispose();
});

test('transport close disconnects; connection failures are errors', async () => {
  const vm = new ScriptedVm();
  vm.register('isolates/1');
  const manager = new ConnectionManager();
  await manager.connect(target(vm));
  await next(manager, 'connected');
  vm.closes.fire({ reason: 'app stopped' });
  assert.equal(manager.snapshot.state, 'disconnected');

  await manager.connect({ id: 'x', label: 'x', createTransport: () => Promise.reject(new Error('refused')) });
  assert.equal(manager.snapshot.state, 'error');
  assert.equal(manager.snapshot.message, 'refused');
  manager.dispose();
});

test('a Sentinel during hot restart: reads retry on the new isolate, writes do not', async () => {
  const vm = new ScriptedVm();
  vm.register('isolates/1');
  const manager = new ConnectionManager({ rescanIntervalMs: 20 });
  await manager.connect(target(vm));
  await next(manager, 'connected');

  vm.sentinels = 1;
  assert.deepEqual(await manager.request('rows.query'), { echo: 'rows.query' });
  assert.equal(manager.snapshot.isolateId, 'isolates/1-restarted');
  assert.deepEqual(vm.calls.filter((m) => m === 'rows.query').length, 2);

  vm.sentinels = 1;
  await assert.rejects(manager.request('row.update'), { code: 'CONNECTION_LOST' });
  assert.equal(vm.calls.filter((m) => m === 'row.update').length, 1);
  manager.dispose();
});
