// DOM rendering. Views hold no business logic: they translate the pure
// modules in src/ into screens. All copy comes from src/strings.js and
// every text is inserted as a text node (no HTML injection).

import { strings } from './strings.js';
import { emojiLabel, transition } from './verification.js';
import { createRecoveryFlow } from './recovery.js';
import { composerKeyAction } from './keyboard.js';
import { canAccept } from './invites.js';
import { relativeTime } from './rooms.js';
import { humanFileSize } from './messages.js';

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
  (root.querySelector('.pane-list') ?? root.querySelector('main'))?.append(line);
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

function roomListItem(room, onSelect, active = false) {
  const agentCount = Array.isArray(room.agents) ? room.agents.length : 0;
  const last = room.lastMessage ?? null;
  const when = last
    ? relativeTime(last.ts, Date.now(), {
        justNow: strings.rooms.justNow,
        minutesAgo: strings.rooms.minutesAgo,
        hoursAgo: strings.rooms.hoursAgo,
        yesterday: strings.rooms.yesterday,
      })
    : '';
  return el(
    'li',
    {},
    el(
      'button',
      { type: 'button', class: 'room-item', 'aria-current': active ? 'true' : null, onclick: () => onSelect(room) },
      el('span', { class: `avatar kind-${room.kind}`, 'aria-hidden': 'true' }, initial(room.displayName || strings.rooms.unnamed)),
      el(
        'span',
        { class: 'texts' },
        el(
          'span',
          { class: 'room-head' },
          el('span', { class: 'room-name' }, room.displayName || strings.rooms.unnamed),
          agentCount > 0 ? el('span', { class: 'pill ai', title: strings.participants.aiTitle }, strings.participants.aiBadge) : null,
          when ? el('span', { class: 'when' }, when) : null,
        ),
        last
          ? el('span', { class: 'preview' }, last.sender ? el('span', { class: 'preview-sender' }, `${last.sender}: `) : null, last.text)
          : el('span', { class: 'preview empty-preview' }, `${roomBadge(room.kind)} · ${strings.rooms.memberCount(room.memberCount)} · ${strings.rooms.noMessages}`),
      ),
    ),
  );
}

/** Room list pane content (appbar, invites, rooms). */
function buildRoomList({ summaries, onSelect, syncState, onOpenVerification, onOpenRecovery, invites = [], inviteHandlers = null, currentRoomId = null, onToggleBox = null }) {
  const body = syncState === 'loading'
    ? el('p', { class: 'empty' }, strings.rooms.loading)
    : summaries.length === 0
      ? el('p', { class: 'empty' }, syncState === 'error' ? strings.rooms.syncError : strings.rooms.empty)
      : el('ul', { class: 'rooms' }, summaries.map((room) => roomListItem(room, onSelect, room.roomId === currentRoomId)));
  const inviteSection = inviteHandlers && invites.length > 0
    ? el(
        'section',
        { class: 'card invites', 'aria-label': strings.invite.title },
        el('h2', {}, strings.invite.title, el('span', { class: 'pill count' }, strings.invite.count(invites.length))),
        invites.map((invite) => inviteCard(invite, inviteHandlers)),
      )
    : null;
  return el(
    'aside',
    { class: 'pane pane-list rooms-screen', 'aria-label': strings.rooms.title },
    el(
      'header',
      { class: 'appbar' },
      el('div', { class: 'titles' }, el('h1', {}, strings.rooms.title), el('span', { class: 'subtitle' }, strings.appName)),
      el(
        'div',
        { class: 'tools' },
        el('button', { type: 'button', class: 'ghost', onclick: onOpenVerification }, strings.verification.title),
        el('button', { type: 'button', class: 'ghost', onclick: onOpenRecovery }, strings.recovery.title),
        onToggleBox ? el('button', { type: 'button', class: 'ghost box-toggle', onclick: onToggleBox }, strings.box.toggle) : null,
      ),
    ),
    syncState === 'error' && summaries.length > 0 ? el('p', { class: 'status warn', role: 'status' }, strings.rooms.syncError) : null,
    inviteSection,
    summaries.length > 0 ? el('p', { class: 'section-title' }, strings.rooms.listTitle) : null,
    body,
  );
}

