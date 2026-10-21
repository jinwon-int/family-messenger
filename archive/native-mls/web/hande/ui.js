// 한데(hande) 웹 화면 — 평범한 DOM(el 빌더), 프레임워크 없음. 문구는 전부 strings.js, 글은 텍스트 노드로만 넣는다.
// 패밀리챗 web/app/src/ui.js 의 구조(목록 pane | 방 pane, 같은 방 재렌더에서 작성창을 교체하지 않는 규칙)를 옮기고
// 모닥불 팔레트로 다시 입혔다. 업무 로직 없음: app.js 가 넘긴 props 를 그리고 콜백만 부른다.

import {
  strings, ACTOR, ROOM, DEVICE, formatTime, dayLabel, dayKey, groupFingerprint, displayName, humanSize,
} from './strings.js';
import {imageType, downloadSpec} from './attachment-view.js';
import {fileboxRefreshUrl} from './filebox.js';
import {parseBlocks, inlineSpans, hasMarkdown} from './agent-markdown.js';

// ---- DOM 도우미 ----

/** 같은 방 재렌더에서 바뀌지 않은 노드를 그대로 두기 위한 렌더 서명(패밀리챗 #194). */
const renderedSignature = new WeakMap();
const signed = (node, signature) => { renderedSignature.set(node, signature); return node; };
const signatureOf = (node) => (node ? renderedSignature.get(node) : undefined);
/** 유지되는 작성창·타임라인이 최신 콜백을 쓰게 하는 props 저장소. */
const liveProps = new WeakMap();

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

function setChildren(node, ...children) {
  node.replaceChildren(...children.flat(Infinity).filter((child) => child != null && child !== false));
}

/** 열린 시트(<dialog open>)와 상태 토스트는 남기고 화면을 비운다 — 시트는 떼었다 붙이면 top layer 에서 빠진다. */
function clearScreen(root) {
  for (const child of [...root.children]) {
    if (child.tagName === 'DIALOG' && child.open) continue;
    if (child.dataset?.testid === 'status') continue;
    child.remove();
  }
}

function field(labelText, inputAttrs, hint = null) {
  const id = `f-${inputAttrs.name}`;
  return el('div', { class: 'field' },
    el('label', { for: id }, labelText),
    el('input', { id, autocapitalize: 'none', autocorrect: 'off', spellcheck: 'false', 'aria-describedby': hint ? `${id}-hint` : null, ...inputAttrs }),
    hint ? el('p', { class: 'hint', id: `${id}-hint` }, hint) : null);
}

const brand = (size = 'l') => el('div', { class: `brand brand-${size}` },
  el('span', { class: 'wordmark', 'aria-label': strings.appName }, strings.wordmark),
  el('span', { class: 'subtitle' }, strings.subtitle));

const fingerprintNode = (hex) => el('code', { class: 'fingerprint', 'aria-label': strings.enroll.fingerprintLabel }, groupFingerprint(hex));

const fact = (label, value, mono = false) => el('div', { class: 'fact' }, el('dt', {}, label), el('dd', { class: mono ? 'mono' : null }, value));

async function copyText(text) {
  try { await navigator.clipboard.writeText(text); return true; } catch { return false; }
}

/** 「복사」 버튼: 누르면 잠깐 "복사했습니다"로 바뀐다. copy 는 Promise<boolean>|void 를 돌려주는 함수. */
function copyButton(copy, label = strings.copy) {
  const button = el('button', { type: 'button', class: 'ghost small', onclick: async () => {
    const ok = await copy();
    button.textContent = ok === false ? strings.app.copyFailed : strings.app.copied;
    setTimeout(() => { button.textContent = label; }, 1800);
  } }, label);
  return button;
}

const statusLine = (text, tone = 'info', extra = {}) => (text ? el('p', { class: `status ${tone}`, role: tone === 'danger' ? 'alert' : 'status', ...extra }, text) : null);

// ---- 시작·이름·치명 오류·등록 화면 ----

export function renderActorSetup(root, { onSubmit, error = null, busy = false }) {
  clearScreen(root);
  const feedback = el('p', { class: 'feedback', role: 'alert' }, error ?? '');
  const form = el('form', { class: 'column', onsubmit: (event) => {
    event.preventDefault();
    const value = form.querySelector('input[name=actor]').value.trim().toLowerCase();
    if (!ACTOR.test(value)) { feedback.textContent = strings.actor.invalid; return; }
    feedback.textContent = '';
    onSubmit(value);
  } },
    field(strings.actor.field, { name: 'actor', required: true, placeholder: 'mom', autocomplete: 'off', inputmode: 'latin', maxlength: '16', disabled: busy || null, 'data-testid': 'actor-input' }, strings.actor.hint),
    feedback,
    el('button', { type: 'submit', class: 'primary block', disabled: busy || null, 'data-testid': 'actor-submit' }, busy ? strings.actor.busy : strings.actor.button));
  root.append(el('main', { class: 'center' }, el('section', { class: 'card hero', 'aria-labelledby': 'actor-title' },
    brand(), el('h1', { id: 'actor-title' }, strings.actor.title), form)));
  form.querySelector('input')?.focus();
}

export function renderStarting(root, { message = strings.app.starting }) {
  clearScreen(root);
  root.append(el('main', { class: 'center' }, el('section', { class: 'card hero starting', role: 'status', 'aria-live': 'polite' },
    brand(), el('div', { class: 'spinner', 'aria-hidden': 'true' }), el('p', { class: 'hint' }, message))));
}

export function renderFatal(root, { title = strings.fatal.title, detail = '', onRetry = null, onWipe = null }) {
  clearScreen(root);
  root.append(el('main', { class: 'center' }, el('section', { class: 'card hero', role: 'alert' },
    brand('s'), el('h1', {}, title), detail ? el('pre', { class: 'detail' }, detail) : null,
    el('div', { class: 'actions' },
      onRetry ? el('button', { type: 'button', class: 'primary', onclick: onRetry }, strings.fatal.retry) : null,
      onWipe ? el('button', { type: 'button', class: 'danger', onclick: onWipe }, strings.fatal.wipe) : null))));
}

