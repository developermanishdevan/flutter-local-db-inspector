import type { HostMessage, WebviewMessage, WebviewRequest } from '@messages';
import { detectTransport, isHostMessage } from './transport';

const transport = detectTransport();

/** Error returned by the host (or by the app, in app mode). */
export class HostError extends Error {
  constructor(
    readonly code: string,
    message: string,
    readonly details: Record<string, unknown> = {},
  ) {
    super(message);
  }
}

/**
 * What a view needs from its surroundings. In panel mode (VS Code) this is the
 * host itself; in app mode each tab gets one scoped to its database / table.
 */
export interface ViewHost {
  request<T>(req: WebviewRequest): Promise<T>;
  loadState<T extends object>(fallback: T): T;
  saveState(state: object): void;
}

let nextId = 1;
const pending = new Map<number, { resolve(v: unknown): void; reject(e: Error): void }>();
const listeners = new Set<(m: HostMessage) => void>();

window.addEventListener('message', (event: MessageEvent<unknown>) => {
  if (!transport.accepts(event) || !isHostMessage(event.data)) return;
  const message = event.data;
  if (message.type === 'result') {
    const entry = pending.get(message.id);
    if (!entry) return;
    pending.delete(message.id);
    if (message.ok) entry.resolve(message.result);
    else entry.reject(new HostError(message.error.code, message.error.message, message.error.details));
    return;
  }
  for (const l of listeners) l(message);
});

/** Sends a request to the host. */
export function request<T>(req: WebviewRequest): Promise<T> {
  const id = nextId++;
  return new Promise<T>((resolve, reject) => {
    pending.set(id, { resolve: resolve as (v: unknown) => void, reject });
    transport.post({ type: 'request', id, request: req });
  });
}

export function onHostMessage(listener: (m: HostMessage) => void): void {
  listeners.add(listener);
}

/** Reports an unexpected error to the host's log. */
export function reportError(message: string): void {
  transport.post({ type: 'error', message });
}

export function ready(): void {
  transport.post({ type: 'ready' });
}

/** Per-view UI state kept by the host (column widths, tab, ...). */
export function loadState<T extends object>(fallback: T): T {
  const s = transport.getState();
  return s && typeof s === 'object' ? { ...fallback, ...(s as Partial<T>) } : fallback;
}

export function saveState(state: object): void {
  transport.setState(state);
}

export function isCancelled(result: unknown): boolean {
  return typeof result === 'object' && result !== null && (result as { cancelled?: boolean }).cancelled === true;
}

/** The host itself, for panel mode (one view per page). */
export const panelHost: ViewHost = { request, loadState, saveState };

/** Posts a raw message to the host (app mode uses this for fire-and-forget). */
export function post(message: WebviewMessage): void {
  transport.post(message);
}

/** Per-page state store for app mode, keyed by view (one entry per tab). */
export function scopedState(scope: string): Pick<ViewHost, 'loadState' | 'saveState'> {
  return {
    loadState<T extends object>(fallback: T): T {
      const all = transport.getState();
      const s = all && typeof all === 'object' ? (all as Record<string, unknown>)[scope] : undefined;
      return s && typeof s === 'object' ? { ...fallback, ...(s as Partial<T>) } : fallback;
    },
    saveState(state: object): void {
      const all = transport.getState();
      transport.setState({ ...(all && typeof all === 'object' ? all : {}), [scope]: state });
    },
  };
}
