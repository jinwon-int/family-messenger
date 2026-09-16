// DOM rendering. Views hold no business logic: they translate the pure
// modules in src/ into screens. All copy comes from src/strings.js and
// every text is inserted as a text node (no HTML injection).

import { strings } from './strings.js';
import { emojiLabel, transition } from './verification.js';
import { createRecoveryFlow } from './recovery.js';
import { canAccept } from './invites.js';

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

/** Login screen. Calls onSubmit({homeserverUrl, user, password}). */
export function renderLogin(root, { onSubmit }) {
  root.replaceChildren();
  const form = el(
    'form',
    {
      class: 'card login',
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
    el('h1', {}, strings.appName),
    el('p', { class: 'hint' }, strings.login.hint),
    el('label', {}, strings.login.homeserverLabel),
    el('input', { name: 'homeserverUrl', type: 'url', required: true, placeholder: strings.login.homeserverPlaceholder, autocomplete: 'url' }),
    el('label', {}, strings.login.userLabel),
    el('input', { name: 'user', required: true, autocomplete: 'username', placeholder: strings.login.userPlaceholder }),
    el('label', {}, strings.login.passwordLabel),
    el('input', { name: 'password', type: 'password', required: true, autocomplete: 'current-password', placeholder: strings.login.passwordPlaceholder }),
    el('button', { type: 'submit', class: 'primary' }, strings.login.submit),
  );
  root.append(el('main', { class: 'center' }, form));
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
    invite.inviterName ? el('p', { class: 'hint' }, strings.invite.from(invite.inviterName)) : null,
    el('p', { class: 'meta' }, strings.rooms.memberCount(invite.memberCount)),
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
      { class: 'row gap' },
      el(
        'button',
        { type: 'button', class: 'primary', disabled: gate.allowed ? null : true, onclick: () => handlers.onAccept(invite) },
        strings.invite.accept,
      ),
      el('button', { type: 'button', class: 'secondary', onclick: () => handlers.onDecline(invite) }, strings.invite.decline),
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
      : el(
          'ul',
          { class: 'rooms' },
          summaries.map((room) =>
            el(
              'li',
              {},
              el(
                'button',
                { class: 'room-item', onclick: () => onSelect(room) },
                el('span', { class: 'room-name' }, room.displayName || strings.rooms.unnamed),
                el(
                  'span',
                  { class: 'meta' },
                  el('span', { class: `pill kind-${room.kind}` }, roomBadge(room.kind)),
                  strings.rooms.memberCount(room.memberCount),
                ),
              ),
            ),
          ),
        );
  const inviteSection = inviteHandlers && invites.length > 0
    ? el(
        'section',
        { class: 'card invites', 'aria-label': strings.invite.title },
        el('h2', {}, strings.invite.title),
        invites.map((invite) => inviteCard(invite, inviteHandlers)),
      )
    : null;
  root.append(
    el(
      'main',
      { class: 'center rooms-screen' },
      el('header', { class: 'row between' }, el('h1', {}, strings.rooms.title), el('span', { class: 'pill brand' }, strings.appName)),
      el(
        'div',
        { class: 'row gap' },
        el('button', { type: 'button', class: 'secondary', onclick: onOpenVerification }, strings.verification.title),
        el('button', { type: 'button', class: 'secondary', onclick: onOpenRecovery }, strings.recovery.title),
      ),
      inviteSection,
      body,
    ),
  );
}

/** Chat pane for one room. onSend(text), onAttach(file). */
export function renderRoom(root, { room, timeline, onSend, onAttach, onBack, notice }) {
  root.replaceChildren();
  const list = el(
    'ul',
    { class: 'timeline', 'aria-live': 'polite' },
    timeline.map((entry) =>
      el(
        'li',
        { class: `bubble kind-${entry.kind}` },
        participantLabel(entry, entry),
        el('p', { class: 'body' }, entry.body),
        entry.meta ? el('span', { class: 'meta' }, entry.meta) : null,
      ),
    ),
  );
  const composer = el(
    'form',
    {
      class: 'composer',
      onsubmit: (event) => {
        event.preventDefault();
        const input = composer.querySelector('input[name=body]');
        if (input.value.trim().length > 0) {
          onSend(input.value);
          input.value = '';
        }
      },
    },
    el('input', { name: 'body', type: 'text', placeholder: strings.chat.messagePlaceholder, autocomplete: 'off' }),
    el('button', { type: 'submit', class: 'primary' }, strings.chat.send),
  );
  const attach = (accept, label) => {
    const input = el('input', {
      type: 'file',
      accept,
      hidden: true,
      onchange: () => {
        const file = input.files?.[0];
        if (file) onAttach(file);
        input.value = '';
      },
    });
    const button = el('button', { type: 'button', class: 'secondary', onclick: () => input.click() }, label);
    return el('span', { class: 'row gap' }, button, input);
  };
  root.append(
    el(
      'main',
      { class: 'room-screen' },
      el(
        'header',
        { class: 'row between' },
        el('button', { type: 'button', class: 'secondary back', onclick: onBack }, '←'),
        el('h2', {}, room.displayName || strings.rooms.unnamed),
        el('span', { class: 'meta' }, strings.chat.encrypted),
      ),
      notice ? el('p', { class: 'status error', role: 'alert' }, notice) : null,
      list,
      el(
        'div',
        { class: 'row gap' },
        attach('image/*', strings.chat.attachPhoto),
        attach('video/*', strings.chat.attachVideo),
        attach('', strings.chat.attachFile),
      ),
      composer,
    ),
  );
  list.scrollTop = list.scrollHeight;
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
  const dialog = el('dialog', { class: 'sheet' });
  const apply = (action) => {
    state = transition(state, action);
    render();
  };
  const render = () => {
    const rows = (state.emojis ?? []).map((emoji) => {
      const glyph = Array.isArray(emoji) ? emoji[0] : emoji?.emoji;
      return el('li', {}, el('span', { class: 'emoji' }, glyph ?? ''), el('span', { class: 'meta' }, emojiLabel(emoji)));
    });
    dialog.replaceChildren(
      el('h2', {}, strings.verification.title),
      el('p', {}, strings.verification.intro),
      state.state === 'idle' ? el('button', { type: 'button', class: 'primary', onclick: start }, strings.verification.start) : null,
      state.state === 'ready'
        ? el(
            'div',
            {},
            el('p', { class: 'compare' }, strings.verification.compareHeading),
            el('ul', { class: 'emojis' }, rows),
            el(
              'div',
              { class: 'row gap' },
              el('button', { type: 'button', class: 'primary', onclick: () => confirmers?.confirm() }, strings.verification.same),
              el('button', { type: 'button', class: 'danger', onclick: () => confirmers?.mismatch() }, strings.verification.different),
            ),
          )
        : null,
      state.state === 'requested' || state.state === 'waiting'
        ? el('p', { class: 'empty' }, strings.verification.waiting)
        : null,
      state.state === 'matched' ? el('p', { class: 'status ok' }, strings.verification.done) : null,
      state.state === 'mismatched'
        ? el('div', {}, el('h3', {}, strings.verification.mismatchTitle), el('p', {}, strings.verification.mismatchBody))
        : null,
      state.state === 'cancelled' ? el('p', { class: 'empty' }, strings.verification.cancelled) : null,
      el('div', { class: 'row end' }, el('button', { type: 'button', class: 'secondary', onclick: close }, strings.verification.close)),
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
  const dialog = el('dialog', { class: 'sheet' });
  const render = () => {
    dialog.replaceChildren(
      el('h2', {}, strings.recovery.title),
      el('p', {}, strings.recovery.intro),
      el('p', { class: 'status warn' }, strings.recovery.showOnceHeading),
      el('p', {}, strings.recovery.showOnceBody),
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
            el('label', {}, strings.recovery.confirmLabel),
            el('input', { name: 'confirm', autocomplete: 'off', spellcheck: 'false' }),
            el('span', { class: 'feedback error' }),
            el('button', { class: 'primary', type: 'submit' }, strings.recovery.confirm),
          ),
      el('div', { class: 'row end' }, el('button', { type: 'button', class: 'secondary', onclick: close }, strings.verification.close)),
    );
  };
  root.append(dialog);
  dialog.showModal();
  render();
  return close;
}
