// DOM rendering. Views hold no business logic: they translate the pure
// modules in src/ into screens. All copy comes from src/strings.js and
// every text is inserted as a text node (no HTML injection).

import { strings } from './strings.js';
import { emojiLabel, transition } from './verification.js';
import { createRecoveryFlow } from './recovery.js';
import { composerKeyAction } from './keyboard.js';
import { canAccept } from './invites.js';

/** replaceChildren that drops null/false entries (a bare null would render the text "null"). */
function setChildren(node, ...children) {
  node.replaceChildren(...children.flat(Infinity).filter((child) => child != null && child !== false));
}

function el(tag, attrs = {}, ...children) {
  const node = document.createElement(tag);
  for (const [key, value] of Object.entries(attrs)) {
    if (value == null || value === false) continue;
    if (key === 'class') node.className = value;
    else if (key.startsWith('on') && typeof value === 'function') node.addEventListener(key.slice(2), value);
    else node.setAttribute(key, value === true ? '' : String(value));
  }
  for (const child of children.flat(Infinity)) {
    if (child == null || child === false) continue;
    node.append(child.nodeType ? child : document.createTextNode(String(child)));
  }
  return node;
}

/** label + input pair; keeps the field markup in one place. */
function field(labelText, inputAttrs) {
  const id = `f-${inputAttrs.name}`;
  return el('div', { class: 'field' }, el('label', { for: id }, labelText), el('input', { id, ...inputAttrs }));
}

/** First visible character of a name for the avatar circle. */
function initial(name) {
  const text = String(name ?? '').trim();
  if (!text) return '·';
  const first = [...text][0];
  return first.toUpperCase();
}

/** Formats a message timestamp for the bubble footer; empty when unknown. */
function timeLabel(ts) {
  if (!Number.isFinite(ts) || ts <= 0) return '';
  try {
    return new Intl.DateTimeFormat('ko-KR', { hour: 'numeric', minute: '2-digit' }).format(new Date(ts));
  } catch {
    return '';
  }
}

/** Login screen. Calls onSubmit({homeserverUrl, user, password}). */
export function renderLogin(root, { onSubmit }) {
  root.replaceChildren();
  const form = el(
    'form',
    {
      onsubmit: (event) => {
        event.preventDefault();
        const data = new FormData(form);
        onSubmit({
          homeserverUrl: String(data.get('homeserverUrl') ?? '').trim(),
          user: String(data.get('user') ?? '').trim(),
          password: String(data.get('password') ?? ''),
        });
      },
    },
    field(strings.login.homeserverLabel, { name: 'homeserverUrl', type: 'url', required: true, placeholder: strings.login.homeserverPlaceholder, autocomplete: 'url', inputmode: 'url' }),
    field(strings.login.userLabel, { name: 'user', required: true, autocomplete: 'username', placeholder: strings.login.userPlaceholder, autocapitalize: 'none', spellcheck: 'false' }),
    field(strings.login.passwordLabel, { name: 'password', type: 'password', required: true, autocomplete: 'current-password', placeholder: strings.login.passwordPlaceholder }),
    el('button', { type: 'submit', class: 'primary block' }, strings.login.submit),
  );
  const card = el(
    'section',
    { class: 'card login', 'aria-labelledby': 'login-title' },
    el(
      'div',
      { class: 'brand-mark' },
      el('img', { src: './icons/icon.svg', alt: '', width: 44, height: 44 }),
      el('h1', { id: 'login-title' }, strings.appName),
    ),
    el('p', { class: 'hint' }, strings.login.hint),
    form,
    el('p', { class: 'login-note' }, strings.login.encryptedNote),
  );
  root.append(el('main', { class: 'center login-wrap' }, card));
}

/** Inline status line inside the current main element. */
export function setStatus(root, message, tone = 'info') {
  root.querySelector('.status')?.remove();
  if (!message) return;
  const line = el('p', { class: `status ${tone}`, role: 'status' }, message);
  root.querySelector('main')?.append(line);
}

