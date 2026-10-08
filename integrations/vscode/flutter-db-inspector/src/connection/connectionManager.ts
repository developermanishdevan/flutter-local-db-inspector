import {
  ErrorCodes,
  EVENT_DATABASES_CHANGED,
  InspectorError,
  Methods,
  PROTOCOL_VERSION,
  SERVICE_EXTENSION,
  SERVICE_EXTENSION_PARAM,
  SUPPORTED_PROTOCOL_VERSIONS,
  type InspectorResponse,
  type InspectorStatus,
} from '../protocol/types';
import { Emitter } from './emitter';
import { RpcError, type VmStreamEvent, type VmTransport } from './transport';

export type ConnectionState = 'disconnected' | 'connecting' | 'connected' | 'reconnecting' | 'error';

/** Something the manager can connect to (a debug session, a pasted URI, ...). */
export interface ConnectionTarget {
  /** Stable identity, e.g. the debug session id or the URI. */
  readonly id: string;
  readonly label: string;
  createTransport(): Promise<VmTransport>;
}

export interface ConnectionSnapshot {
  state: ConnectionState;
  target?: { id: string; label: string };
  isolateId?: string;
  status?: InspectorStatus;
  /** Human readable explanation for `connecting`, `reconnecting` and `error`. */
  message?: string;
}

export interface ConnectionOptions {
  requestTimeoutMs: number;
  /** How long a request waits for a hot restart to finish before failing. */
  reconnectWaitMs: number;
  /** Isolate rescan interval while waiting for the extension. */
  rescanIntervalMs: number;
  log?: (message: string) => void;
}

const DEFAULT_OPTIONS: ConnectionOptions = {
  requestTimeoutMs: 30_000,
  reconnectWaitMs: 20_000,
  rescanIntervalMs: 2_000,
};

/** VM service errors meaning "the isolate went away" (hot restart, stop). */
const ISOLATE_GONE_CODES = new Set([
  -32000, // service connection disposed
  -32601, // method not found: extension not (yet) registered
  105, // isolate must be runnable
  106, // isolate is reloading
  113, // ext not registered / isolate exited (sentinel)
]);

/** Methods without side effects, retried once if a hot restart interrupts them. */
const READ_METHODS = new Set<string>([
  Methods.inspectorStatus,
  Methods.databaseList,
  Methods.databaseInfo,
  Methods.databaseStats,
  Methods.schemaList,
  Methods.schemaTable,
  Methods.rowsQuery,
  Methods.rowsCount,
  Methods.valueRead,
]);

/**
 * Owns the connection to one running app and keeps it alive across hot
 * restarts:
 *
 * ```
 * connect → find isolate exposing ext.flutter_db_inspector.request → CONNECTED
 * IsolateExit (hot restart) → RECONNECTING → ServiceExtensionAdded → CONNECTED
 * transport closed (app stopped) → DISCONNECTED
 * ```
 *
 * Independent of VS Code APIs so it can be tested against a real Dart VM.
 */
export class ConnectionManager {
  private readonly options: ConnectionOptions;
  private transport?: VmTransport;
  private target?: ConnectionTarget;
  private isolateId?: string;
  private status?: InspectorStatus;
  private state: ConnectionState = 'disconnected';
  private message?: string;
  private generation = 0;
  private rescanTimer?: NodeJS.Timeout;
  private subscriptions: { dispose(): void }[] = [];
  private requestCounter = 0;
  private readonly connectedWaiters = new Set<() => void>();

  private readonly stateEmitter = new Emitter<ConnectionSnapshot>();
  private readonly databasesEmitter = new Emitter<void>();

  /** Fired on every state change. */
  readonly onDidChangeState = this.stateEmitter.event;

  /**
   * Fired when the set of databases may have changed: after (re)connecting
   * and when the app registers or unregisters a database.
   */
  readonly onDidChangeDatabases = this.databasesEmitter.event;

  constructor(options: Partial<ConnectionOptions> = {}) {
    this.options = { ...DEFAULT_OPTIONS, ...options };
  }

  get snapshot(): ConnectionSnapshot {
    return {
      state: this.state,
      target: this.target && { id: this.target.id, label: this.target.label },
      isolateId: this.isolateId,
      status: this.status,
      message: this.message,
    };
  }

  get isConnected(): boolean {
    return this.state === 'connected';
  }

  get currentTargetId(): string | undefined {
    return this.target?.id;
  }

  updateOptions(options: Partial<ConnectionOptions>): void {
    Object.assign(this.options, options);
  }

  private log(message: string): void {
    this.options.log?.(message);
  }

  private setState(state: ConnectionState, message?: string): void {
    const changed = this.state !== state || this.message !== message;
    this.state = state;
    this.message = message;
    if (state === 'connected') {
      for (const resolve of [...this.connectedWaiters]) resolve();
      this.connectedWaiters.clear();
    }
    if (changed) {
      this.log(`state → ${state}${message ? ` (${message})` : ''}`);
      this.stateEmitter.fire(this.snapshot);
    }
  }

