type Child = Node | string | null | undefined | false;

type Props = {
  class?: string;
  title?: string;
  href?: string;
  role?: string;
  tabindex?: number;
  hidden?: boolean;
  disabled?: boolean;
  type?: string;
  value?: string;
  placeholder?: string;
  'aria-label'?: string;
  'aria-pressed'?: string;
  'aria-selected'?: string;
  'aria-sort'?: string;
  'aria-live'?: string;
  dataset?: Record<string, string>;
  on?: Partial<{ [K in keyof HTMLElementEventMap]: (e: HTMLElementEventMap[K]) => void }>;
};

/** Creates an element. Text children are always set as text (never HTML). */
export function h<K extends keyof HTMLElementTagNameMap>(
  tag: K,
  props: Props = {},
  ...children: Child[]
): HTMLElementTagNameMap[K] {
  const el = document.createElement(tag);
  const { on, dataset, ...attrs } = props;
  for (const [name, value] of Object.entries(attrs)) {
    if (value === undefined || value === false) continue;
    if (name === 'value' && 'value' in el) (el as HTMLInputElement).value = String(value);
    else el.setAttribute(name === 'class' ? 'class' : name, value === true ? '' : String(value));
  }
  if (dataset) Object.assign(el.dataset, dataset);
  if (on) {
    for (const [event, handler] of Object.entries(on)) el.addEventListener(event, handler as EventListener);
  }
  append(el, ...children);
  return el;
}

export function append(parent: Node, ...children: Child[]): void {
  for (const child of children) {
    if (child === null || child === undefined || child === false) continue;
    parent.appendChild(typeof child === 'string' ? document.createTextNode(child) : child);
  }
}

export function icon(name: string, label?: string): HTMLElement {
  const el = h('span', { class: `codicon codicon-${name}` });
  if (label) el.setAttribute('aria-label', label);
  else el.setAttribute('aria-hidden', 'true');
  return el;
}

export function button(
  label: string,
  onClick: () => void,
  options: { icon?: string; title?: string; primary?: boolean; iconOnly?: boolean; disabled?: boolean } = {},
): HTMLButtonElement {
  return h(
    'button',
    {
      class: `btn${options.primary ? ' primary' : ''}${options.iconOnly ? ' icon-only' : ''}`,
      title: options.title ?? label,
      'aria-label': options.title ?? label,
      disabled: options.disabled,
      type: 'button',
      on: { click: onClick },
    },
    options.icon ? icon(options.icon) : null,
    options.iconOnly ? null : h('span', {}, label),
  );
}

export function clear(el: Element): void {
  while (el.firstChild) el.removeChild(el.firstChild);
}

/** Shows a transient message in the shared live region (screen readers too). */
export function announce(text: string): void {
  let region = document.getElementById('announcer');
  if (!region) {
    region = h('div', { class: 'sr-only', 'aria-live': 'polite' });
    region.id = 'announcer';
    document.body.appendChild(region);
  }
  region.textContent = text;
}

export interface MenuItem {
  label: string;
  icon?: string;
  shortcut?: string;
  danger?: boolean;
  disabled?: boolean;
  run(): void;
}

/** Context menu at a screen position; closes on outside click or Escape. */
export function showMenu(x: number, y: number, items: (MenuItem | 'separator')[]): void {
  document.querySelector('.menu')?.remove();
  const menu = h('div', { class: 'menu', role: 'menu' });
  const close = () => {
    menu.remove();
    document.removeEventListener('mousedown', outside, true);
  };
  const outside = (e: MouseEvent) => {
    if (!menu.contains(e.target as Node)) close();
  };
  for (const item of items) {
    if (item === 'separator') {
      menu.appendChild(h('div', { class: 'menu-separator', role: 'separator' }));
      continue;
    }
    menu.appendChild(
      h(
        'button',
        {
          class: `menu-item${item.danger ? ' danger' : ''}`,
          role: 'menuitem',
          disabled: item.disabled,
          type: 'button',
          on: {
            click: () => {
              close();
              item.run();
            },
          },
        },
        item.icon ? icon(item.icon) : h('span', { class: 'codicon-spacer' }),
        h('span', { class: 'menu-label' }, item.label),
        item.shortcut ? h('span', { class: 'menu-shortcut' }, item.shortcut) : null,
      ),
    );
  }
  menu.addEventListener('keydown', (e) => {
    const buttons = [...menu.querySelectorAll<HTMLButtonElement>('.menu-item:not([disabled])')];
    const index = buttons.indexOf(document.activeElement as HTMLButtonElement);
    if (e.key === 'Escape') close();
    else if (e.key === 'ArrowDown') buttons[(index + 1) % buttons.length]?.focus();
    else if (e.key === 'ArrowUp') buttons[(index - 1 + buttons.length) % buttons.length]?.focus();
    else return;
    e.preventDefault();
  });
  document.body.appendChild(menu);
  const rect = menu.getBoundingClientRect();
  menu.style.left = `${Math.min(x, window.innerWidth - rect.width - 4)}px`;
  menu.style.top = `${Math.min(y, window.innerHeight - rect.height - 4)}px`;
  document.addEventListener('mousedown', outside, true);
  menu.querySelector<HTMLButtonElement>('.menu-item:not([disabled])')?.focus();
}

export const isMac = navigator.platform.toUpperCase().includes('MAC');
export const modKey = isMac ? '⌘' : 'Ctrl+';

export function isMod(e: KeyboardEvent): boolean {
  return isMac ? e.metaKey : e.ctrlKey;
}