/** Participant name with badges for AI agents and self. */
export function participantLabel(member, { isAgent = false, isMe = false } = {}) {
  const bits = [el('span', { class: 'sender' }, member?.name ?? member?.userId ?? '')];
  if (isMe) bits.push(el('span', { class: 'pill you' }, strings.participants.youLabel));
  if (isAgent) bits.push(el('span', { class: 'pill ai', title: strings.participants.aiTitle }, strings.participants.aiBadge));
  return bits;
}

function roomBadge(kind) {
  if (kind === 'family') return strings.rooms.familyBadge;
  if (kind === 'private') return strings.rooms.privateBadge;
  return strings.rooms.otherBadge;
}

/** One pending-invitation card. handlers: {isAiConsentAcknowledged, onAiConsentChange, onAccept, onDecline}. */
function inviteCard(invite, handlers) {
  const acknowledged = handlers.isAiConsentAcknowledged(invite);
  const gate = canAccept(invite, { aiConsentAcknowledged: acknowledged });
  return el(
    'article',
    { class: 'invite-item' },
    el(
      'div',
      { class: 'invite-head' },
      el('span', { class: 'room-name' }, invite.displayName || strings.rooms.unnamed),
      el('span', { class: `pill kind-${invite.kind}` }, roomBadge(invite.kind)),
      invite.agentCount > 0
        ? el('span', { class: 'pill ai', title: strings.participants.aiTitle }, strings.participants.aiBadge)
        : null,
    ),
    el(
      'p',
      { class: 'meta' },
      invite.inviterName ? `${strings.invite.from(invite.inviterName)} · ` : '',
      strings.rooms.memberCount(invite.memberCount),
    ),
    invite.requiresAiConsent
      ? el(
          'div',
          { class: 'invite-consent' },
          el('p', { class: 'invite-consent-heading' }, strings.invite.aiConsentHeading),
          el('p', {}, strings.invite.aiConsentBody),
          el(
            'label',
            { class: 'invite-consent-check' },
            el('input', {
              type: 'checkbox',
              checked: acknowledged || null,
              onchange: (event) => handlers.onAiConsentChange(invite, event.target.checked),
            }),
            strings.invite.aiConsentLabel,
          ),
          gate.allowed ? null : el('p', { class: 'hint' }, strings.invite.aiConsentRequired),
        )
      : null,
    el(
      'div',
      { class: 'actions' },
      el(
        'button',
        { type: 'button', class: 'primary', disabled: gate.allowed ? null : true, onclick: () => handlers.onAccept(invite) },
        strings.invite.accept,
      ),
      el('button', { type: 'button', class: 'ghost', onclick: () => handlers.onDecline(invite) }, strings.invite.decline),
    ),
  );
}

function roomListItem(room, onSelect) {
  const agentCount = Array.isArray(room.agents) ? room.agents.length : 0;
  return el(
    'li',
    {},
    el(
      'button',
      { type: 'button', class: 'room-item', onclick: () => onSelect(room) },
      el('span', { class: `avatar kind-${room.kind}`, 'aria-hidden': 'true' }, initial(room.displayName || strings.rooms.unnamed)),
      el(
        'span',
        { class: 'texts' },
        el('span', { class: 'room-name' }, room.displayName || strings.rooms.unnamed),
        el(
          'span',
          { class: 'meta' },
          el('span', { class: `pill kind-${room.kind}` }, roomBadge(room.kind)),
          agentCount > 0 ? el('span', { class: 'pill ai', title: strings.participants.aiTitle }, strings.participants.aiBadge) : null,
          strings.rooms.memberCount(room.memberCount),
        ),
      ),
      el('span', { class: 'chevron', 'aria-hidden': 'true' }, '›'),
    ),
  );
}

