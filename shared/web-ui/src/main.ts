import type { AppInitMessage, HostMessage, InitMessage } from '@messages';
import { AppShell } from './appShell';
import { h } from './dom';
import { onHostMessage, panelHost, ready, reportError } from './host';
import { SqlView } from './sqlView';
import { StatsView } from './statsView';
import { TableView } from './tableView';

// Hosts can pass their theme in the URL (`index.html?theme=dark`) so the page
// does not flash light before `init` arrives.
const initialTheme = new URLSearchParams(window.location.search).get('theme');
if (initialTheme === 'dark' || initialTheme === 'light') document.documentElement.dataset.theme = initialTheme;

let view: TableView | SqlView | StatsView | undefined;
let shell: AppShell | undefined;
const app = document.getElementById('app')!;

function start(init: InitMessage | AppInitMessage): void {
  if (view || shell) return;
  if (init.view === 'app') {
    shell = new AppShell(init);
    shell.mount(app);
    return;
  }
  switch (init.view) {
    case 'table':
      view = new TableView(init, panelHost);
      break;
    case 'sql':
      view = new SqlView(init, panelHost);
      break;
    case 'stats':
      view = new StatsView(init, panelHost);
      break;
  }
  view.mount(app);
}

onHostMessage((message: HostMessage) => {
  if (shell) {
    onAppMessage(shell, message);
    return;
  }
  switch (message.type) {
    case 'init':
      start(message);
      break;
    case 'refresh':
      if (view instanceof TableView || view instanceof StatsView) view.refresh();
      break;
    case 'connection':
      if (view instanceof TableView) view.setConnection(message.state, message.message);
      if (view instanceof SqlView) view.setConnection(message.state);
      break;
    case 'setSql':
      if (view instanceof SqlView) {
        if (message.ifEmpty) view.suggestSql(message.sql);
        else view.setSql(message.sql, message.run);
      }
      break;
    case 'showTab':
      if (view instanceof TableView) view.showTab(message.tab);
      break;
  }
});

/** App mode: one shell for everything. */
function onAppMessage(app: AppShell, message: HostMessage): void {
  switch (message.type) {
    case 'connection':
      app.setConnection(message.state, message.message);
      break;
    case 'event':
      app.onEvent(message.name);
      break;
    case 'theme':
      app.setTheme(message.theme);
      break;
    case 'open':
      app.open(message.target);
      break;
    case 'reload':
    case 'refresh':
      void app.reloadEverything();
      break;
  }
}

window.addEventListener('error', (e) => {
  app.appendChild(h('p', { class: 'error-text', role: 'alert' }, `Unexpected error: ${e.message}`));
  reportError(`${e.message} (${e.filename}:${e.lineno})`);
});
window.addEventListener('unhandledrejection', (e) => {
  const reason: unknown = e.reason;
  // Protocol errors are shown in context; only report genuine bugs.
  if (reason instanceof Error && reason.name !== 'Error') reportError(`${reason.name}: ${reason.message}`);
});

ready();
