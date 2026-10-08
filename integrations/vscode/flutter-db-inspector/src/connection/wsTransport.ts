import WebSocket from 'ws';

import { Emitter } from './emitter';
import { RpcError, type VmStreamEvent, type VmTransport } from './transport';

/**
 * Normalizes anything a user may paste — an `http://…/token=/` URI, a
 * `ws://…/ws` URI or a DevTools link containing `?uri=` — into the VM
 * service WebSocket URI.
 */
export function toWebSocketUri(input: string): string {
  let text = input.trim();
  const embedded = /[?&]uri=([^&\s]+)/.exec(text);
  if (embedded) text = decodeURIComponent(embedded[1]);
  const found = /(?:https?|wss?):\/\/[^\s"'<>]+/.exec(text);
  if (!found) throw new Error(`"${input}" does not contain a VM service URI`);
  const url = new URL(found[0]);
  if (url.protocol === 'http:') url.protocol = 'ws:';
  if (url.protocol === 'https:') url.protocol = 'wss:';
  url.hash = '';
  url.search = '';
  let path = url.pathname;
  if (!path.endsWith('/ws')) path = `${path.endsWith('/') ? path : `${path}/`}ws`;
  url.pathname = path;
  return url.toString();
}

interface Pending {
  resolve(value: unknown): void;
  reject(error: Error): void;
  timer?: NodeJS.Timeout;
}

/** VM service JSON-RPC over WebSocket. */
export class WebSocketTransport implements VmTransport {
  readonly supportsStreams = true;
  private readonly pending = new Map<string, Pending>();
  private readonly events = new Emitter<VmStreamEvent>();
  private readonly closes = new Emitter<{ reason: string }>();
  private nextId = 1;
  private closed = false;

  readonly onEvent = this.events.event;
  readonly onClose = this.closes.event;

  private constructor(
    private readonly socket: WebSocket,
    readonly description: string,
  ) {
    socket.on('message', (data) => this.onMessage(data.toString()));
    socket.on('close', (_code, reason) => this.handleClose(reason.toString() || 'connection closed'));
    socket.on('error', (error) => this.handleClose(error.message));
  }

  static connect(uri: string, timeoutMs = 10_000): Promise<WebSocketTransport> {
    const wsUri = toWebSocketUri(uri);
    return new Promise((resolve, reject) => {
      const socket = new WebSocket(wsUri, { maxPayload: 256 * 1024 * 1024 });
      const timer = setTimeout(() => {
        socket.terminate();
        reject(new Error(`Timed out connecting to ${wsUri}`));
      }, timeoutMs);
      socket.once('open', () => {
        clearTimeout(timer);
        resolve(new WebSocketTransport(socket, wsUri));
      });
      socket.once('error', (error) => {
        clearTimeout(timer);
        reject(new Error(`Could not connect to ${wsUri}: ${error.message}`));
      });
    });
  }

  call(method: string, params: Record<string, unknown> = {}, timeoutMs?: number): Promise<unknown> {
    if (this.closed) return Promise.reject(new RpcError(-32000, 'Service connection closed'));
    const id = String(this.nextId++);
    return new Promise((resolve, reject) => {
      const entry: Pending = { resolve, reject };
      if (timeoutMs !== undefined) {
        entry.timer = setTimeout(() => {
          this.pending.delete(id);
          reject(new RpcError(-32001, `No response to ${method} within ${timeoutMs} ms`));
        }, timeoutMs);
      }
      this.pending.set(id, entry);
      this.socket.send(JSON.stringify({ jsonrpc: '2.0', id, method, params }), (error) => {
        if (error) {
          this.settle(id);
          reject(new RpcError(-32000, error.message));
        }
      });
    });
  }

  private settle(id: string): Pending | undefined {
    const entry = this.pending.get(id);
    if (entry) {
      this.pending.delete(id);
      if (entry.timer) clearTimeout(entry.timer);
    }
    return entry;
  }

  private onMessage(text: string): void {
    let message: {
      id?: string | number;
      result?: unknown;
      error?: { code: number; message: string; data?: unknown };
      method?: string;
      params?: VmStreamEvent;
    };
    try {
      message = JSON.parse(text) as typeof message;
    } catch {
      return;
    }
    if (message.method === 'streamNotify' && message.params) {
      this.events.fire(message.params);
      return;
    }
    if (message.id === undefined) return;
    const entry = this.settle(String(message.id));
    if (!entry) return;
    if (message.error) {
      entry.reject(new RpcError(message.error.code, message.error.message, message.error.data));
    } else {
      entry.resolve(message.result);
    }
  }

  private handleClose(reason: string): void {
    if (this.closed) return;
    this.closed = true;
    for (const [id, entry] of [...this.pending]) {
      this.settle(id);
      entry.reject(new RpcError(-32000, `Service connection closed (${reason})`));
    }
    this.closes.fire({ reason });
    this.events.dispose();
    this.closes.dispose();
  }

  dispose(): void {
    if (this.closed) return;
    this.socket.close();
    this.handleClose('disposed');
  }
}
