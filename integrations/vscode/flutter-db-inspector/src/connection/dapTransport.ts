import * as vscode from 'vscode';

import { Emitter } from './emitter';
import { RpcError, type VmStreamEvent, type VmTransport } from './transport';

/**
 * Fallback transport through the Dart debug adapter (`callService` custom
 * request) for sessions whose VM service URI was not observed, e.g. when the
 * extension activated after the app started. Stream events are limited to
 * what the debug adapter forwards (`dart.serviceExtensionAdded`); the
 * connection manager rescans isolates to cover the rest.
 */
export class DebugAdapterTransport implements VmTransport {
  readonly supportsStreams = false;
  private readonly events = new Emitter<VmStreamEvent>();
  private readonly closes = new Emitter<{ reason: string }>();
  private readonly subscriptions: vscode.Disposable[] = [];
  private closed = false;

  readonly onEvent = this.events.event;
  readonly onClose = this.closes.event;
  readonly description: string;

  constructor(private readonly session: vscode.DebugSession) {
    this.description = `debug session "${session.name}"`;
    this.subscriptions.push(
      vscode.debug.onDidReceiveDebugSessionCustomEvent((e) => {
        if (e.session.id !== session.id || e.event !== 'dart.serviceExtensionAdded') return;
        const body = e.body as { extensionRPC?: string; isolateId?: string };
        if (!body.isolateId) return;
        this.events.fire({
          streamId: 'Isolate',
          event: { kind: 'ServiceExtensionAdded', extensionRPC: body.extensionRPC, isolate: { id: body.isolateId } },
        });
      }),
      vscode.debug.onDidTerminateDebugSession((s) => {
        if (s.id === session.id) this.close('debug session ended');
      }),
    );
  }

  async call(method: string, params: Record<string, unknown> = {}, timeoutMs?: number): Promise<unknown> {
    if (this.closed) throw new RpcError(-32000, 'Debug session ended');
    const request = Promise.resolve(this.session.customRequest('callService', { method, params }));
    try {
      return timeoutMs === undefined ? await request : await withTimeout(request, timeoutMs, method);
    } catch (error) {
      if (error instanceof RpcError) throw error;
      const message = error instanceof Error ? error.message : String(error);
      throw new RpcError(/not registered|method not found/i.test(message) ? -32601 : -32000, message);
    }
  }

  private close(reason: string): void {
    if (this.closed) return;
    this.closed = true;
    this.closes.fire({ reason });
    this.dispose();
  }

  dispose(): void {
    this.closed = true;
    for (const s of this.subscriptions) s.dispose();
    this.events.dispose();
    this.closes.dispose();
  }
}

function withTimeout<T>(promise: Promise<T>, ms: number, method: string): Promise<T> {
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new RpcError(-32001, `No response to ${method} within ${ms} ms`)), ms);
    promise.then(
      (v) => {
        clearTimeout(timer);
        resolve(v);
      },
      (e: unknown) => {
        clearTimeout(timer);
        reject(e);
      },
    );
  });
}
