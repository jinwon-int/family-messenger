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
import { richMessageFragment } from './rich-text.js';
import { shortHandle } from './participants.js';

// 같은 방 재렌더에서 DOM을 갈아끼우지 않기 위한 렌더 서명(#194). 서명이 같으면 이미 붙어 있는
// 노드를 그대로 둔다 — 교체하면 크롬이 드래그·선택한 글자를 버리고, 호버가 한 프레임 꺼지고,
// 포커스가 body로 떨어지고, 보관함 iframe이 다시 로드된다.
const renderedSignature = new WeakMap();
/** Remembers what a freshly built node shows; returns the node. */
function signed(node, signature) {
  renderedSignature.set(node, signature);
  return node;
}
const signatureOf = (node) => (node ? renderedSignature.get(node) : undefined);
/** Timeline scroller behaviour that must follow the latest props even when the scroller is kept. */
const timelineProps = new WeakMap();

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

/**
 * Login screen. Calls onSubmit({homeserverUrl, user, password}).
 * defaults.homeserverUrl (deploy config / last login) pre-fills the server and
 * folds the field under an "advanced" disclosure; defaults.user pre-fills the id.
 */
export function renderLogin(root, { onSubmit, defaults = {} }) {
  root.replaceChildren();
  const homeserverDefault = typeof defaults.homeserverUrl === 'string' ? defaults.homeserverUrl : '';
  const userDefault = typeof defaults.user === 'string' ? defaults.user : '';
  const homeserverField = field(strings.login.homeserverLabel, { name: 'homeserverUrl', type: 'url', required: true, placeholder: strings.login.homeserverPlaceholder, autocomplete: 'url', inputmode: 'url', value: homeserverDefault || null });
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
    homeserverDefault
      ? el('details', { class: 'advanced' }, el('summary', {}, strings.login.homeserverAdvanced), homeserverField)
      : homeserverField,
    field(strings.login.userLabel, { name: 'user', required: true, autocomplete: 'username', placeholder: strings.login.userPlaceholder, autocapitalize: 'none', spellcheck: 'false', value: userDefault || null }),
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
  // 기본값이 채워졌으면 비어 있는 첫 칸(아이디 또는 비밀번호)에 커서를 둔다.
  const firstEmpty = [...form.querySelectorAll('input')].find((input) => !input.value && !input.closest('details'));
  firstEmpty?.focus();
}

/** Inline status line inside the current main element. */
export function setStatus(root, message, tone = 'info') {
  // 자기가 붙인 줄만 지운다. 목록 pane은 재렌더에도 유지되므로(#194) 첫 .status를 지우면
  // 암호화 실패 배너·동기화 경고가 다시 그려지지 않고 사라진다.
  root.querySelector('.status[data-transient]')?.remove();
  if (!message) return;
  const line = el('p', { class: `status ${tone}`, role: 'status', 'data-transient': true }, message);
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
  const signature = JSON.stringify([
    room.roomId, active, room.kind, room.displayName, room.typing || '', agentCount, when, room.memberCount,
    last ? [room.kind === 'family' ? last.sender ?? '' : '', last.text] : null,
  ]);
  return signed(el(
    'li',
    { 'data-room-id': room.roomId },
    el(
      'button',
      { type: 'button', class: 'room-item', 'data-room-id': room.roomId, 'aria-current': active ? 'true' : null, onclick: (event) => onSelect(room, event) },
      el('span', { class: `avatar kind-${room.kind}`, 'aria-hidden': 'true' }, initial(room.displayName || strings.rooms.unnamed)),
      el(
        'span',
        { class: 'texts' },
        el(
          'span',
          { class: 'room-head' },
          el('span', { class: 'room-name' }, room.displayName || strings.rooms.unnamed),
          // 이름 옆 "입력중.." — 다른 방의 입력도 보이므로 방별 typing 라벨(main.js가 계산).
          room.typing ? el('span', { class: 'typing', role: 'status' }, room.typing) : null,
          agentCount > 0 ? el('span', { class: 'pill ai', title: strings.participants.aiTitle }, strings.participants.aiBadge) : null,
          when ? el('span', { class: 'when' }, when) : null,
        ),
        last
          ? el('span', { class: 'preview' }, room.kind === 'family' && last.sender ? el('span', { class: 'preview-sender' }, `${last.sender}: `) : null, last.text)
          : el('span', { class: 'preview empty-preview' }, `${roomBadge(room.kind)} · ${strings.rooms.memberCount(room.memberCount)} · ${strings.rooms.noMessages}`),
      ),
    ),
  ), signature);
}