/** Left pane only (mobile list screen). Kept for callers/tests; renderShell is the full layout. */
export function renderRoomList(root, props) {
  renderShell(root, { list: props, room: null });
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
    { class: `bubble kind-${entry.kind}`, 'data-me': entry.isMe ? 'true' : 'false', 'data-event-id': entry.eventId ?? null },
    entry.isMe ? null : el('span', { class: 'who' }, participantLabel(entry, entry)),
    el('p', { class: 'body' }, attach ? el('span', { class: 'attach-label' }, attach) : null, entry.body),
    foot.length > 0 ? el('span', { class: 'foot' }, foot.map((text, i) => (i > 0 ? ` · ${text}` : text))) : null,
  );
}

/** Pixels from the bottom within which the timeline counts as "at bottom". */
const NEAR_BOTTOM_PX = 48;

function isNearBottom(list) {
  return list.scrollHeight - list.scrollTop - list.clientHeight <= NEAR_BOTTOM_PX;
}

/**
 * Snapshot of the mounted room pane taken before a re-render: composer draft,
 * focus, and timeline scroll position (see scrollMode below).
 */
function snapshotRoomPane(root) {
  const previous = root.querySelector('.composer textarea[name=body]');
  const list = root.querySelector('.timeline');
  const firstBubble = list?.querySelector('li.bubble');
  return {
    roomId: root.querySelector('.room-screen')?.dataset.roomId ?? null,
    draft: previous?.value ?? '',
    hadFocus: previous != null && document.activeElement === previous,
    scrollTop: list?.scrollTop ?? 0,
    nearBottom: list ? isNearBottom(list) : true,
    count: list ? list.querySelectorAll('li.bubble').length : 0,
    firstEventId: firstBubble?.dataset.eventId ?? null,
    firstOffset: firstBubble ? firstBubble.offsetTop - list.offsetTop : 0,
  };
}

/**
 * Room pane content. Scroll rules (seo-chat #82 decision, adopted here):
 * opening a room → force bottom; new message while near the bottom → stay
 * at the bottom; new message while scrolled up → keep the position and show
 * a floating "새 메시지" badge that jumps down on click.
 */
function buildRoom({ room, timeline, onSend, onAttach, onBack, notice, onToggleBox = null, hasMore = false, loadingEarlier = false, onLoadEarlier = null }, snap) {
  // 맨 위 행: 이전 대화 불러오기 버튼 / 불러오는 중 / 대화의 처음.
  const earlierRow = el(
    'li',
    { class: 'load-earlier' },
    loadingEarlier
      ? el('span', { class: 'hint' }, strings.chat.historyLoading)
      : hasMore && onLoadEarlier
        ? el('button', { type: 'button', class: 'ghost', onclick: () => onLoadEarlier() }, strings.chat.loadEarlier)
        : timeline.length > 0 ? el('span', { class: 'hint' }, strings.chat.historyStart) : null,
  );
  const list = el(
    'ul',
    { class: 'timeline', 'aria-live': 'polite' },
    earlierRow,
    timeline.length === 0 && !loadingEarlier ? el('li', { class: 'empty' }, strings.chat.empty) : timeline.map(bubble),
  );
  // 맨 위 근처까지 올리면 자동으로 이전 페이지를 요청한다(한 번에 하나, main.js가 가드).
  if (hasMore && onLoadEarlier) {
    list.addEventListener('scroll', () => {
      if (list.scrollTop <= 40 && !loadingEarlier) onLoadEarlier();
    });
  }
  const badge = el(
    'button',
    {
      type: 'button',
      class: 'new-messages',
      hidden: true,
      onclick: () => {
        list.scrollTop = list.scrollHeight;
        badge.hidden = true;
      },
    },
    strings.chat.newMessages,
  );
  list.addEventListener('scroll', () => {
    if (isNearBottom(list)) badge.hidden = true;
  });
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
        // 먼저 비우고 나서 보낸다. onSend는 SDK 로컬 에코를 동기적으로 발행해 화면이
        // 즉시 다시 그려지는데, 그때 초안 보존이 아직 남아 있는 본문을 새 작성창으로 옮겨
        // "엔터를 쳐도 글이 안 사라지는" 회귀가 있었다(2026-09-17 실기기 관측).
        input.value = '';
        input.style.height = '';
        onSend(text);
        (document.querySelector('.composer textarea[name=body]') ?? input).focus();
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
  const pane = el(
    'section',
    { class: 'room-screen', 'data-room-id': room.roomId ?? '' },
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
      onToggleBox ? el('button', { type: 'button', class: 'icon ghost box-toggle', 'aria-label': strings.box.toggle, onclick: onToggleBox }, '📎') : null,
    ),
    notice ? el('p', { class: 'status error', role: 'alert' }, notice) : null,
    el('div', { class: 'timeline-wrap' }, list, badge),
    el('div', { class: 'composer-wrap' }, attachBar, composer),
  );
  const sameRoom = snap.roomId != null && snap.roomId === (room.roomId ?? '');
  const mount = () => {
    const input = composer.querySelector('textarea[name=body]');
    if (sameRoom && snap.draft) {
      input.value = snap.draft;
      input.style.height = 'auto';
      input.style.height = `${Math.min(input.scrollHeight, 160)}px`;
    }
    if (sameRoom && snap.hadFocus) {
      input.focus();
      const end = input.value.length;
      input.setSelectionRange(end, end);
    }
    // 앞에 붙은 이전 대화가 있으면(이전 첫 말풍선이 더 아래로 밀림) 보던 위치를 유지한다.
    const anchor = sameRoom && snap.firstEventId ? list.querySelector(`li.bubble[data-event-id="${CSS.escape(snap.firstEventId)}"]`) : null;
    const anchorIndex = anchor ? [...list.querySelectorAll('li.bubble')].indexOf(anchor) : -1;
    if (anchorIndex > 0) {
      list.scrollTop = (anchor.offsetTop - list.offsetTop) - snap.firstOffset + snap.scrollTop;
    } else if (!sameRoom || snap.nearBottom) {
      list.scrollTop = list.scrollHeight;
    } else {
      list.scrollTop = snap.scrollTop;
      if (timeline.length > snap.count) badge.hidden = false;
    }
  };
  return { pane, mount };
}

