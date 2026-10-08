import type { FullValue } from '@messages';
import type { ValueType, WireValue } from '@protocol/types';
import { displayCell, editText, formatBytes, isMasked, isPartial, isTagged } from '@protocol/values';
import { button, clear, h, icon, isMod } from './dom';

export interface ValuePanelOptions {
  column: string;
  valueType: ValueType;
  value: WireValue;
  editable: boolean;
  nullable: boolean;
  /** Fetches the complete value (truncated text / blob). */
  loadFull?: (maxBytes: number) => Promise<FullValue>;
  saveToFile?: () => void;
  copy: (text: string) => void;
  /** Saves edited text; `null` sets SQL NULL / JSON null. */
  save?: (text: string | null) => Promise<boolean>;
}

const FULL_TEXT_LIMIT = 10 * 1024 * 1024;
const BLOB_PREVIEW_BYTES = 64 * 1024;

/** Side drawer showing one value in full: JSON pretty/raw, text, blob hex. */
export class ValuePanel {
  readonly element = h('aside', { class: 'value-panel', hidden: true, 'aria-label': 'Value inspector' });
  private options?: ValuePanelOptions;
  private fullText?: string;
  private mode: 'pretty' | 'raw' = 'pretty';

  constructor(private readonly onClose: () => void) {}

  get isOpen(): boolean {
    return !this.element.hidden;
  }

  show(options: ValuePanelOptions): void {
    this.options = options;
    this.fullText = undefined;
    this.element.hidden = false;
    this.render();
  }

  hide(): void {
    this.element.hidden = true;
    this.options = undefined;
    this.onClose();
  }

  private text(): string | undefined {
    const o = this.options!;
    if (this.fullText !== undefined) return this.fullText;
    if (isTagged(o.value) && o.value.$type === 'text') return o.value.preview;
    if (isTagged(o.value) && (o.value.$type === 'blob' || o.value.$type === 'masked')) return undefined;
    return editText(o.value);
  }

