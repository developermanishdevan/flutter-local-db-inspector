import type { Disposable, Event } from './emitter';

/** A VM service event as delivered on `streamNotify`. */
export interface VmEvent {
  kind: string;
  isolate?: { id: string; name?: string };
  extensionRPC?: string;
  extensionKind?: string;
  extensionData?: Record<string, unknown>;
  [key: string]: unknown;
}

export interface VmStreamEvent {
  streamId: string;
  event: VmEvent;
}

/** Error returned by a VM service JSON-RPC call. */
export class RpcError extends Error {
  constructor(
    readonly code: number,
    message: string,
    readonly data?: unknown,
  ) {
    super(message);
    this.name = 'RpcError';
  }
}

/** JSON-RPC access to a Dart VM service (WebSocket or debug adapter). */
export interface VmTransport extends Disposable {
  /** Human readable description, e.g. the VM service URI. */
  readonly description: string;

  /** Whether `streamListen` and stream events are available. */
  readonly supportsStreams: boolean;

  call(method: string, params?: Record<string, unknown>, timeoutMs?: number): Promise<unknown>;

  readonly onEvent: Event<VmStreamEvent>;

  /** Fired once when the transport closes for any reason. */
  readonly onClose: Event<{ reason: string }>;
}