  /** Connects to [target], replacing any current connection. */
  async connect(target: ConnectionTarget): Promise<void> {
    this.teardown();
    const generation = ++this.generation;
    this.target = target;
    this.setState('connecting', `Connecting to ${target.label}…`);

    let transport: VmTransport;
    try {
      transport = await target.createTransport();
    } catch (error) {
      if (generation !== this.generation) return;
      this.setState('error', errorMessage(error));
      return;
    }
    if (generation !== this.generation) {
      transport.dispose();
      return;
    }
    this.transport = transport;
    this.log(`connected to ${transport.description}`);
    this.subscriptions.push(
      transport.onEvent((e) => this.onVmEvent(e, generation)),
      transport.onClose(({ reason }) => {
        if (generation !== this.generation) return;
        this.log(`transport closed: ${reason}`);
        this.teardown();
        this.setState('disconnected', 'The app stopped or the VM service closed the connection.');
      }),
    );

    if (transport.supportsStreams) {
      await Promise.all([this.listen('Isolate'), this.listen('Extension')]);
    }
    if (generation !== this.generation) return;
    await this.scanIsolates(generation);
    // Still searching (not connected, and no terminal error from the handshake).
    if (generation === this.generation && !this.isolateId && this.state === 'connecting') {
      this.setState('connecting', 'Waiting for the app to call DbInspector.initialize()…');
      this.startRescan(generation);
    }
  }

  /** Closes the connection. */
  disconnect(): void {
    this.generation++;
    this.teardown();
    this.target = undefined;
    this.setState('disconnected');
  }

  dispose(): void {
    this.disconnect();
    this.stateEmitter.dispose();
    this.databasesEmitter.dispose();
  }

  private teardown(): void {
    this.stopRescan();
    for (const s of this.subscriptions) s.dispose();
    this.subscriptions = [];
    this.transport?.dispose();
    this.transport = undefined;
    this.isolateId = undefined;
    this.status = undefined;
  }

  private async listen(streamId: string): Promise<void> {
    try {
      await this.transport?.call('streamListen', { streamId }, this.options.requestTimeoutMs);
    } catch (error) {
      // 103: already subscribed (e.g. shared DDS connection) — fine.
      if (!(error instanceof RpcError && error.code === 103)) {
        this.log(`streamListen(${streamId}) failed: ${errorMessage(error)}`);
      }
    }
  }

  private startRescan(generation: number): void {
    this.stopRescan();
    this.rescanTimer = setInterval(() => {
      if (generation !== this.generation || this.isolateId) {
        this.stopRescan();
        return;
      }
      void this.scanIsolates(generation);
    }, this.options.rescanIntervalMs);
  }

  private stopRescan(): void {
    if (this.rescanTimer) clearInterval(this.rescanTimer);
    this.rescanTimer = undefined;
  }

  /** Looks for the isolate exposing the inspector extension. */
  private async scanIsolates(generation: number): Promise<void> {
    const transport = this.transport;
    if (!transport) return;
    try {
      const vm = (await transport.call('getVM', {}, this.options.requestTimeoutMs)) as {
        isolates?: { id: string; name?: string }[];
      };
      for (const ref of vm.isolates ?? []) {
        const isolate = (await transport.call(
          'getIsolate',
          { isolateId: ref.id },
          this.options.requestTimeoutMs,
        )) as { extensionRPCs?: string[] };
        if (isolate.extensionRPCs?.includes(SERVICE_EXTENSION)) {
          if (generation === this.generation) await this.adopt(ref.id, generation);
          return;
        }
      }
    } catch (error) {
      this.log(`isolate scan failed: ${errorMessage(error)}`);
    }
  }

  /** Makes [isolateId] the active isolate after a protocol handshake. */
  private async adopt(isolateId: string, generation: number): Promise<void> {
    if (this.isolateId === isolateId && this.state === 'connected') return;
    this.isolateId = isolateId;
    this.stopRescan();
    try {
      const status = (await this.rawRequest(Methods.inspectorStatus, {})) as unknown as InspectorStatus;
      if (generation !== this.generation || this.isolateId !== isolateId) return;
      if (!status.supportedVersions?.some((v) => SUPPORTED_PROTOCOL_VERSIONS.includes(v))) {
        this.isolateId = undefined;
        this.setState(
          'error',
          `The app speaks protocol v${status.protocolVersion}; this extension supports ` +
            `v${SUPPORTED_PROTOCOL_VERSIONS.join(', v')}. Update the extension or the package.`,
        );
        return;
      }
      this.status = status;
      this.setState('connected', `${this.target?.label ?? 'App'} · ${status.mode}`);
      this.databasesEmitter.fire();
    } catch (error) {
      if (generation !== this.generation) return;
      this.isolateId = undefined;
      if (error instanceof InspectorError && error.code === ErrorCodes.inspectorDisabled) {
        this.setState('error', 'The inspector is disabled in this build (release mode or enabled: false).');
        return;
      }
      this.log(`handshake failed: ${errorMessage(error)}`);
      this.setState('reconnecting', 'Waiting for the app…');
      this.startRescan(generation);
    }
  }