export function renderEnroll(root, { deviceId, actor, fingerprint, subject = null, registrationJson = '', waiting = false, lastCheckedAt = null, onCopy, onCheck, onOpenApprove = null, onWipe, error = null }) {
  const frame = JSON.stringify([deviceId, actor, fingerprint, subject, registrationJson, error, Boolean(onOpenApprove)]);
  const statusText = waiting ? strings.enroll.waiting : strings.enroll.notWaiting;
  const checked = lastCheckedAt ? strings.enroll.lastChecked(lastCheckedAt) : '';
  const existing = root.querySelector('section.enroll');
  if (existing && signatureOf(existing) === frame) {
    // 폴링 재렌더: 선택한 지문·JSON 을 지키려고 상태 줄만 바꾼다.
    const line = existing.querySelector('.enroll-status');
    line.className = `status enroll-status ${waiting ? 'warn' : 'info'}`;
    setChildren(line, statusText, checked ? el('span', { class: 'meta' }, ` · ${checked}`) : null);
    liveProps.set(existing, { onCopy, onCheck, onOpenApprove, onWipe });
    return;
  }
  clearScreen(root);
  const card = el('section', { class: 'card enroll', 'aria-labelledby': 'enroll-title' });
  liveProps.set(card, { onCopy, onCheck, onOpenApprove, onWipe });
  const live = () => liveProps.get(card);
  setChildren(card,
    brand('s'),
    el('h1', { id: 'enroll-title' }, strings.enroll.title),
    el('p', { class: 'hint' }, strings.enroll.body),
    el('dl', { class: 'facts' },
      fact(strings.enroll.deviceIdLabel, deviceId, true),
      fact(strings.enroll.actorLabel, actor),
      fact(strings.enroll.subjectLabel, subject || el('span', { class: 'meta' }, strings.enroll.subjectUnknown), Boolean(subject)),
      fact(strings.enroll.fingerprintLabel, fingerprintNode(fingerprint))),
    el('p', { class: `status enroll-status ${waiting ? 'warn' : 'info'}`, role: 'status' }, statusText, checked ? el('span', { class: 'meta' }, ` · ${checked}`) : null),
    el('div', { class: 'json-block' },
      el('div', { class: 'row between' }, el('span', { class: 'label' }, strings.enroll.registrationLabel), copyButton(() => live().onCopy?.(), strings.enroll.copyRegistration)),
      el('pre', { class: 'json', tabindex: '0' }, registrationJson)),
    statusLine(error, 'danger'),
    el('div', { class: 'actions wrap' },
      el('button', { type: 'button', class: 'primary', onclick: () => live().onCheck?.() }, strings.enroll.checkNow),
      onOpenApprove ? el('button', { type: 'button', class: 'secondary', onclick: () => live().onOpenApprove?.() }, strings.enroll.openApprove) : null,
      el('button', { type: 'button', class: 'ghost danger-text', onclick: () => live().onWipe?.() }, strings.enroll.wipe)));
  root.append(el('main', { class: 'center' }, signed(card, frame)));
}

/** 항상 DOM 에 있는 상태 토스트([data-testid="status"]). 화면 교체에도 살아남는다(clearScreen). */
function ensureToast(root) {
  let toast = root.querySelector(':scope > [data-testid="status"]');
  if (!toast) {
    toast = el('p', { class: 'status toast', role: 'status', 'aria-live': 'polite', 'data-testid': 'status', hidden: true });
    root.append(toast);
  }
  return toast;
}
const TOAST_MS = 8000;
const toastTimers = new WeakMap();

/** 일시 상태줄(토스트). message 가 비면 지운다; 아니면 8초 뒤 스스로 지운다. */
export function setStatus(root, message, tone = 'info') {
  const toast = ensureToast(root);
  clearTimeout(toastTimers.get(toast));
  toast.className = `status toast ${tone}`;
  toast.textContent = message ?? '';
  toast.hidden = !message;
  if (message) toastTimers.set(toast, setTimeout(() => { toast.textContent = ''; toast.hidden = true; }, TOAST_MS));
}

// ---- 목록 pane ----

const STATE_LABEL = { pending: strings.rooms.pending, halted: strings.rooms.halted, closed: strings.rooms.closed };

function roomListItem(room, onSelect, active) {
  const out = room.state === 'halted' || room.state === 'closed';
  const emoji = room.emoji || (out ? '🪵' : '🔥');
  const preview = room.preview || (out ? strings.rooms.closedPreview : strings.rooms.noMessages);
  const signature = JSON.stringify([room.roomId, room.name, emoji, preview, room.time, Boolean(room.unread), room.state, Boolean(room.hasAgent), room.members ?? 0, active]);
  const classes = ['room-item', `state-${room.state}`, room.unread && !out ? 'unread' : '', room.hasAgent && !out ? 'bright' : ''].filter(Boolean).join(' ');
  return signed(el('li', { 'data-key': room.roomId },
    el('button', { type: 'button', class: classes, 'data-room-id': room.roomId, 'data-testid': 'room-item', 'data-state': room.state, 'data-members': String(room.members ?? 0), 'aria-current': active ? 'true' : null, onclick: () => onSelect(room.roomId) },
      el('span', { class: 'fire', 'aria-hidden': 'true' }, emoji),
      el('span', { class: 'texts' },
        el('span', { class: 'room-head' },
          el('span', { class: 'room-name' }, room.name || room.roomId),
          room.hasAgent && !out ? el('span', { class: 'pill agent' }, strings.rooms.agentBadge) : null,
          STATE_LABEL[room.state] ? el('span', { class: `pill state-${room.state}` }, STATE_LABEL[room.state]) : null,
          room.time ? el('span', { class: 'when' }, room.time) : null),
        el('span', { class: 'preview' }, preview)),
      room.unread && !out ? el('span', { class: 'ember-dot' }, el('span', { class: 'visually-hidden' }, strings.rooms.unreadLabel)) : null)), signature);
}

/** 머리 도구 버튼(아이콘 + 접근성 이름 + 툴팁). 바로 눌리게 팝오버 없이 둔다. */
const toolButton = (icon, label, testid, onClick, extraClass = '') => el('button', { type: 'button', class: `icon ghost tool ${extraClass}`.trim(), 'aria-label': label, title: label, 'data-testid': testid, onclick: () => onClick?.() }, icon);

function syncText(sync) {
  if (!sync) return '';
  if (sync.reconnecting) return strings.sync.reconnecting;
  if (sync.offlineSince) return strings.sync.offline(sync.offlineSince);
  if (sync.lastSyncAt) return strings.sync.synced(sync.lastSyncAt);
  return strings.sync.never;
}

/** 로비 초대 카드(#431 4단계): 운영자/봇이 로비 키로 보낸 새 대화방 Welcome — 수락 1탭 또는 무시. */
function inviteCard(invite) {
  return el('li', { class: 'invite-item', 'data-testid': 'lobby-invite', 'data-room-id': invite.room },
    el('p', { class: 'invite-head' }, el('span', { class: 'fire', 'aria-hidden': 'true' }, '🔥'), el('strong', {}, invite.name || invite.room)),
    el('p', { class: 'hint' }, strings.lobby.inviteBody(invite.name || invite.room)),
    invite.message ? el('p', { class: 'feedback', role: 'alert' }, invite.message) : null,
    el('div', { class: 'actions' },
      el('button', { type: 'button', class: 'primary', 'data-testid': 'invite-accept', disabled: invite.busy ? 'disabled' : null, onclick: () => invite.onAccept?.() }, strings.lobby.accept),
      el('button', { type: 'button', class: 'ghost', 'data-testid': 'invite-ignore', disabled: invite.busy ? 'disabled' : null, onclick: () => invite.onIgnore?.() }, strings.lobby.ignore)));
}

