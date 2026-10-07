const byId = id => document.getElementById(id);
const token = document.querySelector('meta[name="csrf-token"]').content;
let busy = false;
let pending = false;
let connected = false;
let lastConversation = '';

function setSidebarVisible(visible, persist = true) {
  document.querySelector('main').classList.toggle('sidebar-hidden', !visible);
  const toggle = byId('toggle-sidebar');
  toggle.setAttribute('aria-expanded', String(visible));
  toggle.textContent = visible ? 'Hide sidebar' : 'Show sidebar';
  if (persist) {
    try {
      localStorage.setItem('ear.sidebar', visible ? 'visible' : 'hidden');
    } catch (_) {
      // Storage can be unavailable in private browsing contexts.
    }
  }
}

let sidebarVisible = true;
try {
  sidebarVisible = localStorage.getItem('ear.sidebar') !== 'hidden';
} catch (_) {
  // Storage can be unavailable in private browsing contexts.
}
setSidebarVisible(sidebarVisible, false);

function controls() {
  byId('send').disabled = !connected || busy || pending;
  byId('cancel').disabled = !connected || !busy || pending;
  byId('clear').disabled = !connected || busy || pending;
}

async function request(path, data) {
  const response = await fetch(path, {
    method: 'POST',
    headers: {'Content-Type': 'application/json', 'x-csrf-token': token},
    body: JSON.stringify(data || {})
  });
  const result = await response.json();
  if (!response.ok) throw new Error(result.error || 'Request failed');
}

function message(role, content, streaming = false) {
  const element = document.createElement('article');
  element.className = `message ${role}${streaming ? ' streaming' : ''}`;
  const label = document.createElement('div');
  label.className = 'role';
  label.textContent = role;
  const text = document.createElement('pre');
  text.textContent = content;
  element.append(label, text);
  return element;
}

function render(state) {
  busy = state.status === 'running';
  controls();
  byId('status').textContent = state.status;
  byId('status').className = `status ${state.status}`;
  byId('workspace').textContent = state.workspace;
  byId('model').textContent = state.model;
  byId('run-id').textContent = state.run_id || '-';
  byId('turns').textContent = state.turns;
  byId('tools').textContent = state.tool_calls;
  const usage = state.usage || {};
  byId('input-tokens').textContent = usage.input || 0;
  byId('output-tokens').textContent = usage.output || 0;
  byId('cached-tokens').textContent = usage.cached || 0;
  if (state.error) byId('error').textContent = state.error;

  const conversation = JSON.stringify([state.messages, state.partial]);
  if (conversation !== lastConversation) {
    const container = byId('messages');
    const atBottom = container.scrollHeight - container.scrollTop - container.clientHeight < 80;
    container.replaceChildren();
    state.messages.forEach(item => container.append(message(item.role, item.content)));
    if (state.partial) container.append(message('assistant', state.partial, true));
    if (!container.childElementCount) {
      const empty = document.createElement('div');
      empty.className = 'empty';
      empty.textContent = 'No messages yet';
      container.append(empty);
    }
    if (atBottom) container.scrollTop = container.scrollHeight;
    lastConversation = conversation;
  }

}

async function refresh() {
  try {
    const response = await fetch('/api/state', {cache: 'no-store'});
    if (!response.ok) throw new Error('Connection failed');
    connected = true;
    render(await response.json());
    byId('connection').textContent = 'Connected';
  } catch (_) {
    connected = false;
    byId('connection').textContent = 'Disconnected';
    controls();
  }
}

async function action(path, data) {
  pending = true;
  controls();
  byId('error').textContent = '';
  try {
    await request(path, data);
    if (path === '/api/prompt') byId('prompt').value = '';
    await refresh();
  } catch (error) {
    byId('error').textContent = error.message;
  } finally {
    pending = false;
    controls();
  }
}

byId('prompt-form').addEventListener('submit', event => {
  event.preventDefault();
  const prompt = byId('prompt').value.trim();
  if (prompt && !busy && !pending) action('/api/prompt', {prompt});
});
byId('toggle-sidebar').addEventListener('click', () => setSidebarVisible(sidebarVisible = !sidebarVisible));
byId('cancel').addEventListener('click', () => action('/api/cancel'));
byId('clear').addEventListener('click', () => action('/api/clear'));
async function poll() {
  await refresh();
  setTimeout(poll, 400);
}
poll();