/** Left pane: room list. Calls onSelect(room). */
export function renderRoomList(root, { summaries, onSelect, syncState, onOpenVerification, onOpenRecovery, invites = [], inviteHandlers = null }) {
  root.replaceChildren();
  const body = syncState === 'loading'
    ? el('p', { class: 'empty' }, strings.rooms.loading)
    : summaries.length === 0
      ? el('p', { class: 'empty' }, syncState === 'error' ? strings.rooms.syncError : strings.rooms.empty)
      : el('ul', { class: 'rooms' }, summaries.map((room) => roomListItem(room, onSelect)));
  const inviteSection = inviteHandlers && invites.length > 0
    ? el(
        'section',
        { class: 'card invites', 'aria-label': strings.invite.title },
        el('h2', {}, strings.invite.title, el('span', { class: 'pill count' }, strings.invite.count(invites.length))),
        invites.map((invite) => inviteCard(invite, inviteHandlers)),
      )
    : null;
  root.append(
    el(
      'main',
      { class: 'center rooms-screen' },
      el(
        'header',
        { class: 'appbar' },
        el('div', { class: 'titles' }, el('h1', {}, strings.rooms.title), el('span', { class: 'subtitle' }, strings.appName)),
        el(
          'div',
          { class: 'tools' },
          el('button', { type: 'button', class: 'ghost', onclick: onOpenVerification }, strings.verification.title),
          el('button', { type: 'button', class: 'ghost', onclick: onOpenRecovery }, strings.recovery.title),
        ),
      ),
      syncState === 'error' && summaries.length > 0 ? el('p', { class: 'status warn', role: 'status' }, strings.rooms.syncError) : null,
      inviteSection,
      summaries.length > 0 ? el('p', { class: 'section-title' }, strings.rooms.listTitle) : null,
      body,
    ),
  );
}

function attachmentLabel(kind) {
  if (kind === 'photo') return strings.media.photo;
  if (kind === 'video') return strings.media.video;
  if (kind === 'file') return strings.media.file;
  return null;
}

function bubble(entry) {
  const attach = attachmentLabel(entry.kind);
  const time = timeLabel(entry.ts);
  const foot = [entry.meta, time].filter(Boolean);
  return el(
    'li',
    { class: `bubble kind-${entry.kind}`, 'data-me': entry.isMe ? 'true' : 'false' },
    entry.isMe ? null : el('span', { class: 'who' }, participantLabel(entry, entry)),
    el('p', { class: 'body' }, attach ? el('span', { class: 'attach-label' }, attach) : null, entry.body),
    foot.length > 0 ? el('span', { class: 'foot' }, foot.map((text, i) => (i > 0 ? ` · ${text}` : text))) : null,
  );
}