function buildRoomList({ rooms = [], currentRoomId = null, onSelect, onOpenMenu, onOpenJoin, onOpenCreate, onOpenBox = null, sync = null, notice = null, deviceLabel = '', invites = [] }) {
  const syncLabel = syncText(sync);
  const syncTone = sync?.reconnecting ? 'warn' : sync?.offlineSince ? 'danger' : 'ok';
  const frame = JSON.stringify([syncLabel, syncTone, notice ? [notice.text, notice.tone] : null, rooms.length > 0, deviceLabel, Boolean(onOpenBox), invites.map((i) => [i.room, i.name ?? null, i.message ?? null, Boolean(i.busy)])]);
  const body = rooms.length === 0
    ? el('div', { class: 'empty campfire-empty' }, el('span', { class: 'big-fire', 'aria-hidden': 'true' }, '🪵'), el('p', { class: 'empty-title' }, strings.rooms.empty), el('p', { class: 'hint' }, strings.rooms.noRooms))
    : el('ul', { class: 'rooms', 'aria-label': strings.rooms.listLabel }, rooms.map((room) => roomListItem(room, onSelect, room.roomId === currentRoomId)));
  return signed(el('aside', { class: 'pane pane-list', 'aria-label': strings.rooms.title, 'data-testid': 'room-list' },
    el('header', { class: 'appbar' },
      brand('s'),
      el('div', { class: 'tools', role: 'group', 'aria-label': strings.rooms.actions },
        toolButton('🔑', strings.rooms.join, 'open-join', onOpenJoin),
        toolButton('🔥', strings.rooms.create, 'open-create', onOpenCreate),
        onOpenBox ? toolButton('🗂', strings.box.toggle, 'open-box', onOpenBox) : null,
        toolButton('⚙', strings.rooms.settings, 'open-menu', onOpenMenu))),
    el('p', { class: `sync-line ${syncTone}`, role: 'status' }, el('span', { class: 'dot', 'aria-hidden': 'true' }), syncLabel),
    notice ? el('div', { class: `status ${notice.tone || 'info'} notice`, role: notice.tone === 'danger' ? 'alert' : 'status' },
      el('span', {}, notice.text),
      notice.onClose ? el('button', { type: 'button', class: 'ghost small', 'aria-label': strings.close, onclick: notice.onClose }, '✕') : null) : null,
    invites.length > 0 ? el('section', { class: 'card invites', 'aria-label': strings.lobby.inviteSectionTitle },
      el('h2', { class: 'section-title' }, strings.lobby.inviteSectionTitle),
      el('ul', { class: 'invite-list' }, invites.map(inviteCard))) : null,
    body,
    el('p', { class: 'device-line meta' }, el('span', { class: 'label' }, strings.rooms.deviceLabel, ' '), el('span', { class: 'mono', 'data-testid': 'device-label' }, deviceLabel))), frame);
}

/**
 * parent 의 자식을 desired(새로 만든, 미부착)와 같게 맞추되 key·서명이 같은 부착 노드는 옮기기만 한다.
 * @returns {Element[]} 부착된 순서대로
 */
