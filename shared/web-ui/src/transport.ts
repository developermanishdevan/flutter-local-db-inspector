import type { HostMessage, WebviewMessage } from '@messages';

/**
 * How the UI talks to the program hosting it. Every host delivers its
 * messages as `window` "message" events; only sending and per-view state
 * differ between hosts.
 *
 * - VS Code webview: `acquireVsCodeApi()`.
 * - Android Studio (JCEF): the plugin injects `window.fdiHost.postMessage(json)`
 *   (before or after the page loads; see pendingJcefTransport) and answers with
 *   `window.postMessage(message, '*')`.
 * - DevTools (iframe): messages go to `window.parent`; only messages from the
 *   parent frame are accepted.
 */
export interface Transport {
  readonly kind: 'vscode' | 'jcef' | 'iframe';
  post(message: WebviewMessage): void;
  /** Returns false for messages that did not come from the host. */
  accepts(event: MessageEvent): boolean;
  getState(): unknown;
  setState(state: unknown): void;
}

interface VsCodeApi {
  postMessage(message: WebviewMessage): void;
  getState(): unknown;
  setState(state: unknown): void;
}

interface JcefHost {
  postMessage(json: string): void;
}

declare global {
  interface Window {
    acquireVsCodeApi?: () => VsCodeApi;
    fdiHost?: JcefHost;
  }
}

function vscodeTransport(api: VsCodeApi): Transport {
  return {
    kind: 'vscode',
    post: (message) => api.postMessage(message),
    accepts: () => true,
    getState: () => api.getState(),
    setState: (state) => api.setState(state),
  };
}

/** Per-view state for hosts without their own store; lost if storage is blocked. */
function storageState(): Pick<Transport, 'getState' | 'setState'> {
  const key = `flutter_db_inspector.view.${document.documentElement.dataset.stateKey ?? 'default'}`;
  let memory: unknown;
  return {
    getState() {
      try {
        const raw = window.localStorage.getItem(key);
        if (raw !== null) return JSON.parse(raw) as unknown;
      } catch {
        // Storage blocked or corrupt: fall back to memory.
      }
      return memory;
    },
    setState(state) {
      memory = state;
      try {
        window.localStorage.setItem(key, JSON.stringify(state));
      } catch {
        // Storage blocked: memory only.
      }
    },
  };
}

function jcefTransport(host: JcefHost): Transport {
  return {
    kind: 'jcef',
    post: (message) => host.postMessage(JSON.stringify(message)),
    accepts: (event) => event.source === window || event.source === null,
    ...storageState(),
  };
}

function iframeTransport(): Transport {
  return {
    kind: 'iframe',
    post: (message) => window.parent.postMessage(message, '*'),
    accepts: (event) => event.source === window.parent,
    ...storageState(),
  };
}

/**
 * JCEF hosts may inject `window.fdiHost` only after the page has loaded (e.g.
 * from `onLoadEnd`). Until it appears, messages are queued; the host can also
 * dispatch a `fdi-host-ready` event on `window` to flush them immediately.
 */
function pendingJcefTransport(): Transport {
  const queue: WebviewMessage[] = [];
  let host: JcefHost | undefined;
  const flush = () => {
    if (host || !window.fdiHost) return;
    host = window.fdiHost;
    for (const message of queue.splice(0)) host.postMessage(JSON.stringify(message));
  };
  const timer = window.setInterval(() => {
    flush();
    if (host) window.clearInterval(timer);
  }, 25);
  window.addEventListener('fdi-host-ready', flush);
  return {
    kind: 'jcef',
    post(message) {
      flush();
      if (host) host.postMessage(JSON.stringify(message));
      else queue.push(message);
    },
    accepts: (event) => event.source === window || event.source === null,
    ...storageState(),
  };
}

/** Picks the transport for the current host. */
export function detectTransport(): Transport {
  if (typeof window.acquireVsCodeApi === 'function') return vscodeTransport(window.acquireVsCodeApi());
  if (window.fdiHost) return jcefTransport(window.fdiHost);
  if (window.parent !== window) return iframeTransport();
  // A top-level page outside VS Code: a JCEF host that has not injected its bridge yet.
  return pendingJcefTransport();
}

export function isHostMessage(data: unknown): data is HostMessage {
  return typeof data === 'object' && data !== null && typeof (data as { type?: unknown }).type === 'string';
}