/** Chat pane for one room. onSend(text), onAttach(file). */
export function renderRoom(root, { room, timeline, onSend, onAttach, onBack, notice }) {
  // 전체 재렌더 사이에 작성 중인 초안과 포커스·캐럿을 보존한다(메시지 도착마다 입력이 사라지지 않게).
  const previous = root.querySelector('.composer textarea[name=body]');
  const draft = previous?.value ?? '';
  const hadFocus = previous != null && document.activeElement === previous;
  root.replaceChildren();
  const list = el(
    'ul',
    { class: 'timeline', 'aria-live': 'polite' },
    timeline.length === 0 ? el('li', { class: 'empty' }, strings.chat.empty) : timeline.map(bubble),
  );
  const attachInput = (accept, label) => {
    const input = el('input', {
      type: 'file',
      accept,
      hidden: true,
      onchange: () => {
        const file = input.files?.[0];
        if (file) onAttach(file);
        input.value = '';
        attachBar.hidden = true;
        attachToggle.setAttribute('aria-expanded', 'false');
      },
    });
    const button = el('button', { type: 'button', class: 'secondary', onclick: () => input.click() }, label);
    return [button, input];
  };
  const attachBar = el(
    'div',
    { class: 'attach-bar', hidden: true, id: 'attach-bar' },
    attachInput('image/*', strings.chat.attachPhoto),
    attachInput('video/*', strings.chat.attachVideo),
    attachInput('', strings.chat.attachFile),
  );
  const attachToggle = el(
    'button',
    {
      type: 'button',
      class: 'icon',
      'aria-label': strings.chat.attach,
      'aria-expanded': 'false',
      'aria-controls': 'attach-bar',
      onclick: () => {
        const open = attachBar.hidden;
        attachBar.hidden = !open;
        attachToggle.setAttribute('aria-expanded', open ? 'true' : 'false');
      },
    },
    '+',
  );
  const composer = el(
    'form',
    {
      class: 'composer',
      onsubmit: (event) => {
        event.preventDefault();
        const input = composer.querySelector('textarea[name=body]');
        const text = input.value;
        if (text.trim().length === 0) {
          input.focus();
          return;
        }
        // 먼저 비우고 나서 보낸다. onSend는 SDK 로컬 에코를 동기적으로 발행해 renderRoom이
        // 즉시 다시 그려지는데, 그때 초안 보존이 아직 남아 있는 본문을 새 작성창으로 옮겨
        // "엔터를 쳐도 글이 안 사라지는" 회귀가 있었다(2026-09-17 실기기 관측).
        input.value = '';
        input.style.height = '';
        onSend(text);
        // 재렌더로 작성창이 교체됐을 수 있으니 현재 것을 찾아 포커스한다.
        (root.querySelector('.composer textarea[name=body]') ?? input).focus();
      },
    },
    attachToggle,
    el('textarea', {
      name: 'body',
      rows: '1',
      placeholder: strings.chat.messagePlaceholder,
      autocomplete: 'off',
      'aria-label': strings.chat.messagePlaceholder,
      enterkeyhint: 'send',
      onkeydown: (event) => {
        const action = composerKeyAction(event);
        if (action !== 'send') return; // Shift+Enter 등 줄바꿈은 기본 동작
        event.preventDefault();
        composer.requestSubmit();
      },
      oninput: (event) => {
        const input = event.currentTarget;
        input.style.height = 'auto';
        input.style.height = `${Math.min(input.scrollHeight, 160)}px`;
      },
    }),
    el('button', { type: 'submit', class: 'primary' }, strings.chat.send),
  );
  root.append(
    el(
      'main',
      { class: 'room-screen' },
      el(
        'header',
        { class: 'appbar' },
        el('button', { type: 'button', class: 'icon ghost back', 'aria-label': strings.chat.back, onclick: onBack }, '←'),
        el(
          'div',
          { class: 'titles' },
          el('h2', {}, room.displayName || strings.rooms.unnamed),
          el('span', { class: 'subtitle lock' }, `${roomBadge(room.kind)} · ${strings.rooms.memberCount(room.memberCount)} · ${strings.chat.encryptedShort}`),
        ),
      ),
      notice ? el('p', { class: 'status error', role: 'alert' }, notice) : null,
      list,
      el('div', { class: 'composer-wrap' }, attachBar, composer),
    ),
  );
  list.scrollTop = list.scrollHeight;
  const input = composer.querySelector('textarea[name=body]');
  if (draft) {
    input.value = draft;
    input.style.height = 'auto';
    input.style.height = `${Math.min(input.scrollHeight, 160)}px`;
  }
  if (hadFocus) {
    input.focus();
    const end = input.value.length;
    input.setSelectionRange(end, end);
  }
}

/**
 * Device verification sheet.
 * `driver(callbacks)` starts the SDK SAS exchange; callbacks are
 * onEmojis(emojis, {confirm, mismatch}), onDone, onCancelled.
 */