/** Room list pane content (appbar, invites, rooms). */
function buildRoomList({ summaries, onSelect, syncState, onOpenVerification, onOpenRecovery, onOpenMenu = null, invites = [], inviteHandlers = null, currentRoomId = null, onToggleBox = null, banner = null }) {
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
  // 방 항목을 뺀 목록 pane의 틀. 같으면 pane을 두고 방 항목만 맞춘다(reconcileRoomList).
  const frame = JSON.stringify([
    syncState, banner ?? '', summaries.length > 0, Boolean(onToggleBox),
    inviteHandlers ? invites.map((invite) => [invite, inviteHandlers.isAiConsentAcknowledged(invite)]) : null,
  ]);
  return signed(el(
    'aside',
    { class: 'pane pane-list rooms-screen', 'aria-label': strings.rooms.title },
    el(
      'header',
      { class: 'appbar' },
      el('div', { class: 'titles' }, el('h1', {}, strings.rooms.title), el('span', { class: 'subtitle' }, strings.appName)),
      el(
        'div',
        { class: 'tools' },
        onToggleBox ? el('button', { type: 'button', class: 'ghost box-toggle', onclick: onToggleBox }, strings.box.toggle) : null,
        el('button', { type: 'button', class: 'ghost', 'aria-label': strings.menu.open, onclick: onOpenMenu ?? onOpenVerification }, `⚙ ${strings.menu.open}`),
      ),
    ),
    banner ? el('p', { class: 'status error banner', role: 'alert' }, banner) : null,
    syncState === 'error' && summaries.length > 0 ? el('p', { class: 'status warn', role: 'status' }, strings.rooms.syncError) : null,
    inviteSection,
    summaries.length > 0 ? el('p', { class: 'section-title' }, strings.rooms.listTitle) : null,
    body,
  ), frame);
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

function photoPreview(attachment, previews, onOpen) {
  if (attachment?.kind !== 'photo' || !previews) return null;
  const preview = previews.get(attachment);
  if (preview?.status === 'ready') {
    return el('button', { type: 'button', class: 'photo-preview', 'aria-label': `${strings.box.previewTitle}: ${attachment.name}`, onclick: () => onOpen?.(attachment) },
      el('img', { src: preview.src, alt: attachment.name, onerror: () => previews.fail(attachment) }));
  }
  return el('div', { class: 'photo-preview' }, preview?.status === 'error'
    ? el('button', { type: 'button', class: 'photo-retry', onclick: () => previews.retry(attachment) }, strings.media.photoFailed)
    : el('span', { role: 'status' }, strings.box.loading));
}

function bubble(entry, photoPreviews, onOpenAttachment) {
  const attach = attachmentLabel(entry.kind);
  const rich = ['text', 'notice'].includes(entry.kind) ? richMessageFragment(entry.formattedBody) : null;
  const time = timeLabel(entry.ts);
  const foot = [entry.meta, time].filter(Boolean);
  const preview = entry.attachment?.kind === 'photo' && photoPreviews ? photoPreviews.get(entry.attachment) : null;
  // 화면에 보이는 것 전부. 같으면 붙어 있는 말풍선을 그대로 둔다(선택·사진 img 유지).
  const signature = JSON.stringify([
    entry.eventId ?? null, entry.kind, Boolean(entry.isMe), Boolean(entry.isProgress), Boolean(entry.isAgent),
    entry.name ?? null, entry.userId ?? null, entry.body ?? '', entry.formattedBody ?? null, foot,
    entry.attachment ?? null, preview ? [preview.status ?? null, preview.src ?? null] : null,
  ]);
  return signed(el(
    'li',
    { class: `bubble kind-${entry.kind}${entry.isProgress ? ' is-progress' : ''}`, 'data-me': entry.isMe ? 'true' : 'false', 'data-event-id': entry.eventId ?? null },
    entry.isMe ? null : el('span', { class: 'who' }, participantLabel(entry, entry)),
    el('div', { class: rich ? 'body rich-text' : 'body' }, photoPreview(entry.attachment, photoPreviews, onOpenAttachment), attach ? el('span', { class: 'attach-label' }, attach) : null, rich ?? entry.body),
    foot.length > 0 ? el('span', { class: 'foot' }, foot.map((text, i) => (i > 0 ? ` · ${text}` : text))) : null,
  ), signature);
}

/** Pixels from the bottom within which the timeline counts as "at bottom". */
const NEAR_BOTTOM_PX = 48;

function isNearBottom(list) {
  return list.scrollHeight - list.scrollTop - list.clientHeight <= NEAR_BOTTOM_PX;
}

/** Reconcile key of a timeline row: bubbles by event id, the two fixed rows by role. */
function timelineKey(node) {
  if (node.classList.contains('load-earlier')) return 'earlier';
  if (node.classList.contains('empty')) return 'empty';
  const id = node.dataset?.eventId;
  return id ? `event:${id}` : null;
}

/**
 * Make `parent`'s children equal `desired` (freshly built, unmounted) while keeping every
 * mounted child whose key and render signature match — it is moved at most, never rebuilt.
 * Rows that changed are replaced one by one; rows that vanished are removed.
 * @returns {Element[]} the children now mounted, in order
 */
function reconcileChildren(parent, desired, keyOf, { patch = null } = {}) {
  const mounted = new Map();
  for (const child of [...parent.children]) {
    const key = keyOf(child);
    if (key != null && !mounted.has(key)) mounted.set(key, child);
  }
  const next = desired.map((fresh) => {
    const key = keyOf(fresh);
    const old = key == null ? null : mounted.get(key);
    const same = old && signatureOf(old) !== undefined && signatureOf(old) === signatureOf(fresh);
    if (same) return old;
    // 바뀌었지만 노드 자체는 남겨야 하는 행(진행 말풍선)은 안쪽만 갈아끼운다.
    if (old && patch?.(old, fresh)) {
      renderedSignature.set(old, signatureOf(fresh));
      return old;
    }
    return fresh;
  });
  let previous = null;
  for (const node of next) {
    const expected = previous ? previous.nextSibling : parent.firstChild;
    if (expected !== node) parent.insertBefore(node, expected);
    previous = node;
  }
  while (previous ? previous.nextSibling : parent.firstChild) (previous ? previous.nextSibling : parent.firstChild).remove();
  return next;
}

/** Rewrite a mounted progress bubble in place from a freshly built one (same slot, new text or id). */
function patchProgressBubble(old, fresh) {
  if (!old.classList.contains('is-progress') || !fresh.classList.contains('is-progress')) return false;
  old.className = fresh.className;
  for (const name of ['data-event-id', 'data-me']) {
    if (fresh.hasAttribute(name)) old.setAttribute(name, fresh.getAttribute(name));
    else old.removeAttribute(name);
  }
  setChildren(old, [...fresh.childNodes]);
  return true;
}

/** First bubble whose bottom edge is below the scroller's top — the one the reader is looking at. */
function firstVisibleBubble(list) {
  const top = list.scrollTop + list.offsetTop;
  for (const node of list.querySelectorAll('li.bubble')) {
    if (node.offsetTop + node.offsetHeight > top) return node;
  }
  return null;
}

/**
 * Same room, kept scroller: bring the timeline rows up to date without replacing the scroller
 * (#194 — the old code swapped the whole .timeline-wrap, dropping selections and scroll state).
 * Scroll rules match buildRoom: near the bottom stays pinned by the height delta (#184), a
 * scrolled-up reader keeps the bubble they were looking at in place, and new messages below
 * show the floating badge.
 */
function updateTimeline(oldWrap, fresh, { count }) {
  const list = oldWrap.querySelector('.timeline');
  const freshList = fresh.querySelector('.timeline');
  const badge = oldWrap.querySelector('.new-messages');
  const near = isNearBottom(list);
  const top = list.scrollTop;
  const height = list.scrollHeight;
  const anchor = near ? null : firstVisibleBubble(list);
  const anchorOffset = anchor ? anchor.offsetTop : 0;
  const before = new Set(list.querySelectorAll('li.bubble'));
  // 진행 말풍선은 event id가 아니라 자리(n번째)로 맞춘다. 하트비트 편집·삭제 후 재게시는 id가
  // 바뀌어도 같은 말풍선이며, 노드를 바꾸면 사이에 높이가 줄었다 늘어난다(#181·#184).
  const keys = new Map();
  const assignKeys = (nodes) => {
    let progress = 0;
    for (const node of nodes) keys.set(node, node.classList.contains('is-progress') ? `progress:${progress++}` : timelineKey(node));
  };
  const desired = [...freshList.children];
  assignKeys([...list.children]);
  assignKeys(desired);
  reconcileChildren(list, desired, (node) => keys.get(node) ?? null, { patch: patchProgressBubble });
  timelineProps.set(list, timelineProps.get(freshList));
  if (near) {
    list.scrollTop = top + (list.scrollHeight - height);
  } else if (anchor && anchor.isConnected) {
    list.scrollTop = top + (anchor.offsetTop - anchorOffset);
  } else {
    list.scrollTop = top;
  }
  const added = [...list.querySelectorAll('li.bubble')].some((node) => !before.has(node));
  if (!near && added && list.querySelectorAll('li.bubble').length > count && badge) badge.hidden = false;
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
function buildRoom({ room, timeline, onSend, onAttach, photoPreviews = null, onOpenAttachment = null, onTyping = null, onBack, notice, onToggleBox = null, hasMore = false, loadingEarlier = false, onLoadEarlier = null, typing = '' }, snap) {
  // 맨 위 행: 이전 대화 불러오기 버튼 / 불러오는 중 / 대화의 처음.
  const earlierMode = loadingEarlier ? 'loading' : hasMore && onLoadEarlier ? 'button' : timeline.length > 0 ? 'start' : 'none';
  const earlierRow = signed(el(
    'li',
    { class: 'load-earlier' },
    earlierMode === 'loading'
      ? el('span', { class: 'hint' }, strings.chat.historyLoading)
      : earlierMode === 'button'
        // 유지된 행에서도 최신 콜백을 부른다(timelineProps).
        ? el('button', { type: 'button', class: 'ghost', onclick: () => timelineProps.get(list)?.onLoadEarlier?.() }, strings.chat.loadEarlier)
        : earlierMode === 'start' ? el('span', { class: 'hint' }, strings.chat.historyStart) : null,
  ), earlierMode);
  const list = el(
    'ul',
    { class: 'timeline', 'aria-live': 'polite' },
    earlierRow,
    timeline.length === 0 && !loadingEarlier ? signed(el('li', { class: 'empty' }, strings.chat.empty), 'empty') : timeline.map((entry) => bubble(entry, photoPreviews, onOpenAttachment)),
  );
  // 스크롤러는 같은 방 재렌더에서 유지된다(updateTimeline) — 리스너는 만들 때의 값이 아니라
  // 가장 최근 렌더의 값을 읽어야 한다.
  timelineProps.set(list, { hasMore, loadingEarlier, onLoadEarlier });
  // 맨 위 근처까지 올리면 자동으로 이전 페이지를 요청한다(한 번에 하나, main.js가 가드).
  list.addEventListener('scroll', () => {
    const props = timelineProps.get(list);
    if (props?.hasMore && props.onLoadEarlier && !props.loadingEarlier && list.scrollTop <= 40) props.onLoadEarlier();
  });
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
        // 입력 활동을 알린다(main.js가 서버 타이핑 알림으로 변환 — m.typing).
        // 프로그램적 input 이벤트(초안 복원 등)는 실제 타이핑이 아니므로 isTrusted로 걸러낸다.
        if (event.isTrusted) onTyping?.(input.value.trim().length > 0);
      },
    }),
    el('button', { type: 'submit', class: 'primary' }, strings.chat.send),
  );
  const header = signed(el(
    'header',
    { class: 'appbar' },
    el('button', { type: 'button', class: 'icon ghost back', 'aria-label': strings.chat.back, onclick: onBack }, '←'),
    el(
      'div',
      { class: 'titles' },
      el(
        'div',
        { class: 'title-row' },
        el('h2', {}, room.displayName || strings.rooms.unnamed),
        // 이름 옆 "…님이 입력중입니다" — main.js가 typingNames로 채운다. 빈 문자열이면 숨긴다.
        typing ? el('span', { class: 'typing', role: 'status' }, typing) : null,
      ),
      el('span', { class: 'subtitle lock' }, `${roomBadge(room.kind)} · ${strings.rooms.memberCount(room.memberCount)} · ${strings.chat.encryptedShort}`),
    ),
    onToggleBox ? el('button', { type: 'button', class: 'icon ghost box-toggle', 'aria-label': strings.box.toggle, onclick: onToggleBox }, '📎') : null,
  ), JSON.stringify([room.displayName, typing || '', room.kind, room.memberCount, Boolean(onToggleBox)]));
  const noticeNode = notice ? signed(el('p', { class: 'status error', role: 'alert' }, notice), notice) : null;
  const timelineWrap = el('div', { class: 'timeline-wrap' }, list, badge);
  const composerWrap = el('div', { class: 'composer-wrap' }, attachBar, composer);
  const pane = el('section', { class: 'room-screen', 'data-room-id': room.roomId ?? '' }, header, noticeNode, timelineWrap, composerWrap);
  const sameRoom = snap.roomId != null && snap.roomId === (room.roomId ?? '');
  /** keepComposer: the existing composer stays in the DOM (incremental update) — don't touch draft/focus. */
  const mount = ({ keepComposer = false } = {}) => {
    const input = composer.querySelector('textarea[name=body]');
    if (!keepComposer && sameRoom && snap.draft) {
      input.value = snap.draft;
      input.style.height = 'auto';
      input.style.height = `${Math.min(input.scrollHeight, 160)}px`;
    }
    if (!keepComposer && sameRoom && snap.hadFocus) {
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
  return { pane, mount, parts: { header, notice: noticeNode, timelineWrap, composerWrap } };
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
  // 파일보관함 탭은 iframe이다 — 서명이 같으면 pane을 유지해 다시 로드하지 않는다(#194).
  // 새로고침 버튼은 url(refresh 카운터)을 바꿔 교체를 일으킨다.
  const signature = JSON.stringify([
    open, tab, filebox ? [filebox.url, filebox.homeUrl, filebox.title] : null,
    tab === 'filebox' && filebox ? null : attachments.map((file) => [file.kind, file.name, file.size ?? null, file.roomName ?? null, timeLabel(file.ts), file.url ?? null]),
  ]);
  return signed(el(
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
  ), signature);
}

/** Wide layout (three columns) — the box pane is always visible there. */
function isWide() {
  return typeof window !== 'undefined' && typeof window.matchMedia === 'function' && window.matchMedia('(min-width: 1200px)').matches;
}

/** List pane: keep it when its frame is unchanged and reconcile only the room rows. */
function updateListPane(shell, fresh) {
  const old = shell.querySelector(':scope > .pane-list');
  if (!old) {
    shell.prepend(fresh);
    return;
  }
  const oldRooms = old.querySelector('ul.rooms');
  const freshRooms = fresh.querySelector('ul.rooms');
  if (signatureOf(old) !== signatureOf(fresh) || !oldRooms || !freshRooms) {
    old.replaceWith(fresh);
    return;
  }
  reconcileChildren(oldRooms, [...freshRooms.children], (node) => (node.dataset?.roomId ? `room:${node.dataset.roomId}` : null));
}

/** Box pane: keep it (and the filebox iframe) unless what it shows changed. */
function updateBoxPane(shell, fresh) {
  const old = shell.querySelector(':scope > .pane-box');
  if (old && fresh) {
    if (signatureOf(old) !== signatureOf(fresh)) old.replaceWith(fresh);
  } else if (fresh) shell.append(fresh);
  else old?.remove();
}

/**
 * Whole app layout after login: list pane + room pane (+ box pane). On phones one pane is
 * shown at a time (data-view); from 900px both are side by side.
 * `room` may be null (nothing selected → placeholder on desktop).
 */
export function renderShell(root, { list, room, box = null }) {
  const snap = snapshotRoomPane(root);
  const onToggleBox = box ? box.onToggle : null;
  // 좁은 화면에서만 보관함이 별도 화면이 된다; 1200px부터는 세 번째 열로 항상 보인다.
  const view = box?.open && !isWide() ? 'box' : room ? 'room' : 'list';
  const listPane = buildRoomList({ ...list, currentRoomId: room?.room?.roomId ?? null, onToggleBox });

  // 같은 방을 다시 그릴 때는 작성창(composer-wrap)을 절대 교체하지 않는다 — 요소를 새로 만들어
  // value를 다시 넣으면 한글 IME 조합이 끊겨 "내가"가 "ㄴㅐㄱㅏ"로 깨지고 화면이 깜빡였다
  // (2026-09-17 실기기). 목록·헤더·타임라인·보관함만 부분 교체한다.
  const existingShell = root.querySelector('main.shell');
  const existingScreen = existingShell?.querySelector('.room-screen') ?? null;
  const sameRoom = Boolean(room && existingScreen && existingScreen.dataset.roomId === (room.room.roomId ?? ''));
  if (existingShell && sameRoom && existingScreen.querySelector('.composer-wrap')) {
    // 같은 방: 붙어 있는 노드를 유지하고 바뀐 것만 맞춘다(#194). 통째 교체는 드래그·선택한 글자,
    // 호버, 목록 포커스, 스크롤 관성, 보관함 iframe을 매번 날렸다.
    const built = buildRoom({ ...room, onToggleBox }, snap);
    updateListPane(existingShell, listPane);
    const oldHeader = existingScreen.querySelector(':scope > header.appbar');
    if (oldHeader && signatureOf(oldHeader) !== signatureOf(built.parts.header)) oldHeader.replaceWith(built.parts.header);
    const oldWrap = existingScreen.querySelector(':scope > .timeline-wrap');
    const oldNotice = existingScreen.querySelector(':scope > .status');
    if (signatureOf(oldNotice) !== signatureOf(built.parts.notice ?? undefined)) {
      oldNotice?.remove();
      if (built.parts.notice) existingScreen.insertBefore(built.parts.notice, oldWrap);
    }
    if (oldWrap?.querySelector('.timeline')) updateTimeline(oldWrap, built.parts.timelineWrap, { count: snap.count });
    else {
      oldWrap?.replaceWith(built.parts.timelineWrap);
      built.mount({ keepComposer: true });
    }
    updateBoxPane(existingShell, box ? buildBox(box) : null);
    existingShell.dataset.view = view;
    return;
  }
  // 방을 열지 않은 목록 화면도 같은 방식으로 목록·보관함만 맞춘다(목록 호버·포커스 유지).
  if (existingShell && !room && !existingScreen && existingShell.querySelector(':scope > .pane-room')) {
    updateListPane(existingShell, listPane);
    updateBoxPane(existingShell, box ? buildBox(box) : null);
    existingShell.dataset.view = view;
    return;
  }

  // 전체 재구성은 열려 있는 시트(<dialog open>)를 건드리면 안 된다 — 지우면 시트가 사라지고,
  // 떼었다 다시 붙이면 top layer(모달)에서 빠져 첨부 카드처럼 화면 아래에 인라인으로 깔린다
  // (2026-09-17 실기기: 목록 화면에서 2초 갱신마다 기기 검증 시트가 "첨부처럼" 떴다).
  // 그래서 main.shell만 제자리에서 교체하고 시트는 손대지 않는다.
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
  if (existingShell) {
    // 방 전환(소교 → 육손 등)·목록↔방: 방 pane만 새로 만들고, 목록은 바뀐 항목만, 보관함은
    // 제자리에 둔다. 보관함은 방과 무관한데 shell을 통째 바꾸면 파일보관함 iframe이 다시
    // 로드됐다(#194 후속). iframe은 떼었다 붙여도 다시 로드되므로 옮기지 않고 형제만 바꾼다.
    updateListPane(existingShell, listPane);
    const oldRoomPane = existingShell.querySelector(':scope > .pane-room');
    if (oldRoomPane) oldRoomPane.replaceWith(roomPane);
    else existingShell.querySelector(':scope > .pane-list')?.after(roomPane);
    updateBoxPane(existingShell, boxPane);
    existingShell.dataset.view = view;
  } else {
    const shell = el('main', { class: 'shell', 'data-view': view }, listPane, roomPane, boxPane);
    // 로그인 화면 등 다른 내용은 걷어내되 열린 시트는 그대로 둔다.
    for (const child of [...root.children]) if (!(child.tagName === 'DIALOG' && child.open)) child.remove();
    root.prepend(shell);
  }
  mount?.();
}

/** Settings menu sheet: a vertical list of actions. items: [{label, onClick, danger?}]. */
export function openMenuSheet(root, { items, onClose }) {
  const dialog = el('dialog', { class: 'sheet menu', 'aria-label': strings.menu.title });
  const close = () => dialog.close();
  dialog.addEventListener('close', () => {
    dialog.remove();
    onClose?.();
  });
  setChildren(
    dialog,
    el('h2', {}, strings.menu.title),
    el(
      'div',
      { class: 'menu-items' },
      items.map((item) =>
        el(
          'button',
          {
            type: 'button',
            class: item.danger ? 'danger block' : 'block',
            onclick: () => {
              close();
              item.onClick();
            },
          },
          item.label,
        ),
      ),
    ),
    el('div', { class: 'row end' }, el('button', { type: 'button', class: 'ghost', onclick: close }, strings.verification.close)),
  );
  root.append(dialog);
  dialog.showModal();
  return close;
}

function deviceWhen(ts) {
  if (!Number.isFinite(ts) || ts <= 0) return strings.account.neverSeen;
  try {
    return strings.account.lastSeen(new Intl.DateTimeFormat('ko-KR', { month: 'numeric', day: 'numeric', hour: 'numeric', minute: '2-digit' }).format(new Date(ts)));
  } catch {
    return '';
  }
}

/**
 * Device management sheet: list my sessions with signing status, delete the
 * selected ones after a password re-check (user-interactive auth).
 * load() → devices[], remove(ids, password) → {deleted}.
 */
export function openDevicesSheet(root, { load, remove, onClose }) {
  const dialog = el('dialog', { class: 'sheet devices', 'aria-labelledby': 'devices-title' });
  const close = () => dialog.close();
  dialog.addEventListener('close', () => {
    dialog.remove();
    onClose?.();
  });
  let devices = null;
  let selected = new Set();
  let status = null; // {tone, text}
  let busy = false;
  const render = () => {
    const rows = (devices ?? []).map((device) =>
      el(
        'li',
        { class: 'device-item' },
        el('input', {
          type: 'checkbox',
          disabled: device.isCurrent || busy ? true : null,
          checked: selected.has(device.deviceId) || null,
          'aria-label': device.deviceId,
          onchange: (event) => {
            if (event.target.checked) selected.add(device.deviceId);
            else selected.delete(device.deviceId);
            render();
          },
        }),
        el(
          'span',
          { class: 'texts' },
          el(
            'span',
            { class: 'device-head' },
            el('span', { class: 'device-name' }, device.displayName || device.deviceId),
            device.isCurrent ? el('span', { class: 'pill you' }, strings.account.thisDevice) : null,
            device.crossSigned === true
              ? el('span', { class: 'pill kind-family' }, strings.account.signed)
              : device.crossSigned === false
                ? el('span', { class: 'pill warn' }, strings.account.unsigned)
                : el('span', { class: 'pill' }, strings.account.unknownSigning),
          ),
          el('span', { class: 'meta' }, `${device.deviceId} · ${deviceWhen(device.lastSeenTs)}${device.lastSeenIp ? ` · ${device.lastSeenIp}` : ''}`),
        ),
      ),
    );
    const form = el(
      'form',
      {
        class: 'column',
        onsubmit: async (event) => {
          event.preventDefault();
          const password = form.querySelector('input[name=password]').value;
          const ids = [...selected];
          if (ids.length === 0 || busy) return;
          busy = true;
          status = null;
          render();
          try {
            const result = await remove(ids, password);
            status = { tone: 'ok', text: strings.account.deleteDone(result.deleted.length) };
            selected = new Set();
            devices = await load();
          } catch (error) {
            console.error('device delete failed', error);
            status = { tone: 'error', text: strings.account.deleteFailed };
          } finally {
            busy = false;
            render();
          }
        },
      },
      field(strings.account.passwordLabel, { name: 'password', type: 'password', autocomplete: 'current-password', placeholder: strings.account.passwordPlaceholder, required: true }),
      el('button', { type: 'submit', class: 'danger block', disabled: selected.size === 0 || busy ? true : null }, strings.account.deleteSelected(selected.size)),
    );
    setChildren(
      dialog,
      el('h2', { id: 'devices-title' }, strings.account.devicesTitle),
      el('p', { class: 'hint' }, strings.account.devicesIntro),
      status ? el('p', { class: `status ${status.tone}`, role: 'status' }, status.text) : null,
      devices == null
        ? el('p', { class: 'empty' }, strings.account.devicesLoading)
        : devices.length === 0
          ? el('p', { class: 'empty' }, strings.account.devicesEmpty)
          : el('ul', { class: 'devices' }, rows),
      devices && devices.some((d) => !d.isCurrent) ? form : null,
      el(
        'div',
        { class: 'row end' },
        el('button', { type: 'button', class: 'ghost', disabled: busy ? true : null, onclick: async () => { devices = null; render(); devices = await load(); render(); } }, strings.account.refresh),
        el('button', { type: 'button', class: 'ghost', onclick: close }, strings.verification.close),
      ),
    );
  };
  root.append(dialog);
  dialog.showModal();
  render();
  load().then((list) => { devices = list; render(); }).catch((error) => {
    console.error('device list failed', error);
    devices = [];
    status = { tone: 'error', text: strings.errors.generic };
    render();
  });
  return close;
}

/**
 * 알림 켜기/끄기 시트.
 *
 * `load()`가 src/push.js의 pushAvailability 문자열을 돌려주고, 이 함수는 그것을
 * 화면으로 옮기기만 한다(판단은 전부 순수 모듈에 있다).
 * `enable()`/`disable()`은 `{ok, reason}`을 돌려준다.
 *
 * 로그인 직후 권한 팝업을 띄우지 않는다 — 거절당하면 브라우저 설정에서 손대야
 * 해서 회복이 어렵다. 여기 버튼을 누르는 것이 유일한 요청 시점이다.
 */
export function openNotificationsSheet(root, { load, enable, disable, onClose }) {
  const dialog = el('dialog', { class: 'sheet notifications', 'aria-labelledby': 'notifications-title' });
  const close = () => dialog.close();
  dialog.addEventListener('close', () => {
    dialog.remove();
    onClose?.();
  });
  let availability = null; // null이면 아직 읽는 중
  let status = null; // {tone, text}
  let busy = false;

  const run = async (action, failureText) => {
    if (busy) return;
    busy = true;
    status = null;
    render();
    try {
      const result = await action();
      if (result?.ok) {
        status = null;
      } else {
        status = { tone: 'error', text: result?.reason === 'no-permission' ? strings.notifications.permissionRefused : failureText };
      }
    } catch (error) {
      console.error('notification toggle failed', error);
      status = { tone: 'error', text: failureText };
    }
    // ⚠ load()를 finally에 두면 그것이 던질 때 render()가 영영 안 불려
    //    버튼이 "처리 중…"으로 고정된다(openDevicesSheet는 try 안에 둔다).
    try {
      availability = await load();
    } catch (error) {
      console.error('notification state failed', error);
    }
    busy = false;
    render();
  };

  const render = () => {
    const body = [];
    if (availability === null) {
      body.push(el('p', { class: 'empty' }, strings.notifications.working));
    } else if (availability === 'not-configured') {
      body.push(el('p', { class: 'hint' }, strings.notifications.notConfigured));
    } else if (availability === 'unsupported') {
      body.push(el('p', { class: 'hint' }, strings.notifications.unsupported));
    } else if (availability === 'ios-needs-install') {
      body.push(
        el('p', { class: 'hint' }, strings.notifications.iosSteps),
        el('p', { class: 'status error', role: 'status' }, strings.notifications.iosOrder),
      );
    } else if (availability === 'denied' || availability === 'denied-ios') {
      // iOS 홈화면 앱에는 주소창도 사이트 권한 메뉴도 없다 — 다른 경로를 알려준다.
      body.push(el('p', { class: 'status error', role: 'status' }, availability === 'denied-ios' ? strings.notifications.deniedIos : strings.notifications.denied));
    } else if (availability === 'on') {
      body.push(
        el('p', { class: 'hint' }, strings.notifications.on),
        el('button', {
          type: 'button',
          class: 'ghost block',
          disabled: busy ? true : null,
          onclick: () => run(disable, strings.notifications.disableFailed),
        }, busy ? strings.notifications.working : strings.notifications.disable),
      );
    } else {
      body.push(
        el('p', { class: 'hint' }, strings.notifications.off),
        el('button', {
          type: 'button',
          class: 'block',
          disabled: busy ? true : null,
          onclick: () => run(enable, strings.notifications.enableFailed),
        }, busy ? strings.notifications.working : strings.notifications.enable),
      );
    }
    setChildren(
      dialog,
      el('h2', { id: 'notifications-title' }, availability === 'ios-needs-install' ? strings.notifications.iosTitle : strings.notifications.title),
      // 켤 수 없는 상태에서는 "앱을 닫아도 알려줍니다" 바로 밑에 "지원하지
      // 않습니다"가 붙어 서로 어긋난다 — 켜고 끌 수 있을 때만 보여준다.
      availability === 'off' || availability === 'on' ? el('p', { class: 'hint' }, strings.notifications.intro) : null,
      status ? el('p', { class: `status ${status.tone}`, role: 'status' }, status.text) : null,
      ...body,
      el('div', { class: 'row end' }, el('button', { type: 'button', class: 'ghost', onclick: close }, strings.verification.close)),
    );
  };

  root.append(dialog);
  dialog.showModal();
  render();
  Promise.resolve(load()).then((value) => { availability = value; render(); }).catch((error) => {
    console.error('notification state failed', error);
    availability = 'unsupported';
    render();
  });
  return close;
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
  let request = null; // SDK VerificationRequest once the driver created/accepted one
  let cancelInfo = null; // '사유: m.user · 취소한 쪽: @…' once the SDK tells us why
  const dialog = el('dialog', { class: 'sheet', 'aria-labelledby': 'verify-title' });
  dialog.addEventListener('close', () => {
    // 시트를 닫으면 상대 기기가 시간 초과까지 기다리지 않도록 진행 중인 요청을 취소한다.
    if (!['matched', 'mismatched', 'cancelled', 'idle'].includes(state.state)) {
      try {
        request?.cancel?.();
      } catch {
        /* best-effort: the other device times out on its own */
      }
    }
    dialog.remove();
    onClose?.();
  });
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
      state.state === 'cancelled'
        ? el('p', { class: 'status warn' }, strings.verification.cancelled, cancelInfo ? el('br') : null, cancelInfo ? el('small', {}, cancelInfo) : null)
        : null,
      el('div', { class: 'row end' }, el('button', { type: 'button', class: 'ghost', onclick: close }, strings.verification.close)),
    );
  };
  const start = () => {
    apply({ type: 'request' });
    driver({
      onRequest: (sdkRequest) => {
        request = sdkRequest;
      },
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
      onCancelled: (reason) => {
        if (reason && (reason.code || reason.by || reason.message)) {
          cancelInfo = strings.verification.cancelDetail(reason.code || reason.message, shortHandle(reason.by || ''));
        }
        apply({ type: 'cancel' });
      },
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
