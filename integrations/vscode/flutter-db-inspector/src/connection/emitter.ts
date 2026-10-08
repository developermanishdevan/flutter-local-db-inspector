/** Minimal event emitter compatible with `vscode.Event` (usable outside VS Code). */
export interface Disposable {
  dispose(): void;
}

export type Event<T> = (listener: (value: T) => void) => Disposable;

export class Emitter<T> {
  private readonly listeners = new Set<(value: T) => void>();

  readonly event: Event<T> = (listener) => {
    this.listeners.add(listener);
    return { dispose: () => this.listeners.delete(listener) };
  };

  fire(value: T): void {
    for (const listener of [...this.listeners]) {
      try {
        listener(value);
      } catch (error) {
        console.error('[flutter-db-inspector] listener failed', error);
      }
    }
  }

  dispose(): void {
    this.listeners.clear();
  }
}
