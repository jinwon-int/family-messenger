import test from 'node:test';
import assert from 'node:assert/strict';
import { build } from 'esbuild';
import { Window } from 'happy-dom';
import { saveSession } from '../../src/session.js';

// Exercise the real bootstrap, UI and document handlers; only the Matrix transport
// is synthetic. No test accounts, network calls or production session data.
const bundle = await build({
  entryPoints: [new URL('../../src/main.js', import.meta.url).pathname],
  bundle: true, write: false, format: 'iife', platform: 'browser',
  plugins: [{ name: 'synthetic-matrix', setup(builder) {
    builder.onResolve({ filter: /\/matrix\/client\.js$/ }, () => ({ path: 'client', namespace: 'fixture' }));
    builder.onLoad({ filter: /.*/, namespace: 'fixture' }, () => ({ contents: `
      export const createFamilyClient = async () => window.testClient;
      export const loginWithPassword = async () => { throw new Error('Unexpected login'); };
      export class PlaintextRefusedError extends Error {}
    ` }));
  } }],
});

async function app(t, { finePointer = false } = {}) {
  const window = new Window({ url: 'https://chat.example.test/' });
  t.after(() => window.happyDOM.abort());
  const { document } = window;
  document.body.innerHTML = '<div id="app"></div>';
  window.fetch = async () => ({ ok: true, json: async () => ({}) });
  const matchMedia = window.matchMedia.bind(window);
  window.matchMedia = (query) => query === '(pointer: fine)' ? { matches: finePointer } : matchMedia(query);
  let summaries = ['a', 'b', 'c'].map((id) => ({
    roomId: `!${id}:example.test`, displayName: id, kind: 'private', memberCount: 2, agents: [],
  }));
  let refresh;
  const sent = [];
  window.testClient = {
    enableEncryption: async () => {}, start() {}, onTimeline() {}, onVerificationRequest() {},
    onRoomAdded(callback) { refresh = callback; },
    roomSummaries: () => summaries, inviteSummaries: () => [], canLoadEarlier: () => false,
    roomMemberHandles: () => [], sendText: async (...args) => sent.push(args),
  };
  saveSession({ homeserverUrl: 'https://matrix.example.test', userId: '@reader:example.test', deviceId: 'TEST', accessToken: 'synthetic' }, {
    persistent: window.localStorage, volatile: window.sessionStorage,
  });
  window.eval(bundle.outputFiles[0].text);
  // Bootstrap awaits configuration, client creation and encryption initialization.
  for (let i = 0; i < 20 && !document.querySelector('.room-item'); i++) await new Promise((resolve) => setImmediate(resolve));
  assert.equal(document.querySelectorAll('.room-item').length, 3);
  const buttons = () => [...document.querySelectorAll('.room-item')];
  const key = (value, options = {}) => {
    const target = document.activeElement;
    const event = new window.KeyboardEvent('keydown', { key: value, bubbles: true, cancelable: true, ...options });
    target.dispatchEvent(event);
    // happy-dom does not implement the browser's Enter -> button click default.
    if (value === 'Enter' && target.tagName === 'BUTTON' && !event.defaultPrevented) target.click();
    return event;
  };
  return { window, document, buttons, key, sent, refresh, reorder() { summaries = [summaries[1], summaries[0], summaries[2]]; refresh(); } };
}

test('Enter opens a room and focuses composer even without a fine pointer; Escape restores the same row', async (t) => {
  const { document, buttons, key, sent } = await app(t);
  key('ArrowDown');
  key('ArrowDown');
  assert.ok(document.activeElement === buttons()[1]);
  key('Enter');
  const input = document.querySelector('.composer textarea');
  assert.ok(document.activeElement === input, "composer must retain focus");
  assert.equal(sent.length, 0, 'opening Enter must not send a message');
  input.value = '작성 중인 초안';
  key('Escape');
  assert.equal(document.querySelector('main.shell').dataset.view, 'list');
  assert.equal(document.activeElement.dataset.roomId, '!b:example.test');
  key('ArrowDown');
  assert.equal(document.activeElement.dataset.roomId, '!c:example.test');
  key('ArrowUp');
  key('Enter');
  assert.equal(document.activeElement.value, '작성 중인 초안', 'Escape must not discard the draft');
});

test('pointer-selected room returns to its row and follows room identity after list reordering', async (t) => {
  const { window, document, buttons, key, reorder, refresh } = await app(t, { finePointer: true });
  buttons()[1].dispatchEvent(new window.MouseEvent('click', { bubbles: true, detail: 1 }));
  assert.equal(document.activeElement.tagName, 'TEXTAREA');
  reorder();
  key('Escape');
  assert.ok(document.activeElement === buttons()[0]);
  assert.equal(document.activeElement.dataset.roomId, '!b:example.test');
  refresh();
  assert.equal(document.activeElement.dataset.roomId, '!b:example.test', 'list refresh keeps keyboard focus');
  key('ArrowDown');
  assert.equal(document.activeElement.dataset.roomId, '!a:example.test');
});

test('touch taps do not open a software keyboard; hardware Enter does', async (t) => {
  const { window, document, buttons, key } = await app(t);
  buttons()[0].dispatchEvent(new window.MouseEvent('click', { bubbles: true, detail: 1 }));
  assert.notEqual(document.activeElement.tagName, 'TEXTAREA');
  key('Escape');
  assert.ok(document.activeElement === buttons()[0]);
  key('Enter');
  assert.equal(document.activeElement.tagName, 'TEXTAREA');
});

test('IME and open dialogs retain Escape; ordinary composer arrows remain text editing', async (t) => {
  const { window, document, key } = await app(t);
  key('ArrowDown'); key('Enter');
  const input = document.activeElement;
  key('Escape', { isComposing: true });
  assert.ok(document.activeElement === input, "composer must retain focus");
  assert.equal(key('ArrowDown').defaultPrevented, false);
  const dialog = document.createElement('dialog');
  document.getElementById('app').append(dialog);
  dialog.showModal();
  key('Escape');
  assert.equal(document.querySelector('main.shell').dataset.view, 'room');
  dialog.close(); dialog.remove(); input.focus();
  key('Escape');
  assert.equal(document.querySelector('main.shell').dataset.view, 'list');
});
