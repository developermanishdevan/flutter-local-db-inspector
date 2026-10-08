import { button, h } from './dom';

/**
 * In-page dialogs for app mode (VS Code uses its native dialogs instead).
 * They share the row form's look: `.dialog-backdrop` / `.dialog`.
 */
function open<T>(
  title: string,
  build: (form: HTMLFormElement, done: (value: T) => void) => HTMLElement | null,
  cancelValue: T,
): Promise<T> {
  document.querySelector('.dialog-backdrop')?.remove();
  const previouslyFocused = document.activeElement as HTMLElement | null;
  return new Promise<T>((resolve) => {
    const form = h('form', { class: 'dialog', role: 'dialog', 'aria-label': title });
    const backdrop = h('div', { class: 'dialog-backdrop' }, form);
    const done = (value: T) => {
      backdrop.remove();
      previouslyFocused?.focus();
      resolve(value);
    };
    form.appendChild(h('h2', {}, title));
    const focus = build(form, done);
    form.addEventListener('keydown', (e) => {
      if (e.key === 'Escape') {
        e.preventDefault();
        done(cancelValue);
      }
    });
    document.body.appendChild(backdrop);
    (focus ?? form.querySelector<HTMLElement>('button[type=submit]'))?.focus();
  });
}

export interface ConfirmOptions {
  title: string;
  message?: string;
  /** Shown in a monospace block (SQL, a key, ...). */
  code?: string;
  okLabel: string;
  danger?: boolean;
}

export function confirmDialog(options: ConfirmOptions): Promise<boolean> {
  return open<boolean>(
    options.title,
    (form, done) => {
      if (options.message) form.appendChild(h('p', {}, options.message));
      if (options.code) form.appendChild(h('pre', { class: 'dialog-code' }, options.code));
      const ok = h('button', { class: `btn primary${options.danger ? ' danger' : ''}`, type: 'submit' }, options.okLabel);
      form.appendChild(h('div', { class: 'dialog-actions' }, button('Cancel', () => done(false)), ok));
      form.addEventListener('submit', (e) => {
        e.preventDefault();
        done(true);
      });
      return options.danger ? form.querySelector<HTMLElement>('.dialog-actions .btn:not(.primary)') : ok;
    },
    false,
  );
}

export function promptDialog(options: { title: string; label: string; value?: string; okLabel: string }): Promise<string | undefined> {
  return open<string | undefined>(
    options.title,
    (form, done) => {
      const input = h('input', { class: 'input', type: 'text', 'aria-label': options.label, value: options.value ?? '' });
      form.appendChild(h('label', { class: 'dialog-field' }, h('span', {}, options.label), input));
      const ok = h('button', { class: 'btn primary', type: 'submit' }, options.okLabel);
      form.appendChild(h('div', { class: 'dialog-actions' }, button('Cancel', () => done(undefined)), ok));
      form.addEventListener('submit', (e) => {
        e.preventDefault();
        const value = input.value.trim();
        if (value) done(value);
      });
      queueMicrotask(() => input.select());
      return input;
    },
    undefined,
  );
}

export interface Choice<T extends string> {
  id: T;
  label: string;
  description?: string;
}

/** Radio list; resolves the chosen id, or undefined when cancelled. */
export function chooseDialog<T extends string>(options: {
  title: string;
  choices: readonly Choice<T>[];
  okLabel: string;
}): Promise<T | undefined> {
  return open<T | undefined>(
    options.title,
    (form, done) => {
      const name = `choice-${Date.now()}`;
      const list = h('div', { class: 'dialog-choices', role: 'radiogroup' });
      options.choices.forEach((choice, i) => {
        const radio = h('input', { type: 'radio', value: choice.id });
        radio.name = name;
        radio.checked = i === 0;
        list.appendChild(
          h(
            'label',
            { class: 'dialog-choice' },
            radio,
            h('span', {}, h('strong', {}, choice.label), choice.description ? h('span', { class: 'muted' }, ` — ${choice.description}`) : null),
          ),
        );
      });
      form.appendChild(list);
      const ok = h('button', { class: 'btn primary', type: 'submit' }, options.okLabel);
      form.appendChild(h('div', { class: 'dialog-actions' }, button('Cancel', () => done(undefined)), ok));
      form.addEventListener('submit', (e) => {
        e.preventDefault();
        const checked = form.querySelector<HTMLInputElement>(`input[name="${name}"]:checked`);
        done(checked ? (checked.value as T) : undefined);
      });
      return list.querySelector<HTMLElement>('input:checked');
    },
    undefined,
  );
}