  private onVmEvent({ streamId, event }: VmStreamEvent, generation: number): void {
    if (generation !== this.generation) return;
    if (streamId === 'Isolate') {
      if (event.kind === 'ServiceExtensionAdded' && event.extensionRPC === SERVICE_EXTENSION && event.isolate) {
        this.log(`extension registered on ${event.isolate.id}`);
        void this.adopt(event.isolate.id, generation);
      } else if (event.kind === 'IsolateExit' && event.isolate?.id === this.isolateId) {
        // Hot restart (or the isolate died): wait for the extension to return.
        this.isolateId = undefined;
        this.status = undefined;
        this.setState('reconnecting', 'App restarted — reconnecting…');
        this.startRescan(generation);
      }
    } else if (
      streamId === 'Extension' &&
      event.extensionKind === EVENT_DATABASES_CHANGED &&
      event.isolate?.id === this.isolateId
    ) {
      this.databasesEmitter.fire();
    }
  }

  /** Resolves once connected, or rejects after [timeoutMs]. */
  private waitUntilConnected(timeoutMs: number): Promise<void> {
    if (this.state === 'connected') return Promise.resolve();
    return new Promise((resolve, reject) => {
      const done = () => {
        clearTimeout(timer);
        resolve();
      };
      const timer = setTimeout(() => {
        this.connectedWaiters.delete(done);
        reject(new InspectorError(ErrorCodes.connectionLost, 'The app did not come back after restarting.'));
      }, timeoutMs);
      this.connectedWaiters.add(done);
    });
  }

  /**
   * Sends a protocol request and returns its `result`. Throws
   * [InspectorError] for protocol errors and connection problems. Requests
   * made during a hot restart wait for the app to come back.
   */
  async request(method: string, params: Record<string, unknown> = {}): Promise<Record<string, unknown>> {
    if (this.state === 'reconnecting' || (this.state === 'connecting' && this.transport)) {
      await this.waitUntilConnected(this.options.reconnectWaitMs);
    }
    if (this.state !== 'connected') {
      throw new InspectorError(ErrorCodes.notConnected, 'No Flutter app is connected.');
    }
    try {
      return await this.rawRequest(method, params);
    } catch (error) {
      // A read that raced a hot restart is safe to repeat on the new isolate.
      // Writes are never retried, so they can't be applied twice.
      if (!(error instanceof InspectorError && error.code === ErrorCodes.connectionLost && READ_METHODS.has(method))) {
        throw error;
      }
      await this.waitUntilConnected(this.options.reconnectWaitMs);
      return this.rawRequest(method, params);
    }
  }

  /** Marks the current isolate as gone (hot restart) and starts looking for its successor. */
  private isolateGone(isolateId: string): InspectorError {
    if (this.isolateId === isolateId && this.state === 'connected') {
      this.isolateId = undefined;
      this.setState('reconnecting', 'App restarted — reconnecting…');
      this.startRescan(this.generation);
    }
    return new InspectorError(ErrorCodes.connectionLost, 'The app restarted while the request was running. Try again.');
  }

  private async rawRequest(method: string, params: Record<string, unknown>): Promise<Record<string, unknown>> {
    const transport = this.transport;
    const isolateId = this.isolateId;
    if (!transport || !isolateId) {
      throw new InspectorError(ErrorCodes.notConnected, 'No Flutter app is connected.');
    }
    const requestId = `vscode-${++this.requestCounter}`;
    const envelope = { version: PROTOCOL_VERSION, requestId, method, params };
    let raw: unknown;
    try {
      raw = await transport.call(
        SERVICE_EXTENSION,
        { isolateId, [SERVICE_EXTENSION_PARAM]: JSON.stringify(envelope) },
        this.options.requestTimeoutMs,
      );
    } catch (error) {
      if (error instanceof RpcError && error.code === -32001) {
        throw new InspectorError(
          ErrorCodes.clientTimeout,
          `The app did not answer ${method} within ${this.options.requestTimeoutMs} ms.`,
        );
      }
      this.log(`${method} failed: ${error instanceof RpcError ? `${error.code} ${error.message} ${JSON.stringify(error.data)}` : errorMessage(error)}`);
      if (error instanceof RpcError && ISOLATE_GONE_CODES.has(error.code)) throw this.isolateGone(isolateId);
      throw new InspectorError(ErrorCodes.connectionLost, errorMessage(error));
    }
    // The VM answers with a Sentinel when the isolate died mid-request.
    if (typeof raw === 'object' && raw !== null && (raw as { type?: unknown }).type === 'Sentinel') {
      throw this.isolateGone(isolateId);
    }
    const response = parseResponse(raw);
    if (!response.success) {
      throw new InspectorError(response.error.code, response.error.message, response.error.details ?? {});
    }
    return response.result ?? {};
  }
}

function parseResponse(raw: unknown): InspectorResponse {
  let value = raw;
  if (typeof value === 'string') value = JSON.parse(value) as unknown;
  if (typeof value !== 'object' || value === null || !('success' in value)) {
    throw new InspectorError(ErrorCodes.internalError, 'The app returned a malformed response.');
  }
  return value as InspectorResponse;
}

export function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}