  private parsedJson(text: string | undefined): unknown {
    if (text === undefined) return undefined;
    const trimmed = text.trim();
    if (!/^[[{]/.test(trimmed)) return undefined;
    try {
      return JSON.parse(trimmed) as unknown;
    } catch {
      return undefined;
    }
  }

  private render(): void {
    const o = this.options!;
    clear(this.element);
    const display = displayCell(o.value);
    this.element.appendChild(
      h(
        'header',
        { class: 'value-header' },
        h('div', { class: 'value-title' }, h('strong', {}, o.column), h('span', { class: 'badge' }, o.valueType)),
        button('Close', () => this.hide(), { icon: 'close', iconOnly: true, title: 'Close (Esc)' }),
      ),
    );
    const body = h('div', { class: 'value-body' });
    this.element.appendChild(body);

    if (isMasked(o.value)) {
      body.appendChild(
        h('p', { class: 'notice' }, icon('lock'), ' This column is marked sensitive by the app. Its value never leaves the device.'),
      );
      return;
    }

    if (isTagged(o.value) && o.value.$type === 'blob') {
      this.renderBlob(body, o.value.size, o.value.preview);
      return;
    }

    const text = this.text();
    const json = this.parsedJson(text);
    const toolbar = h('div', { class: 'toolbar' });
    if (json !== undefined) {
      for (const mode of ['pretty', 'raw'] as const) {
        toolbar.appendChild(
          h(
            'button',
            {
              class: `btn toggle${this.mode === mode ? ' on' : ''}`,
              type: 'button',
              'aria-pressed': String(this.mode === mode),
              on: {
                click: () => {
                  this.mode = mode;
                  this.render();
                },
              },
            },
            mode === 'pretty' ? 'Pretty' : 'Raw',
          ),
        );
      }
    }
    toolbar.appendChild(
      button('Copy', () => o.copy(json !== undefined && this.mode === 'pretty' ? JSON.stringify(json, null, 2) : (text ?? '')), {
        icon: 'copy',
      }),
    );
    body.appendChild(toolbar);

    if (isPartial(o.value) && this.fullText === undefined) {
      const size = isTagged(o.value) && o.value.$type === 'text' ? o.value.size : 0;
      body.appendChild(
        h(
          'p',
          { class: 'notice' },
          icon('info'),
          ` Showing a preview of ${formatBytes(size)}. `,
          o.loadFull
            ? button(`Load full value`, () => void this.loadFullText(), { icon: 'cloud-download' })
            : null,
        ),
      );
    }

    if (o.value === null) {
      body.appendChild(h('p', { class: 'muted' }, 'NULL'));
    } else {
      const shown = json !== undefined && this.mode === 'pretty' ? JSON.stringify(json, null, 2) : (text ?? display.text);
      body.appendChild(h('pre', { class: `value-text${json !== undefined ? ' json' : ''}`, tabindex: 0 }, shown));
    }

    if (o.editable && o.save && (!isPartial(o.value) || this.fullText !== undefined)) {
      this.renderEditor(body, json !== undefined && this.mode === 'pretty' ? JSON.stringify(json, null, 2) : (text ?? ''));
    }
  }

  private renderEditor(body: HTMLElement, initial: string): void {
    const o = this.options!;
    const editor = h('textarea', { class: 'value-editor', 'aria-label': `Edit ${o.column}` });
    editor.value = initial;
    const status = h('span', { class: 'muted', 'aria-live': 'polite' });
    const save = async (text: string | null) => {
      status.textContent = 'Saving…';
      const ok = await o.save!(text);
      status.textContent = ok ? 'Saved' : '';
    };
    editor.addEventListener('keydown', (e) => {
      if (e.key === 'Enter' && isMod(e)) {
        e.preventDefault();
        void save(editor.value);
      }
    });
    body.appendChild(
      h(
        'details',
        { class: 'value-edit' },
        h('summary', {}, 'Edit value'),
        editor,
        h(
          'div',
          { class: 'toolbar' },
          button('Save', () => void save(editor.value), { icon: 'save', primary: true, title: 'Save (Ctrl/Cmd+Enter)' }),
          o.nullable ? button('Set NULL', () => void save(null), { icon: 'circle-slash' }) : null,
          status,
        ),
      ),
    );
  }

  private async loadFullText(): Promise<void> {
    const o = this.options!;
    if (!o.loadFull) return;
    const result = await o.loadFull(FULL_TEXT_LIMIT);
    if (this.options !== o) return;
    this.fullText = result.text ?? '';
    this.render();
    if (!result.complete) {
      this.element
        .querySelector('.value-body')
        ?.prepend(h('p', { class: 'notice' }, icon('warning'), ` Only the first ${formatBytes(FULL_TEXT_LIMIT)} were loaded.`));
    }
  }

  private renderBlob(body: HTMLElement, size: number, previewBase64: string): void {
    const o = this.options!;
    const hex = h('pre', { class: 'hex', tabindex: 0 }, hexDump(base64ToBytes(previewBase64)));
    body.appendChild(h('p', {}, icon('file-binary'), ` Binary value, ${formatBytes(size)}`));
    body.appendChild(
      h(
        'div',
        { class: 'toolbar' },
        o.loadFull
          ? button(`Preview ${formatBytes(Math.min(size, BLOB_PREVIEW_BYTES))}`, () => {
              void o.loadFull!(BLOB_PREVIEW_BYTES).then((full) => {
                hex.textContent = hexDump(base64ToBytes(full.base64 ?? '').slice(0, BLOB_PREVIEW_BYTES));
              });
            }, { icon: 'eye' })
          : null,
        o.saveToFile ? button('Save…', () => o.saveToFile!(), { icon: 'save' }) : null,
      ),
    );
    body.appendChild(hex);
  }
}

function base64ToBytes(base64: string): Uint8Array {
  const binary = atob(base64);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
  return bytes;
}

function hexDump(bytes: Uint8Array): string {
  if (bytes.length === 0) return '(no preview)';
  const lines: string[] = [];
  for (let offset = 0; offset < bytes.length; offset += 16) {
    const slice = bytes.slice(offset, offset + 16);
    const hex = [...slice].map((b) => b.toString(16).padStart(2, '0')).join(' ');
    const ascii = [...slice].map((b) => (b >= 32 && b < 127 ? String.fromCharCode(b) : '.')).join('');
    lines.push(`${offset.toString(16).padStart(8, '0')}  ${hex.padEnd(47)}  ${ascii}`);
  }
  return lines.join('\n');
}