function reconcileChildren(parent, desired, keyOf) {
  const mounted = new Map();
  for (const child of [...parent.children]) {
    const key = keyOf(child);
    if (key != null && !mounted.has(key)) mounted.set(key, child);
  }
  const next = desired.map((fresh) => {
    const old = mounted.get(keyOf(fresh));
    return old && signatureOf(old) !== undefined && signatureOf(old) === signatureOf(fresh) ? old : fresh;
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

const keyOfRow = (node) => node.dataset?.key ?? null;

function updateListPane(shell, fresh) {
  const old = shell.querySelector(':scope > .pane-list');
  if (!old) { shell.prepend(fresh); return; }
  const oldRooms = old.querySelector('ul.rooms');
  const freshRooms = fresh.querySelector('ul.rooms');
  if (signatureOf(old) !== signatureOf(fresh) || !oldRooms || !freshRooms) {
    old.replaceWith(fresh);
    return;
  }
  reconcileChildren(oldRooms, [...freshRooms.children], keyOfRow);
}

// ---- 방 pane ----

const NEAR_BOTTOM_PX = 48;
const isNearBottom = (list) => list.scrollHeight - list.scrollTop - list.clientHeight <= NEAR_BOTTOM_PX;

function firstVisibleRow(list) {
  const top = list.scrollTop + list.offsetTop;
  for (const node of list.children) if (node.offsetTop + node.offsetHeight > top) return node;
  return null;
}

/** 첨부 본체를 받아 저장한다(blob 링크). 내용으로 판별된 이미지는 attachment-<seq>.jpg 등 + 그 MIME,
 *  나머지는 attachment-<seq>.bin + 불활성 MIME(attachment-view.js downloadSpec). */
async function downloadAttachment(entry, button, onOpenAttachment) {
  const label = button.textContent;
  button.disabled = true;
  button.textContent = strings.chat.downloading;
  try {
    const bytes = await onOpenAttachment(entry);
    const {name, type} = downloadSpec(entry.seq, entry.image?.type ?? imageType(bytes));
    const url = URL.createObjectURL(new Blob([bytes], { type }));
    const link = el('a', { href: url, download: name, hidden: true });
    document.body.append(link);
    link.click();
    link.remove();
    setTimeout(() => URL.revokeObjectURL(url), 10_000);
    button.textContent = label;
  } catch (error) {
    console.error('attachment download failed', error);
    button.textContent = strings.chat.downloadFailed;
    setTimeout(() => { button.textContent = label; }, 2500);
  } finally {
    button.disabled = false;
  }
}

// ---- 에이전트 답장 마크다운(iOS #405 와 같은 블록 규칙) ----
// agent-markdown.js 가 돌려준 문자열을 el() 로만 넣는다 — 전부 텍스트 노드, innerHTML·링크 이동·원격 이미지 없음.

// 굵게·기울임·취소선 안쪽은 다시 나눈다(**`코드` 굵게**). 한 겹마다 기호 2자 이상이 줄어 깊이는 글 길이로 묶인다.
const inlineNodes = (text) => inlineSpans(text).map((span) => {
  if (span.style === 'text') return span.text;
  return el(span.style, {}, span.style === 'code' ? span.text : inlineNodes(span.text));
});

function markdownBlock(block) {
  switch (block.type) {
    case 'heading': {
      const level = Math.min(block.level, 3);
      return el('p', { class: `md-h md-h${level}`, role: 'heading', 'aria-level': String(level + 2) }, inlineNodes(block.text));
    }
    case 'list':
      return el('ul', { class: 'md-list' }, block.items.map((item) => el('li', { class: `md-lvl-${item.level}` },
        el('span', { class: 'md-marker', 'aria-hidden': 'true' }, item.marker ?? '•'),
        el('span', { class: 'md-item' }, inlineNodes(item.text)))));
    case 'table':
      return el('div', { class: 'md-table' }, el('table', {},
        el('thead', {}, el('tr', {}, block.header.map((cell) => el('th', { scope: 'col' }, inlineNodes(cell))))),
        el('tbody', {}, block.rows.map((row) => el('tr', {}, row.map((cell) => el('td', {}, inlineNodes(cell))))))));
    case 'code':
      return el('pre', { class: 'md-code' }, el('code', {}, block.text));
    case 'quote':
      return el('blockquote', { class: 'md-quote' }, inlineNodes(block.text));
    case 'rule':
      return el('hr', { class: 'md-rule' });
    default:
      return el('p', { class: 'md-p' }, inlineNodes(block.text));
  }
}

function agentMarkdownBody(text) {
  return el('div', { class: 'body md', 'data-testid': 'agent-markdown' }, parseBlocks(text).map(markdownBlock));
}

function bubble(entry, onOpenAttachment) {
  const time = formatTime(entry.ts);
  const signature = JSON.stringify([entry.key, entry.kind, Boolean(entry.isMe), Boolean(entry.isAgent), entry.senderName ?? null, entry.body ?? '', time, entry.size ?? null, entry.image?.url ?? null, Boolean(entry.replay), entry.seq ?? null]);
  if (entry.kind === 'system') {
    return signed(el('li', { class: 'system', 'data-key': entry.key, 'data-testid': 'system-row' }, el('span', { class: 'body' }, entry.body), time ? el('span', { class: 'foot' }, time) : null), signature);
  }
  let body;
  if (entry.kind === 'undecryptable') body = el('div', { class: 'body' }, strings.chat.undecryptable);
  else if (entry.kind === 'attachment') {
    const download = onOpenAttachment
      ? el('button', { type: 'button', class: 'ghost small download', onclick: (event) => downloadAttachment(entry, event.currentTarget, onOpenAttachment) }, strings.chat.download)
      : null;
    body = entry.image
      ? el('div', { class: 'body media' },
          el('button', { type: 'button', class: 'media-open', title: strings.chat.viewImage, 'aria-label': strings.chat.viewImage, onclick: () => openImageViewer(entry) },
            el('img', { src: entry.image.url, alt: entry.image.alt || strings.chat.image, loading: 'lazy' })),
          download)
      : el('div', { class: 'body file' }, el('span', { class: 'file-label' }, strings.chat.file(humanSize(entry.size ?? 0))), download);
  } else if (entry.isAgent && entry.kind === 'text' && hasMarkdown(entry.body)) body = agentMarkdownBody(entry.body);
  else body = el('div', { class: 'body' }, entry.body);
  const foot = [entry.replay ? strings.chat.replay : null, time].filter(Boolean).join(' · ');
  return signed(el('li', { class: `bubble kind-${entry.kind}${entry.isAgent ? ' agent' : ''}`, 'data-key': entry.key, 'data-me': entry.isMe ? 'true' : 'false', 'data-testid': entry.kind === 'undecryptable' ? 'system-row' : 'bubble' },
    entry.isMe ? null : el('span', { class: 'who' }, entry.senderName || displayName(entry.sender)),
    body,
    foot ? el('span', { class: 'foot' }, foot) : null), signature);
}

function timelineRows(timeline, onOpenAttachment) {
  const rows = [];
  let day = '';
  for (const entry of timeline) {
    const key = dayKey(entry.ts);
    if (key && key !== day) {
      day = key;
      rows.push(signed(el('li', { class: 'day-divider', 'data-key': `day:${key}`, role: 'separator' }, el('span', {}, dayLabel(entry.ts))), key));
    }
    rows.push(bubble(entry, onOpenAttachment));
  }
  return rows;
}

/** 같은 방, 유지된 스크롤러: 행만 맞추고 스크롤 규칙(내 글 → 맨 아래, 아래 근처 → 따라감, 위에서 읽는 중 → 자리 유지 + 배지)을 적용. */
function updateTimeline(oldWrap, freshWrap) {
  const list = oldWrap.querySelector('.timeline');
  const freshList = freshWrap.querySelector('.timeline');
  const badge = oldWrap.querySelector('.new-messages');
  const near = isNearBottom(list);
  const top = list.scrollTop;
  const height = list.scrollHeight;
  const anchor = near ? null : firstVisibleRow(list);
  const anchorOffset = anchor ? anchor.offsetTop : 0;
  const before = new Set(list.children);
  reconcileChildren(list, [...freshList.children], keyOfRow);
  const added = [...list.children].filter((node) => !before.has(node));
  const ownAdded = added.some((node) => node.dataset.me === 'true');
  if (ownAdded) list.scrollTop = list.scrollHeight;
  else if (near) list.scrollTop = top + (list.scrollHeight - height);
  else if (anchor?.isConnected) list.scrollTop = top + (anchor.offsetTop - anchorOffset);
  else list.scrollTop = top;
  if (!near && !ownAdded && added.some((node) => node.classList.contains('bubble')) && badge) badge.hidden = false;
}

function snapshotRoomPane(root) {
  const textarea = root.querySelector('.composer textarea[name=body]');
  return {
    roomId: root.querySelector('.room-screen')?.dataset.roomId ?? null,
    hadFocus: textarea != null && document.activeElement === textarea,
  };
}

const isWide = () => typeof window.matchMedia === 'function' && window.matchMedia('(min-width: 900px)').matches;

/** 작성창 활성 상태를 제자리에서 맞춘다 — textarea 를 바꾸지 않는다(한글 IME). */
function applyComposerState(form, { enabled, sending }) {
  const textarea = form.querySelector('textarea');
  const placeholder = enabled ? strings.chat.placeholder : strings.chat.placeholderDisabled;
  if (textarea.disabled !== !enabled) textarea.disabled = !enabled;
  if (textarea.placeholder !== placeholder) { textarea.placeholder = placeholder; textarea.setAttribute('aria-label', placeholder); }
  form.querySelector('.attach').disabled = !enabled;
  const send = form.querySelector('.send');
  send.disabled = !enabled || Boolean(sending);
  // Enter 의 requestSubmit() 은 비활성 보내기 버튼을 거치지 않으므로 submit 핸들러가 이 표식을 본다(#478).
  if (sending) form.dataset.sending = 'true'; else delete form.dataset.sending;
  const label = sending ? strings.chat.sending : strings.chat.send;
  if (send.textContent !== label) send.textContent = label;
}

/** 작성창 높이를 내용에 맞춘다(최대 160px). */
function autosize(textarea) {
  textarea.style.height = 'auto';
  textarea.style.height = `${Math.min(textarea.scrollHeight, 160)}px`;
}

function buildComposer(room) {
  const fileInput = el('input', { type: 'file', hidden: true, tabindex: '-1', 'aria-hidden': 'true', onchange: () => {
    const file = fileInput.files?.[0];
    if (file) liveProps.get(form)?.onAttach?.(file);
    fileInput.value = '';
  } });
  const textarea = el('textarea', {
    name: 'body', rows: '1', autocomplete: 'off', enterkeyhint: 'send', placeholder: strings.chat.placeholder, 'aria-label': strings.chat.placeholder, 'data-testid': 'composer',
    onkeydown: (event) => {
      // Enter 전송, Shift+Enter 줄바꿈. IME 조합을 확정하는 Enter(isComposing / keyCode 229)는 그대로 둔다.
      if (event.key !== 'Enter' || event.shiftKey || event.isComposing || event.keyCode === 229) return;
      event.preventDefault();
      form.requestSubmit();
    },
    oninput: (event) => {
      autosize(textarea);
      if (event.isTrusted) liveProps.get(form)?.onDraft?.(textarea.value);
    },
  });
  const form = el('form', { class: 'composer', onsubmit: (event) => {
    event.preventDefault();
    const text = textarea.value;
    if (textarea.disabled || text.trim().length === 0) { textarea.focus(); return; }
    // 보내는 중의 Enter 는 글을 그대로 둔다 — 예전에는 먼저 비운 뒤 app 의 sending 가드에 걸려 글이 사라졌다(#478).
    if (form.dataset.sending === 'true') { textarea.focus(); return; }
    // 먼저 비우고 보낸다 — onSend 가 동기 재렌더를 일으켜도 초안이 되살아나지 않게(패밀리챗 2026-09-17).
    textarea.value = '';
    textarea.style.height = '';
    const props = liveProps.get(form);
    props?.onDraft?.('');
    const result = props?.onSend?.(text);
    textarea.focus();
    // 전송이 거절·실패(false)하면 글을 되살린다(room.js send 계약: 실패하면 호출자가 초안을 지킨다).
    // 그 사이 더 쓴 글이 있으면 보낸 글 뒤에 이어 붙인다.
    Promise.resolve(result).then((ok) => {
      if (ok !== false || !textarea.isConnected) return;
      const typed = textarea.value;
      textarea.value = typed ? `${text}\n${typed}` : text;
      autosize(textarea);
      liveProps.get(form)?.onDraft?.(textarea.value);
    }).catch(() => {});
  } },
    el('button', { type: 'button', class: 'icon ghost attach', 'aria-label': strings.chat.attach, title: strings.chat.attachHint, onclick: () => fileInput.click() }, '📎'),
    fileInput, textarea,
    el('button', { type: 'submit', class: 'primary send' }, strings.chat.send));
  liveProps.set(form, room);
  return form;
}

function haltBanner(room) {
  const halted = room.halted;
  if (halted) {
    const detail = strings.halt.detail(halted.seq, halted.committer, halted.at);
    return signed(el('div', { class: 'halt-banner', role: 'alert', 'data-part': 'gate' },
      el('strong', {}, strings.halt.title),
      el('p', {}, strings.halt.bannerBody(halted.reason, { removed: Boolean(halted.removed) })),
      halted.detail ? el('p', { class: 'meta' }, halted.detail) : null,
      el('p', { class: 'meta mono' }, `${strings.halt.reasonLabel}: ${halted.removed ? 'removed_from_room' : halted.reason || '—'}${detail ? ` · ${detail}` : ''}`)),
    JSON.stringify(['halt', halted]));
  }
  if (!room.joined) return signed(el('p', { class: 'status warn', role: 'status', 'data-part': 'gate' }, strings.chat.notJoined), 'not-joined');
  return null;
}

function resendBar(pending) {
  if (!pending) return null;
  const size = humanSize(pending.size ?? 0);
  return signed(el('div', { class: 'resend-bar status warn', role: 'status', 'data-part': 'resend' },
    el('span', {}, el('strong', {}, strings.chat.resendTitle), ' ', strings.chat.resendBody(size)),
    el('button', { type: 'button', class: 'secondary small', onclick: () => pending.onRetry?.() }, strings.chat.resend)), `resend:${size}`);
}

/** 방 pane. parts 는 재렌더에서 따로따로 맞춘다(patchRoomScreen). */
function buildRoom(room) {
  const canCompose = Boolean(room.joined) && !room.halted;
  const members = Array.isArray(room.members) ? room.members : [];
  const header = signed(el('header', { class: 'appbar', 'data-part': 'header' },
    el('button', { type: 'button', class: 'icon ghost back', 'aria-label': strings.chat.back, onclick: () => liveProps.get(screen)?.onBack?.() }, '←'),
    el('div', { class: 'titles' },
      el('h2', {}, el('span', { class: 'fire', 'aria-hidden': 'true' }, room.halted ? '🪵' : '🔥'), ' ', room.name || room.roomId),
      el('span', { class: 'subtitle' }, strings.chat.members(members.length))),
    el('div', { class: 'tools' },
      room.onOpenBox ? el('button', { type: 'button', class: 'ghost small box-toggle', 'data-testid': 'open-box', 'aria-label': strings.box.toggle, onclick: () => liveProps.get(screen)?.onOpenBox?.() }, '🗂') : null,
      el('button', { type: 'button', class: 'ghost small', onclick: () => liveProps.get(screen)?.onOpenMembers?.() }, strings.chat.membersButton),
      el('button', { type: 'button', class: 'secondary small', 'data-testid': 'open-invite', disabled: room.joined ? null : true, onclick: () => liveProps.get(screen)?.onOpenInvite?.() }, strings.chat.invite))),
  JSON.stringify([room.name, room.roomId, members.length, Boolean(room.halted), Boolean(room.joined), Boolean(room.onOpenBox)]));
  const notice = room.notice?.text ? signed(el('p', { class: `status ${room.notice.tone || 'info'}`, role: 'status', 'data-part': 'notice' }, room.notice.text), JSON.stringify(room.notice)) : null;
  const list = el('ul', { class: 'timeline', tabindex: '-1', 'aria-live': 'polite', 'aria-label': strings.chat.timelineLabel, 'data-testid': 'timeline' },
    room.timeline.length === 0 ? signed(el('li', { class: 'empty', 'data-key': 'empty' }, strings.chat.empty), 'empty') : timelineRows(room.timeline, room.onOpenAttachment));
  const badge = el('button', { type: 'button', class: 'new-messages', hidden: true, onclick: () => { list.scrollTop = list.scrollHeight; badge.hidden = true; } }, strings.chat.newMessages);
  list.addEventListener('scroll', () => { if (isNearBottom(list)) badge.hidden = true; });
  const timelineWrap = el('div', { class: 'timeline-wrap', 'data-part': 'timeline' }, list, badge);
  const composer = buildComposer(room);
  applyComposerState(composer, { enabled: canCompose, sending: room.sending });
  const composerWrap = el('div', { class: 'composer-wrap', 'data-part': 'composer' }, composer);
  const parts = { header, notice, gate: haltBanner(room), timeline: timelineWrap, resend: resendBar(room.attachmentPending), composer: composerWrap };
  const screen = el('section', { class: 'room-screen', 'data-room-id': room.roomId }, Object.values(parts));
  liveProps.set(screen, room);
  const mount = ({ focus }) => {
    const textarea = composer.querySelector('textarea');
    textarea.value = room.draft ?? '';
    if (textarea.value) { textarea.style.height = 'auto'; textarea.style.height = `${Math.min(textarea.scrollHeight, 160)}px`; }
    list.scrollTop = list.scrollHeight;
    if (focus && canCompose) { textarea.focus(); textarea.setSelectionRange(textarea.value.length, textarea.value.length); }
  };
  return { screen, parts, mount, canCompose };
}

const PART_ORDER = ['header', 'notice', 'gate', 'timeline', 'resend', 'composer'];

/** 같은 방 재렌더: 작성창은 절대 교체하지 않고(IME), 타임라인은 행만 맞추고, 나머지는 서명이 바뀐 것만 교체. */
function patchRoomScreen(screen, built, room) {
  liveProps.set(screen, room);
  for (const name of PART_ORDER) {
    const fresh = built.parts[name];
    const old = screen.querySelector(`:scope > [data-part="${name}"]`);
    if (name === 'timeline' && old) { updateTimeline(old, fresh); continue; }
    if (name === 'composer' && old) {
      const form = old.querySelector('form.composer');
      liveProps.set(form, room);
      applyComposerState(form, { enabled: built.canCompose, sending: room.sending });
      continue;
    }
    if (!fresh && !old) continue;
    if (fresh && old && signatureOf(old) === signatureOf(fresh)) continue;
    if (!fresh) { old.remove(); continue; }
    if (old) { old.replaceWith(fresh); continue; }
    const after = PART_ORDER.slice(PART_ORDER.indexOf(name) + 1).map((n) => screen.querySelector(`:scope > [data-part="${n}"]`)).find(Boolean);
    screen.insertBefore(fresh, after ?? null);
  }
}

/** 목록 pane + 방 pane. 휴대폰은 data-view 로 하나씩, 900px 부터 나란히. room 이 null 이면 안내 자리. */
export function renderShell(root, { list, room, box = null }) {
  shellRoot = root;
  const snap = snapshotRoomPane(root);
  const view = room ? 'room' : 'list';
  const listPane = buildRoomList({ ...list, currentRoomId: room?.roomId ?? list.currentRoomId ?? null });
  const existingShell = root.querySelector('main.shell');
  const existingScreen = existingShell?.querySelector('.room-screen') ?? null;
  const sameRoom = Boolean(room && existingScreen && existingScreen.dataset.roomId === room.roomId);
  if (existingShell && sameRoom && existingScreen.querySelector('form.composer')) {
    updateListPane(existingShell, listPane);
    patchRoomScreen(existingScreen, buildRoom(room), room);
    existingShell.dataset.view = view;
    updateBoxPane(existingShell, box);
    return;
  }
  if (existingShell && !room && !existingScreen) {
    updateListPane(existingShell, listPane);
    existingShell.dataset.view = view;
    updateBoxPane(existingShell, box);
    return;
  }
  let roomPane;
  let mount = null;
  if (room) {
    const built = buildRoom(room);
    roomPane = el('section', { class: 'pane pane-room' }, built.screen);
    mount = () => built.mount({ focus: snap.hadFocus || isWide() });
  } else {
    roomPane = el('section', { class: 'pane pane-room' }, el('div', { class: 'pane-empty' }, el('span', { class: 'big-fire', 'aria-hidden': 'true' }, '🔥'), el('p', { class: 'empty' }, strings.rooms.selectHint)));
  }
  if (existingShell) {
    updateListPane(existingShell, listPane);
    const oldRoomPane = existingShell.querySelector(':scope > .pane-room');
    if (oldRoomPane) oldRoomPane.replaceWith(roomPane); else existingShell.insertBefore(roomPane, existingShell.querySelector(':scope > .pane-box'));
    existingShell.dataset.view = view;
    updateBoxPane(existingShell, box);
  } else {
    clearScreen(root);
    const shell = el('main', { class: 'shell', 'data-view': view }, listPane, roomPane);
    root.prepend(shell);
    updateBoxPane(shell, box);
  }
  mount?.();
}

// ---- 오른쪽 보관함 pane (파일보관함 임베드, 패밀리챗 web/app buildBox 의 파일보관함 탭) ----

/**
 * pane 본체는 iframe 이라 다시 만들면 다시 로드된다 — 주소·제목이 같으면 노드를 그대로 두고
 * 열림 상태(`data-open`)만 바꾼다. 새로고침은 app.js 가 url 의 refresh 카운터를 올려 교체를 일으킨다.
 */
function buildBox({ filebox, onToggle, onRefresh }) {
  const url = fileboxRefreshUrl(filebox.url, filebox.refresh ?? 0);
  const signature = JSON.stringify([url, filebox.url, filebox.title]);
  return signed(el('section', { class: 'pane pane-box', 'aria-label': filebox.title, 'data-testid': 'filebox-pane' },
    el('header', { class: 'appbar' },
      el('button', { type: 'button', class: 'icon ghost back', 'aria-label': strings.box.close, onclick: onToggle }, '←'),
      el('div', { class: 'titles' }, el('h2', {}, '🗂 ', filebox.title))),
    el('div', { class: 'filebox-tools' },
      el('button', { type: 'button', class: 'secondary small', onclick: onRefresh }, `🔄 ${strings.box.refresh}`),
      el('a', { class: 'button ghost small', href: filebox.url, target: '_blank', rel: 'noopener noreferrer' }, strings.box.newWindow)),
    el('p', { class: 'hint meta' }, strings.box.loginHint),
    el('div', { class: 'filebox-frame' },
      el('iframe', { src: url, title: filebox.title, loading: 'lazy', referrerpolicy: 'strict-origin-when-cross-origin' }))), signature);
}

/** shell 의 보관함 pane 을 box(없으면 제거)에 맞춘다. 서명이 같으면 iframe 을 건드리지 않는다. */
function updateBoxPane(shell, box) {
  const old = shell.querySelector(':scope > .pane-box');
  if (!box) { old?.remove(); delete shell.dataset.box; return; }
  const fresh = buildBox(box);
  if (!old) shell.append(fresh);
  else if (signatureOf(old) !== signatureOf(fresh)) old.replaceWith(fresh);
  shell.dataset.box = box.open ? 'open' : 'closed';
}

// ---- 사진 크게 보기 ----

/** 마지막으로 그린 shell 의 root — 뷰어 dialog 를 같은 top layer 에 붙인다(renderShell 이 갱신). */
let shellRoot = null;

/** 미리보기를 누르면 사진을 화면 가득 보여 주고, 아무 곳이나 한 번 더 누르거나 Esc 로 대화로 돌아간다. */
function openImageViewer(entry) {
  const root = shellRoot ?? document.body;
  if (root.querySelector('dialog.viewer[open]')) return;
  const dialog = el('dialog', { class: 'viewer', 'aria-label': entry.image?.alt || strings.chat.image, 'data-testid': 'image-viewer' },
    el('img', { src: entry.image.url, alt: entry.image.alt || strings.chat.image }),
    el('span', { class: 'viewer-hint' }, strings.chat.closeImage));
  const finish = () => { if (dialog.isConnected) dialog.remove(); };
  dialog.addEventListener('click', () => { if (dialog.open) dialog.close(); finish(); });   // 사진·여백 어디든 한 번
  dialog.addEventListener('close', finish);   // Esc(cancel→close)
  root.append(dialog);
  dialog.showModal();
}

// ---- 시트 ----

function openSheet(root, { className = '', labelledBy, onClose }) {
  const dialog = el('dialog', { class: `sheet ${className}`.trim(), 'aria-labelledby': labelledBy });
  // close 이벤트는 비동기로 온다 — 코드로 닫을 때는 바로 떼고, Esc(cancel→close)도 같은 finish 로(한 번만).
  const finish = () => { if (!dialog.isConnected) return; dialog.remove(); onClose?.(); };
  const close = () => { if (dialog.open) dialog.close(); finish(); };
  dialog.addEventListener('close', finish);
  root.append(dialog);
  dialog.showModal();
  return { dialog, close };
}

const closeRow = (close, ...extra) => el('div', { class: 'row end gap' }, ...extra, el('button', { type: 'button', class: 'ghost close', onclick: close }, strings.close));

/** 설정 메뉴: items [{label, run, tone}]. 누르면 닫고 run(). */
export function openMenuSheet(root, { items, onClose }) {
  const { dialog, close } = openSheet(root, { className: 'menu', labelledBy: 'menu-title', onClose });
  setChildren(dialog,
    el('h2', { id: 'menu-title' }, strings.menu.title),
    el('div', { class: 'menu-items' }, items.map((item) => el('button', { type: 'button', class: item.tone === 'danger' ? 'danger block' : 'block', onclick: () => { close(); item.run?.(); } }, item.label))),
    closeRow(close));
  return { close };
}

export function openSettingsSheet(root, { deviceId, actor, fingerprint, subject = null, origin = '', onCopyRegistration, onOpenApprove = null, onWipe, onClose }) {
  const { dialog, close } = openSheet(root, { className: 'settings', labelledBy: 'settings-title', onClose });
  setChildren(dialog,
    el('h2', { id: 'settings-title' }, strings.settings.title),
    el('dl', { class: 'facts' },
      fact(strings.settings.deviceIdLabel, deviceId, true),
      fact(strings.settings.actorLabel, actor),
      fact(strings.settings.fingerprintLabel, fingerprintNode(fingerprint)),
      fact(strings.settings.subjectLabel, subject || el('span', { class: 'meta' }, strings.enroll.subjectUnknown), Boolean(subject)),
      origin ? fact(strings.settings.originLabel, origin, true) : null),
    el('div', { class: 'menu-items' },
      el('button', { type: 'button', class: 'block', onclick: () => onCopyRegistration?.() }, strings.settings.copyRegistration),
      onOpenApprove ? el('button', { type: 'button', class: 'block', onclick: () => { close(); onOpenApprove(); } }, strings.settings.openApprove) : null,
      el('button', { type: 'button', class: 'danger block', onclick: () => { close(); onWipe?.(); } }, strings.settings.wipe)),
    el('p', { class: 'hint' }, strings.settings.wipeHint),
    closeRow(close));
  return { close };
}

/**
 * 한 칸 입력 시트(참여 요청·방 만들기·초대 공용). onSubmit(value) 가 Promise 를 돌려주면 끝날 때까지 busy,
 * 문자열로 풀리면 그 문구를, 던지면 error.message 를 보여 준다. 돌려주는 update({busy, message, tone}) 로도 바꿀 수 있다.
 */
function openIdSheet(root, { className, title, hint, fieldLabel, fieldName, placeholder, defaultValue = '', pattern, invalidText, submitLabel, busyLabel, onSubmit, onClose, busy = false, message = null, before = [], after = [], testid = {} }) {
  const { dialog, close } = openSheet(root, { className, labelledBy: `${className}-title`, onClose });
  const status = el('p', { class: 'status info', role: 'status', hidden: true });
  const button = el('button', { type: 'submit', class: 'primary block', 'data-testid': testid.submit ?? null }, submitLabel);
  const input = el('input', { id: `f-${fieldName}`, name: fieldName, required: true, placeholder, value: defaultValue || null, autocomplete: 'off', autocapitalize: 'none', autocorrect: 'off', spellcheck: 'false', 'aria-describedby': `${className}-hint`, 'data-testid': testid.input ?? null });
  const update = (patch = {}) => {
    if ('busy' in patch) { busy = Boolean(patch.busy); button.disabled = busy; button.textContent = busy ? busyLabel : submitLabel; input.disabled = busy; }
    if ('message' in patch) {
      message = patch.message;
      status.hidden = !message;
      status.className = `status ${patch.tone || 'info'}`;
      status.textContent = message ?? '';
    }
  };
  const form = el('form', { class: 'column', onsubmit: async (event) => {
    event.preventDefault();
    if (busy) return;
    const value = input.value.trim();
    if (pattern && !pattern.test(value)) { update({ message: invalidText, tone: 'danger' }); input.focus(); return; }
    update({ busy: true, message: null });
    try {
      await onSubmit(value);
      close(); // 성공하면 닫는다 — 결과 문구는 app.js 가 setStatus 로 띄운다.
    } catch (error) {
      update({ busy: false, message: error?.message || strings.errors.generic, tone: 'danger' });
    }
  } },
    el('div', { class: 'field' }, el('label', { for: input.id }, fieldLabel), input, el('p', { class: 'hint', id: `${className}-hint` }, hint)),
    status, button);
  setChildren(dialog, el('h2', { id: `${className}-title` }, title), before, form, after, closeRow(close));
  update({ busy, message });
  input.focus();
  return { close, update, dialog };
}

export function openJoinSheet(root, { defaultRoom = '', onSubmit, onClose, busy = false, message = null }) {
  return openIdSheet(root, {
    className: 'join', title: strings.join.title, hint: strings.join.hint, fieldLabel: strings.join.field, fieldName: 'room', placeholder: 'family',
    defaultValue: defaultRoom, pattern: ROOM, invalidText: strings.join.invalid, submitLabel: strings.join.button, busyLabel: strings.join.busy,
    onSubmit, onClose, busy, message, testid: { input: 'join-room', submit: 'join-submit' },
  });
}

export function openCreateSheet(root, { defaultRoom = '', onSubmit, onClose, busy = false, message = null }) {
  return openIdSheet(root, {
    className: 'create', title: strings.create.title, hint: strings.create.hint, fieldLabel: strings.create.field, fieldName: 'newroom', placeholder: 'family',
    defaultValue: defaultRoom, pattern: ROOM, invalidText: strings.create.invalid, submitLabel: strings.create.button, busyLabel: strings.create.busy,
    onSubmit: (value) => onSubmit(value.toLowerCase()), onClose, busy, message, testid: { input: 'create-room', submit: 'create-submit' },
  });
}

/** 초대 + 멤버 목록(+ onRemove 가 있으면 멤버 제거 — 정책 체인에서 이미 폐기된 기기용). */
export function openInviteSheet(root, { roomId, members = [], onInvite, onRemove = null, onClose, busy = false, message = null, selfDevice = null }) {
  const memberRow = (device) => el('li', { class: 'member' },
    el('span', { class: 'texts' }, el('span', { class: 'name' }, displayName(device), device === selfDevice ? el('span', { class: 'pill you' }, strings.invite.thisDevice) : null), el('code', { class: 'meta' }, device)),
    onRemove && device !== selfDevice
      ? el('button', { type: 'button', class: 'ghost small danger-text', onclick: () => openConfirmSheet(root, {
          title: strings.invite.remove, body: strings.invite.removeConfirm(device), confirmLabel: strings.invite.remove, tone: 'danger',
          onConfirm: () => onRemove(device),
        }) }, strings.invite.remove)
      : null);
  const sheet = openIdSheet(root, {
    className: 'invite', title: `${strings.invite.title} — ${roomId}`, hint: strings.invite.hint, fieldLabel: strings.invite.field, fieldName: 'device', placeholder: 'mom-iphone-1a2b3c',
    pattern: DEVICE, invalidText: strings.invite.invalid, submitLabel: strings.invite.button, busyLabel: strings.invite.busy,
    onSubmit: (value) => {
      if (selfDevice && value === selfDevice) throw new Error(strings.invite.self);
      return onInvite(value);
    },
    onClose, busy, message, testid: { input: 'invite-device', submit: 'invite-submit' },
    after: [el('section', { class: 'members-section', 'aria-label': strings.invite.membersTitle },
      el('h3', {}, strings.invite.membersTitle, ' ', el('span', { class: 'pill' }, String(members.length))),
      members.length === 0 ? el('p', { class: 'hint' }, strings.invite.membersEmpty) : el('ul', { class: 'members' }, members.map(memberRow)))],
  });
  return sheet;
}

/** 신뢰 기기 승인(E2): 등록 JSON → 지문 보기 → 비교 → 승인 서명 → 증거 JSON 복사. */
export function openApproveSheet(root, { onOffer, onApprove, onClose }) {
  const { dialog, close } = openSheet(root, { className: 'approve', labelledBy: 'approve-title', onClose });
  let step = 'input';
  let candidate = null;
  let evidence = '';
  let error = null;
  let busy = false;
  const textarea = el('textarea', { id: 'f-candidate', name: 'candidate', rows: '8', placeholder: strings.approve.placeholder, 'aria-label': strings.approve.field, spellcheck: 'false' });
  const run = async (action) => {
    busy = true; error = null; render();
    try { await action(); } catch (e) { error = e?.message || strings.errors.generic; }
    busy = false; render();
  };
  const offer = () => run(async () => {
    const json = textarea.value.trim();
    if (!json) throw new Error(strings.room.candidateMissing('device_id'));
    candidate = await onOffer(json);
    step = 'compare';
  });
  const approve = () => run(async () => { evidence = await onApprove(); step = 'done'; });
  const render = () => {
    const body = step === 'input'
      ? [el('p', { class: 'hint' }, strings.approve.intro),
        el('div', { class: 'field' }, el('label', { for: 'f-candidate' }, strings.approve.field), textarea),
        el('button', { type: 'button', class: 'primary block', disabled: busy || null, onclick: offer }, busy ? strings.approve.checking : strings.approve.show)]
      : step === 'compare'
        ? [el('dl', { class: 'facts' }, fact(strings.approve.candidate, candidate.deviceId, true), fact(strings.approve.fingerprint, fingerprintNode(candidate.fingerprint))),
          el('p', { class: 'compare' }, strings.approve.compare),
          el('div', { class: 'actions' },
            el('button', { type: 'button', class: 'primary', disabled: busy || null, onclick: approve }, busy ? strings.approve.signing : strings.approve.accept),
            el('button', { type: 'button', class: 'danger', disabled: busy || null, onclick: () => { step = 'rejected'; candidate = null; render(); } }, strings.approve.reject))]
        : step === 'done'
          ? [statusLine(strings.room.approvalSigned, 'ok'),
            el('div', { class: 'json-block' },
              el('div', { class: 'row between' }, el('span', { class: 'label' }, strings.approve.evidenceTitle), copyButton(() => copyText(evidence))),
              el('pre', { class: 'json', tabindex: '0' }, evidence)),
            el('p', { class: 'hint' }, strings.approve.evidenceHint)]
          : [statusLine(strings.approve.rejected, 'warn'),
            el('button', { type: 'button', class: 'block', onclick: () => { step = 'input'; render(); textarea.focus(); } }, strings.retry)];
    setChildren(dialog, el('h2', { id: 'approve-title' }, strings.approve.title), body, statusLine(error, 'danger'), closeRow(close));
  };
  render();
  textarea.focus();
  return { close };
}

/** 확인 시트. onConfirm 이 Promise 면 끝날 때까지 busy, 던지면 문구를 보이고 남는다; 끝나면 닫는다. */
export function openConfirmSheet(root, { title, body = '', confirmLabel = strings.confirm, tone = null, onConfirm, onClose }) {
  const { dialog, close } = openSheet(root, { className: 'confirm', labelledBy: 'confirm-title', onClose });
  const feedback = el('p', { class: 'feedback', role: 'alert' });
  const button = el('button', { type: 'button', class: tone === 'danger' ? 'danger' : 'primary', onclick: async () => {
    button.disabled = true;
    try { await onConfirm?.(); close(); } catch (error) { feedback.textContent = error?.message || strings.errors.generic; button.disabled = false; }
  } }, confirmLabel);
  setChildren(dialog,
    el('h2', { id: 'confirm-title' }, title),
    body ? el('p', { class: 'confirm-body' }, body) : null,
    feedback,
    el('div', { class: 'row end gap' }, el('button', { type: 'button', class: 'ghost', onclick: close }, strings.cancel), button));
  button.focus();
  return { close };
}