export function openVerificationSheet(root, { driver, onClose }) {
  const close = () => dialog.close();
  let state = { state: 'idle' };
  let confirmers = null;
  const dialog = el('dialog', { class: 'sheet', 'aria-labelledby': 'verify-title' });
  const apply = (action) => {
    state = transition(state, action);
    render();
  };
  const render = () => {
    const rows = (state.emojis ?? []).map((emoji) => {
      const glyph = Array.isArray(emoji) ? emoji[0] : emoji?.emoji;
      return el('li', {}, el('span', { class: 'emoji' }, glyph ?? ''), el('span', { class: 'meta' }, emojiLabel(emoji)));
    });
    setChildren(dialog, 
      el('h2', { id: 'verify-title' }, strings.verification.title),
      el('p', { class: 'hint' }, strings.verification.intro),
      state.state === 'idle' ? el('button', { type: 'button', class: 'primary block', onclick: start }, strings.verification.start) : null,
      state.state === 'ready'
        ? el(
            'div',
            { class: 'column' },
            el('p', { class: 'compare' }, strings.verification.compareHeading),
            el('ul', { class: 'emojis' }, rows),
            el(
              'div',
              { class: 'actions' },
              el('button', { type: 'button', class: 'primary', onclick: () => confirmers?.confirm() }, strings.verification.same),
              el('button', { type: 'button', class: 'danger', onclick: () => confirmers?.mismatch() }, strings.verification.different),
            ),
          )
        : null,
      state.state === 'requested' || state.state === 'waiting'
        ? el('p', { class: 'status' }, strings.verification.waiting)
        : null,
      state.state === 'matched' ? el('p', { class: 'status ok' }, strings.verification.done) : null,
      state.state === 'mismatched'
        ? el('div', { class: 'status error' }, el('strong', {}, strings.verification.mismatchTitle), el('br'), strings.verification.mismatchBody)
        : null,
      state.state === 'cancelled' ? el('p', { class: 'status warn' }, strings.verification.cancelled) : null,
      el('div', { class: 'row end' }, el('button', { type: 'button', class: 'ghost', onclick: close }, strings.verification.close)),
    );
  };
  const start = () => {
    apply({ type: 'request' });
    driver({
      onEmojis: (emojis, sdkConfirmers) => {
        confirmers = sdkConfirmers;
        apply({ type: 'ready', emojis });
      },
      onDone: () => apply({ type: 'confirm' }),
      onCancelled: () => apply({ type: 'cancel' }),
    }).catch(() => apply({ type: 'cancel' }));
  };
  root.append(dialog);
  dialog.showModal();
  render();
  return close;
}

/**
 * Recovery key sheet: generate → show once → typed-back confirmation.
 * The key lives only inside the flow object and is never stored.
 */
export function openRecoverySheet(root, { onClose }) {
  const flow = createRecoveryFlow();
  let confirmed = false;
  const close = () => dialog.close();
  const dialog = el('dialog', { class: 'sheet', 'aria-labelledby': 'recovery-title' });
  const render = () => {
    setChildren(dialog, 
      el('h2', { id: 'recovery-title' }, strings.recovery.title),
      el('p', { class: 'hint' }, strings.recovery.intro),
      el('p', { class: 'status warn' }, el('strong', {}, strings.recovery.showOnceHeading), el('br'), strings.recovery.showOnceBody),
      el('code', { class: 'recovery-key' }, flow.formatted),
      el('p', { class: 'meta' }, strings.recovery.privacy),
      confirmed
        ? el('p', { class: 'status ok' }, strings.recovery.done)
        : el(
            'form',
            {
              class: 'column',
              onsubmit: (event) => {
                event.preventDefault();
                const input = dialog.querySelector('input[name=confirm]');
                const feedback = dialog.querySelector('.feedback');
                if (flow.confirm(input.value)) {
                  confirmed = true;
                  render();
                } else {
                  feedback.textContent = strings.recovery.mismatch;
                }
              },
            },
            field(strings.recovery.confirmLabel, { name: 'confirm', autocomplete: 'off', spellcheck: 'false', autocapitalize: 'none', placeholder: strings.recovery.confirmPlaceholder }),
            el('span', { class: 'feedback', role: 'alert' }),
            el('button', { class: 'primary block', type: 'submit' }, strings.recovery.confirm),
          ),
      el('div', { class: 'row end' }, el('button', { type: 'button', class: 'ghost', onclick: close }, strings.verification.close)),
    );
  };
  root.append(dialog);
  dialog.showModal();
  render();
  return close;
}