function fileRow(file, onOpen) {
  const foot = [
    file.size != null ? humanFileSize(file.size) : null,
    file.roomName || null,
    timeLabel(file.ts) || null,
  ].filter(Boolean);
  return el(
    'li',
    {},
    el(
      'button',
      { type: 'button', class: 'file-item', onclick: () => onOpen(file) },
      el('span', { class: `pill kind-${file.kind}` }, attachmentLabel(file.kind)),
      el(
        'span',
        { class: 'texts' },
        el('span', { class: 'file-name' }, file.name),
        el('span', { class: 'meta' }, foot.join(' · ')),
      ),
      el('span', { class: 'chevron', 'aria-hidden': 'true' }, '›'),
    ),
  );
}

/** Right pane: attachments across rooms + optional embedded filebox (config.json). */
function buildBox({ open, tab, attachments, filebox, onToggle, onTab, onRefresh, onOpen }) {
  const tabs = filebox
    ? el(
        'div',
        { class: 'box-tabs', role: 'tablist' },
        el('button', { type: 'button', role: 'tab', 'aria-selected': tab === 'attachments' ? 'true' : 'false', onclick: () => onTab('attachments') }, strings.box.tabAttachments),
        el('button', { type: 'button', role: 'tab', 'aria-selected': tab === 'filebox' ? 'true' : 'false', onclick: () => onTab('filebox') }, filebox.title),
      )
    : null;
  const body = tab === 'filebox' && filebox
    ? el(
        'div',
        { class: 'box-body filebox' },
        el(
          'div',
          { class: 'filebox-tools' },
          el('button', { type: 'button', class: 'secondary', onclick: onRefresh }, `🔄 ${strings.box.refresh}`),
          el('a', { class: 'button ghost', href: filebox.homeUrl, target: '_blank', rel: 'noopener noreferrer' }, strings.box.newWindow),
        ),
        el('p', { class: 'hint' }, strings.box.loginHint),
        el('div', { class: 'filebox-frame' }, el('iframe', { src: filebox.url, title: filebox.title, loading: 'lazy', referrerpolicy: 'strict-origin-when-cross-origin' })),
      )
    : el(
        'div',
        { class: 'box-body' },
        attachments.length === 0
          ? el('p', { class: 'empty' }, strings.box.empty)
          : el('ul', { class: 'files' }, attachments.map((file) => fileRow(file, onOpen))),
      );
  return el(
    'section',
    { class: 'pane pane-box', 'aria-label': strings.box.title, 'data-open': open ? 'true' : 'false' },
    el(
      'header',
      { class: 'appbar' },
      el('button', { type: 'button', class: 'icon ghost back', 'aria-label': strings.box.close, onclick: onToggle }, '←'),
      el('div', { class: 'titles' }, el('h2', {}, strings.box.title)),
    ),
    tabs,
    body,
  );
}

/** Wide layout (three columns) — the box pane is always visible there. */
function isWide() {
  return typeof window !== 'undefined' && typeof window.matchMedia === 'function' && window.matchMedia('(min-width: 1200px)').matches;
}

/**
 * Whole app layout after login: list pane + room pane (+ box pane). On phones one pane is
 * shown at a time (data-view); from 900px both are side by side.
 * `room` may be null (nothing selected → placeholder on desktop).
 */
export function renderShell(root, { list, room, box = null }) {
  const snap = snapshotRoomPane(root);
  root.replaceChildren();
  const onToggleBox = box ? box.onToggle : null;
  const listPane = buildRoomList({ ...list, currentRoomId: room?.room?.roomId ?? null, onToggleBox });
  let roomPane;
  let mount = null;
  if (room) {
    const built = buildRoom({ ...room, onToggleBox }, snap);
    roomPane = el('section', { class: 'pane pane-room' }, built.pane);
    mount = built.mount;
  } else {
    roomPane = el('section', { class: 'pane pane-room' }, el('p', { class: 'empty pane-empty' }, strings.rooms.selectHint));
  }
  const boxPane = box ? buildBox(box) : null;
  // 좁은 화면에서만 보관함이 별도 화면이 된다; 1200px부터는 세 번째 열로 항상 보인다.
  const view = box?.open && !isWide() ? 'box' : room ? 'room' : 'list';
  root.append(el('main', { class: 'shell', 'data-view': view }, listPane, roomPane, boxPane));
  mount?.();
}

/** Photo preview sheet for an attachment already fetched to an object URL. */
export function openPreviewSheet(root, { name, src, onClose }) {
  const dialog = el('dialog', { class: 'sheet preview', 'aria-label': strings.box.previewTitle });
  const close = () => dialog.close();
  dialog.addEventListener('close', () => {
    dialog.remove();
    onClose?.();
  });
  setChildren(
    dialog,
    el('h2', {}, name),
    el('img', { src, alt: name }),
    el('div', { class: 'row end' }, el('button', { type: 'button', class: 'ghost', onclick: close }, strings.verification.close)),
  );
  root.append(dialog);
  dialog.showModal();
  return close;
}

/** Chat pane only (mobile room screen). Kept for callers/tests; renderShell is the full layout. */
export function renderRoom(root, props) {
  renderShell(root, { list: { summaries: [], syncState: 'live', onSelect() {}, onOpenVerification() {}, onOpenRecovery() {} }, room: props });
}

/**
 * Device verification sheet.
 * `driver(callbacks)` starts the SDK SAS exchange; callbacks are
 * onEmojis(emojis, {confirm, mismatch}), onDone, onCancelled.
 */
export function openVerificationSheet(root, { driver, onClose, incoming = false }) {
  const close = () => dialog.close();
  let state = { state: 'idle' };
  let hint = null; // 'requested' while the other device still has to accept
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
      state.state === 'idle' && incoming
        ? el('div', { class: 'status' }, el('strong', {}, strings.verification.incomingTitle), el('br'), strings.verification.incomingBody)
        : null,
      state.state === 'idle'
        ? el('button', { type: 'button', class: 'primary block', onclick: start }, incoming ? strings.verification.acceptRequest : strings.verification.start)
        : null,
      state.state === 'ready'
        ? el(
            'div',
            { class: 'column' },
            el('p', { class: 'compare' }, strings.verification.compareHeading),
            el('ul', { class: 'emojis' }, rows),
            el(
              'div',
              { class: 'actions' },
              el(
                'button',
                {
                  type: 'button',
                  class: 'primary',
                  onclick: () => {
                    // ready → waiting(내가 확인) → matched(상대도 확인). 이전에는 accept 단계를
                    // 건너뛰어 confirm 전이가 거부되고 완료 화면이 뜨지 않았다.
                    apply({ type: 'accept' });
                    confirmers?.confirm();
                  },
                },
                strings.verification.same,
              ),
              el('button', { type: 'button', class: 'danger', onclick: () => confirmers?.mismatch() }, strings.verification.different),
            ),
          )
        : null,
      state.state === 'requested' || state.state === 'waiting'
        ? el('p', { class: 'status' }, hint === 'requested' ? strings.verification.requested : strings.verification.waiting)
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
      onRequested: () => {
        hint = 'requested';
        render();
      },
      onEmojis: (emojis, sdkConfirmers) => {
        hint = null;
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
