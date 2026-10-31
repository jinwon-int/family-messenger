// 한데(hande) 웹 화면 — 평범한 DOM(el 빌더), 프레임워크 없음. 문구는 전부 strings.js, 글은 텍스트 노드로만 넣는다.
// 패밀리챗 web/app/src/ui.js 의 구조(목록 pane | 방 pane, 같은 방 재렌더에서 작성창을 교체하지 않는 규칙)를 옮기고
// 모닥불 팔레트로 다시 입혔다. 업무 로직 없음: app.js 가 넘긴 props 를 그리고 콜백만 부른다.

import {
  strings, ACTOR, ROOM, DEVICE, formatTime, dayLabel, dayKey, groupFingerprint, fingerprintRows, displayName, isServiceDevice, humanSize, relativeTime,
  participantCount, participantOf, groupParticipants, deviceKind, deviceKinds,
} from './strings.js';
import {imageType, downloadSpec} from './attachment-view.js';
import { pickTransferFile, transferHasFiles } from './composer-files.js';
import { lastSentView, collapsedKey } from './last-sent.js';
import {fileboxRefreshUrl} from './filebox.js';
import {attachmentTitle} from './attachments.js';
import {parseBlocks, inlineSpans, hasMarkdown} from './agent-markdown.js';
import {linkParts} from './service-links.js';
import {isCaretMode} from './timeline-caret.js';

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

const brand = (size = 'l') => el('div', { class: `brand brand-${size}` },
  el('span', { class: 'wordmark', 'aria-label': strings.appName }, strings.wordmark),
  el('span', { class: 'subtitle' }, strings.subtitle));

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

// ---- 디자인 2차-A 공용 조각(iOS OnboardingKit 과 같은 결) ----

const SVG_NS = 'http://www.w3.org/2000/svg';
/** SVG 요소(벡터 그림 — 이모지 🔥🪵 대신). 글은 넣지 않는다. */
function svgEl(tag, attrs = {}, ...children) {
  const node = document.createElementNS(SVG_NS, tag);
  for (const [key, value] of Object.entries(attrs)) if (value != null) node.setAttribute(key, String(value));
  for (const child of children.flat()) if (child) node.append(child);
  return node;
}

/**
 * 자리 점: 사람 = 크림 ●(낮불 먹), 에이전트 = 파랑 ●(낮불 ◆). kinds = 'p' | 'a' 배열. 장식(aria-hidden).
 * 「…하는 중」 표시는 **정지된** 점 3개(움직임 없음, §A2·A5).
 */
const seatDots = (kinds = ['p', 'p', 'p'], extra = '') => el('span', { class: `seat-dots ${extra}`.trim(), 'aria-hidden': 'true' },
  kinds.map((kind) => el('span', { class: `seat-dot ${kind === 'a' ? 'agent' : 'person'}` })));

/** 상단 진행 막대(§A2): 3px · 반경 2 · 켜짐 = 불. 웹은 2칸(이름 · 등록). */
function stepBar(step, total = strings.onboarding.steps) {
  return el('div', { class: 'step-bar', role: 'img', 'aria-label': strings.onboarding.step(step, total) },
    Array.from({ length: total }, (_, index) => el('span', { class: index < step ? 'on' : null })));
}

/** 1줄 안내 + 「자세히」 → 접힌 카드(§2차-A 규칙: 설명은 1줄 + 자세히). detail 은 노드나 글. */
function moreLine(line, detail, { className = '' } = {}) {
  const card = el('div', { class: 'card more-card', hidden: true }, typeof detail === 'string' ? el('p', { class: 'hint' }, detail) : detail);
  const button = el('button', { type: 'button', class: 'more', 'aria-expanded': 'false', onclick: () => {
    const open = card.hidden;
    card.hidden = !open;
    button.textContent = open ? strings.onboarding.less : strings.onboarding.more;
    button.setAttribute('aria-expanded', open ? 'true' : 'false');
  } }, strings.onboarding.more);
  return el('div', { class: `more-line ${className}`.trim() }, el('p', { class: 'hint line' }, line, ' ', button), card);
}

/**
 * 지문 1열(§A1): 행 42px · 번호 13 · 값 모노 19 · (승인 쪽) 표시 원 22px. 등록 화면과 승인 시트가 같은 번호로 같은 행을 보인다.
 * ticks 가 Set 이면 행이 버튼(눌러 표시, aria-pressed), 아니면 그냥 행. onToggle(index) 는 호출자가 다시 그린다.
 * @param {string[]} rows fingerprintRows() 결과
 */
export function renderFingerprintRows(rows, { ticks = null, onToggle = null, label = strings.enroll.fingerprintLabel, ...attrs } = {}) {
  const interactive = ticks instanceof Set && typeof onToggle === 'function';
  return el('ol', { class: `fp-list${interactive ? ' ticking' : ''}`, 'aria-label': label, ...attrs },
    rows.map((value, index) => {
      const ticked = interactive ? ticks.has(index) : null;
      const number = el('span', { class: 'fp-n', 'aria-hidden': 'true' }, String(index + 1));
      const text = el('span', { class: 'fp-v mono', 'aria-hidden': 'true' }, value);
      if (!interactive) return el('li', { class: 'fp-row', 'aria-label': strings.onboarding.fingerprintRowLabel(index + 1, value) }, number, text);
      return el('li', { class: `fp-row${ticked ? ' ticked' : ''}` },
        el('button', { type: 'button', class: 'fp-tick-row', 'aria-pressed': ticked ? 'true' : 'false', 'aria-label': strings.onboarding.fingerprintRowLabel(index + 1, value, ticked), 'data-row': String(index), onclick: () => onToggle(index) },
          number, text, el('span', { class: 'fp-tick', 'aria-hidden': 'true' }, ticked ? '✓' : '')));
    }));
}

const TOAST_BRIEF_MS = 2000;
/** 시트 안 짧은 토스트 「복사했어요」(2초, §A5) — 시트는 top layer 라 시트 안에 붙여야 보인다. */
function sheetToast(dialog, text) {
  dialog.querySelector(':scope > .toast-brief')?.remove();
  const toast = el('p', { class: 'toast-brief', role: 'status', 'aria-live': 'polite' }, text);
  dialog.append(toast);
  setTimeout(() => toast.remove(), TOAST_BRIEF_MS);
}

/** 「복사」 글자 버튼 + 시트 토스트. */
const copyLink = (dialog, copy, label = strings.settings2.copy) => el('button', { type: 'button', class: 'more', onclick: async () => {
  const ok = await copy();
  sheetToast(dialog, ok === false ? strings.app.copyFailed : strings.settings2.copied);
} }, label);

// ---- 시작·이름·치명 오류·등록 화면 ----

/**
 * ② 이름(디자인 2차-A §A2): 진행 막대 + 제목 + 「회원가입이 없습니다」 선언 카드 + 라벨·모노 칸 + 1줄 안내 + 「자세히」.
 * 형식이 틀리면 칸 선이 warn 으로 바뀌고 밑줄 자리에 한 줄(「영문 소문자·숫자 2~16자로 써 주세요」).
 */
export function renderActorSetup(root, { onSubmit, error = null, busy = false }) {
  clearScreen(root);
  const t = strings.onboarding;
  const feedback = el('p', { class: 'feedback', role: 'alert', id: 'f-actor-feedback' }, error ?? '');
  const input = el('input', { id: 'f-actor', name: 'actor', class: 'mono', required: true, placeholder: t.actorPlaceholder, autocomplete: 'off', autocapitalize: 'none', autocorrect: 'off', spellcheck: 'false',
    inputmode: 'latin', maxlength: '16', disabled: busy || null, 'aria-describedby': 'f-actor-hint f-actor-feedback', 'aria-invalid': error ? 'true' : null, 'data-testid': 'actor-input',
    oninput: () => { if (fieldBox.classList.contains('invalid')) { fieldBox.classList.remove('invalid'); input.removeAttribute('aria-invalid'); feedback.textContent = ''; } } });
  const fieldBox = el('div', { class: `field onboarding-field${error ? ' invalid' : ''}` },
    el('label', { for: 'f-actor' }, t.actorLabel),
    input,
    moreLine(t.actorHint, t.actorDetail, { className: 'actor-more' }),
    feedback);
  fieldBox.querySelector('.more-line .hint.line').id = 'f-actor-hint';
  const form = el('form', { class: 'column onboarding-form', onsubmit: (event) => {
    event.preventDefault();
    const value = input.value.trim().toLowerCase();
    if (!ACTOR.test(value)) { fieldBox.classList.add('invalid'); input.setAttribute('aria-invalid', 'true'); feedback.textContent = t.actorInvalid; input.focus(); return; }
    fieldBox.classList.remove('invalid'); input.removeAttribute('aria-invalid'); feedback.textContent = '';
    onSubmit(value);
  } },
    fieldBox,
    el('div', { class: 'onboarding-footer' }, el('button', { type: 'submit', class: 'primary block', disabled: busy || null, 'data-testid': 'actor-submit' }, busy ? strings.actor.busy : strings.actor.button)));
  root.append(el('main', { class: 'center onboarding' }, el('section', { class: 'card hero onboarding-screen', 'aria-labelledby': 'actor-title' },
    stepBar(1),
    brand('s'),
    el('h1', { id: 'actor-title', class: 'onboarding-title' }, t.actorTitle),
    el('p', { class: 'declaration' }, t.declaration),
    form)));
  input.focus();
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

/**
 * 기기 등록 화면. mode(#574):
 * - 'operator'(기존): 등록 JSON 을 운영자에게 전달하고 403 이 풀리기를 기다린다.
 * - 'sibling': 릴레이 우편함에 올라갔다 — 큰 지문과 「다른 기기에서 승인해 주세요」, 운영자 JSON 은 접힌 보조 경로.
 * - 'id-taken': 체인에 같은 ID 가 이미 있다(409) — 지우고 새 ID 로 시작하라는 안내.
 * statusText 가 오면 상태 줄 문구를 그것으로(없으면 waiting 에 따라 기존 문구).
 */
export function renderEnroll(root, { deviceId, actor, fingerprint, subject = null, registrationJson = '', waiting = false, lastCheckedAt = null, onCopy, onCheck, onOpenApprove = null, onWipe, error = null, mode = 'operator', statusText = null, expiresAt = null }) {
  const frame = JSON.stringify([deviceId, actor, fingerprint, subject, registrationJson, error, Boolean(onOpenApprove), mode]);
  const t = strings.onboarding;
  const sibling = mode === 'sibling';
  const taken = mode === 'id-taken';
  // 대기 문구(§A2): 기술값 「(403 device_subject_mismatch)」는 화면에 내지 않는다 — 진단 기록 몫. 형제 모드는 만료 시각만(카운트다운 없음).
  const text = statusText ?? (sibling
    ? (expiresAt ? t.enrollWaitingSiblingUntil(formatTime(expiresAt)) : t.enrollWaitingSibling)
    : waiting ? t.enrollWaitingOperator : strings.enroll.notWaiting);
  const tone = taken ? 'danger' : 'waiting';
  const extra = lastCheckedAt ? strings.enroll.lastChecked(lastCheckedAt) : '';
  const statusChildren = () => [taken ? null : seatDots(['p', 'p', 'p'], 'thinking'), el('span', { class: 'text' }, text), extra ? el('span', { class: 'meta' }, extra) : null];
  const existing = root.querySelector('section.enroll');
  if (existing && signatureOf(existing) === frame) {
    // 폴링 재렌더: 선택한 지문·JSON 을 지키려고 상태 줄만 바꾼다.
    const line = existing.querySelector('.enroll-status');
    line.className = `status enroll-status ${tone}`;
    setChildren(line, statusChildren());
    liveProps.set(existing, { onCopy, onCheck, onOpenApprove, onWipe });
    return;
  }
  clearScreen(root);
  const card = el('section', { class: `card hero onboarding-screen enroll mode-${mode}`, 'aria-labelledby': 'enroll-title', 'data-testid': 'enroll', 'data-mode': mode });
  liveProps.set(card, { onCopy, onCheck, onOpenApprove, onWipe });
  const live = () => liveProps.get(card);
  // 운영자용 정보: 등록 JSON(복사) + 이름·로그인 주체 — 접힌 details(숨기지는 않는다).
  const operatorInfo = el('details', { class: 'operator-fallback section-card' },
    el('summary', {}, t.operatorInfo),
    el('p', { class: 'hint' }, sibling ? strings.enroll.operatorDetails : strings.enroll.body),
    el('dl', { class: 'facts' },
      fact(strings.enroll.actorLabel, actor),
      fact(strings.enroll.subjectLabel, subject || el('span', { class: 'meta' }, strings.enroll.subjectUnknown), Boolean(subject))),
    el('div', { class: 'json-block' },
      el('div', { class: 'row between' }, el('span', { class: 'label' }, strings.enroll.registrationLabel), copyButton(() => live().onCopy?.(), strings.enroll.copyRegistration)),
      el('pre', { class: 'json', tabindex: '0' }, registrationJson)));
  setChildren(card,
    stepBar(2),
    el('h1', { id: 'enroll-title', class: 'onboarding-title' }, t.enrollTitle),
    moreLine(t.enrollLine, sibling ? strings.enroll.siblingBody : strings.enroll.body),
    // 지문 1열(§A1): 승인하는 기기의 시트와 같은 번호·같은 행. 컨테이너에 testid 를 둔다.
    el('div', { class: 'fingerprint-hero' },
      el('span', { class: 'label' }, strings.enroll.fingerprintLabel),
      renderFingerprintRows(fingerprintRows(fingerprint), { 'data-testid': 'enroll-fingerprint', 'data-fingerprint': fingerprint }),
      el('p', { class: 'meta device-caption' }, el('span', { class: 'label' }, strings.enroll.deviceIdLabel, ' '), el('code', { class: 'mono' }, deviceId))),
    taken ? statusLine(strings.enroll.idTaken, 'danger', { 'data-testid': 'enroll-id-taken' }) : null,
    el('p', { class: `status enroll-status ${tone}`, role: 'status' }, statusChildren()),
    statusLine(error, 'danger'),
    el('div', { class: 'onboarding-footer column' },
      el('button', { type: 'button', class: 'secondary block', onclick: () => live().onCopy?.() }, t.shareRegistration),
      el('div', { class: 'row gap center-row' },
        el('button', { type: 'button', class: 'more', onclick: () => live().onCheck?.() }, strings.enroll.checkNow),
        onOpenApprove ? el('button', { type: 'button', class: 'more', onclick: () => live().onOpenApprove?.() }, strings.enroll.openApprove) : null,
        el('button', { type: 'button', class: 'more danger-text', onclick: () => live().onWipe?.() }, strings.enroll.wipe))),
    operatorInfo);
  root.append(el('main', { class: 'center onboarding' }, signed(card, frame)));
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

/**
 * @param {object} room
 * @param {Function} onSelect
 * @param {boolean} active
 * @param {{index: number, count: number, onMove: (roomId: string, toIndex: number, focus?: 'up'|'down') => void}|null} order
 *   순서 편집 중일 때만 — 행에 ▲▼가 붙고, PC 에서는 행을 끌어 옮길 수 있다(패밀리챗 roomListItem, #480 A).
 */
function roomListItem(room, onSelect, active, order = null) {
  const out = room.state === 'halted' || room.state === 'closed';
  const emoji = room.emoji || (out ? '🪵' : '🔥');
  const preview = room.preview || (out ? strings.rooms.closedPreview : strings.rooms.noMessages);
  const unread = Boolean(room.unread) && !out;
  const muted = Boolean(room.muted) && !out;
  // status-v1(#560): 일하는 중인 방은 미리보기 자리에 최신 「⏳ Working …」 줄(오너 2026-10-30 — 목록에서 작업 중인지 보이게).
  const working = !out && typeof room.working === 'string' && room.working ? room.working : null;
  const signature = JSON.stringify([room.roomId, room.name, emoji, preview, working, room.time, unread, muted, room.state, Boolean(room.hasAgent), room.members ?? 0, active, order ? [order.index, order.count] : null]);
  const classes = ['room-item', `state-${room.state}`, unread ? 'unread' : '', room.hasAgent && !out ? 'bright' : '', working ? 'working' : ''].filter(Boolean).join(' ');
  const name = room.name || room.roomId;
  const content = [
    el('span', { class: 'fire', 'aria-hidden': 'true' }, emoji),
    el('span', { class: 'texts' },
      el('span', { class: 'room-head' },
        // 이름과 N 배지를 한 묶음으로 둔다 — 긴 이름은 말줄임되고 배지는 이름 바로 옆에 항상 보인다.
        el('span', { class: 'room-title' },
          el('span', { class: 'room-name' }, name),
          muted ? el('span', { class: 'muted-mark', 'data-testid': 'room-muted', title: strings.rooms.mutedLabel },
            el('span', { 'aria-hidden': 'true' }, '🔕'),
            el('span', { class: 'visually-hidden' }, strings.rooms.mutedLabel)) : null,
          unread ? el('span', { class: 'unread-badge', title: strings.rooms.unreadLabel },
            el('span', { 'aria-hidden': 'true' }, strings.rooms.unreadBadge),
            el('span', { class: 'visually-hidden' }, strings.rooms.unreadLabel)) : null),
        // 방 목록에는 「에이전트」 배지를 두지 않는다(오너 요청 2026-10-27) — 에이전트 방 강조(bright)는 그대로.
        STATE_LABEL[room.state] ? el('span', { class: `pill state-${room.state}` }, STATE_LABEL[room.state]) : null,
        room.time ? el('span', { class: 'when' }, room.time) : null),
      working ? el('span', { class: 'preview working', 'data-testid': 'room-working' }, working) : el('span', { class: 'preview' }, preview)),
  ];
  const rowAttrs = { class: classes, 'data-room-id': room.roomId, 'data-testid': 'room-item', 'data-state': room.state, 'data-members': String(room.members ?? 0), 'aria-current': active ? 'true' : null };
  const dragAttrs = order ? {
    class: 'reorderable',
    draggable: 'true',
    ondragstart: (event) => {
      event.dataTransfer?.setData('text/plain', room.roomId);
      if (event.dataTransfer) event.dataTransfer.effectAllowed = 'move';
      event.currentTarget.classList.add('dragging');
    },
    ondragend: (event) => event.currentTarget.classList.remove('dragging'),
    ondragover: (event) => { event.preventDefault(); if (event.dataTransfer) event.dataTransfer.dropEffect = 'move'; },
    ondrop: (event) => {
      event.preventDefault();
      const dragged = event.dataTransfer?.getData('text/plain');
      if (dragged && dragged !== room.roomId) order.onMove(dragged, order.index);
    },
  } : {};
  return signed(el('li', { 'data-key': room.roomId, ...dragAttrs },
    // 순서 편집 중에는 행이 버튼이 아니다 — 눌러도 방이 열리지 않고, 행 자체를 끌 수 있게.
    order
      ? el('div', rowAttrs, ...content)
      : el('button', { type: 'button', ...rowAttrs, onclick: () => onSelect(room.roomId) }, ...content),
    order ? el('span', { class: 'order-tools' },
      el('button', { type: 'button', class: 'order-btn order-up', 'aria-label': strings.rooms.moveUp(name), disabled: order.index === 0 ? true : null, onclick: () => order.onMove(room.roomId, order.index - 1, 'up') }, '▲'),
      el('button', { type: 'button', class: 'order-btn order-down', 'aria-label': strings.rooms.moveDown(name), disabled: order.index === order.count - 1 ? true : null, onclick: () => order.onMove(room.roomId, order.index + 1, 'down') }, '▼')) : null), signature);
}

/**
 * 방을 옮긴 뒤 같은 방의 같은 방향 버튼에 포커스를 돌려준다 — 행이 다시 그려져 포커스가 body 로 떨어지지 않게,
 * 키보드로 ▲를 연달아 누를 수 있게. 끝에 닿아 비활성이면 반대쪽으로(패밀리챗 focusRoomOrderControl).
 */
export function focusRoomOrderControl(root, roomId, direction) {
  const row = [...root.querySelectorAll('ul.rooms > li')].find((li) => li.dataset.key === roomId);
  if (!row) return;
  const wanted = row.querySelector(`.order-${direction}`);
  const other = row.querySelector(`.order-${direction === 'up' ? 'down' : 'up'}`);
  const target = wanted && !wanted.disabled ? wanted : other && !other.disabled ? other : null;
  target?.focus();
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

/** 🔔 알림 버튼(#521): 받은 초대 수를 배지로. */
function bellButton(count, onOpen) {
  const label = strings.notify.button(count);
  return el('button', { type: 'button', class: 'icon ghost tool bell', 'aria-label': label, title: label, 'data-testid': 'open-notify', onclick: () => onOpen?.() },
    '🔔', count > 0 ? el('span', { class: 'unread-badge bell-badge', 'aria-hidden': 'true' }, String(count > 99 ? '99+' : count)) : null);
}
/** 「…하는 중」 줄(§A5): 정지된 크림 점 3 + 글자 — 버튼 자리를 대체한다. */
const thinkingLine = (text) => el('p', { class: 'thinking-line', role: 'status' }, seatDots(['p', 'p', 'p'], 'thinking'), el('span', {}, text));

/**
 * 로비 초대 카드(#431 4단계 → 디자인 2차-A 2e): 운영자/봇이 로비 키로 보낸 새 대화방 Welcome.
 * 상태 3 — 기본(수락 주 44 / 무시 보조) · 수락하는 중(크림 점 3 + 글자, 버튼 자리 대체) · 실패(선 warn + 사람 말 한 줄 + 다시 시도/무시).
 * 실패 횟수 숫자·기술 사유는 진단 기록(「기록 복사」)으로 — message 가 오면 아래 한 줄로.
 */
function inviteCard(invite) {
  const n = strings.notify2;
  const name = invite.name || invite.room;
  const failed = Boolean(invite.failed);
  return el('li', { class: `invite-item notice-card${failed ? ' failed' : ''}${invite.busy ? ' busy' : ''}`, 'data-testid': 'lobby-invite', 'data-room-id': invite.room, 'data-state': invite.busy ? 'busy' : failed ? 'failed' : 'new' },
    el('p', { class: 'kicker' }, n.inviteKickerLine(invite.when ?? null)),
    el('p', { class: 'body-line' }, failed ? n.inviteFailedTitle(name) : n.inviteBody(name)),
    failed ? el('p', { class: 'plain-fail', role: 'status' }, n.inviteAutoFailed(invite.failed.tries)) : null,
    invite.message && !failed ? el('p', { class: 'feedback', role: 'alert' }, invite.message) : null,
    invite.busy
      ? thinkingLine(n.accepting)
      : el('div', { class: 'actions' },
        el('button', { type: 'button', class: failed ? 'secondary' : 'primary', 'data-testid': 'invite-accept', onclick: () => invite.onAccept?.() }, failed ? strings.notify.retry : strings.lobby.accept),
        el('button', { type: 'button', class: 'secondary dim', 'data-testid': 'invite-ignore', onclick: () => invite.onIgnore?.() }, strings.lobby.ignore)));
}

/**
 * 새 기기 승인 카드(#574 → 디자인 2차-A 2a 기기 카드): 같은 사람의 새 기기가 릴레이 우편함에 올린 등록 요청.
 * 기기 ID 모노 18 · 요청·만료 시각(카운트다운 없음) · 「지문 비교 후 승인」 → 비교 시트(openApproveSheet relay) / 무시.
 * candidate = {deviceId, actor, fingerprint, createdAt(ms), expiresAt(ms), busy, message, onApprove, onIgnore}
 */
function candidateCard(candidate) {
  const a = strings.approve2;
  const times = candidate.createdAt && candidate.expiresAt ? a.times(formatTime(candidate.createdAt), formatTime(candidate.expiresAt)) : candidate.expiresAt ? a.expiresOnly(formatTime(candidate.expiresAt)) : null;
  return el('li', { class: `invite-item notice-card candidate-item${candidate.busy ? ' busy' : ''}`, 'data-testid': 'device-candidate', 'data-device': candidate.deviceId },
    el('p', { class: 'kicker' }, strings.notify2.candidateKicker),
    el('p', { class: 'device-card-id' }, el('span', { class: 'hint' }, a.incoming), el('code', { class: 'mono big-id' }, candidate.deviceId)),
    times ? el('p', { class: 'meta' }, times) : null,
    el('p', { class: 'hint' }, strings.candidates.cardBody(displayName(candidate.deviceId))),
    candidate.message ? el('p', { class: 'feedback', role: 'alert' }, candidate.message) : null,
    candidate.busy
      ? thinkingLine(strings.candidates.busy)
      : el('div', { class: 'actions' },
        el('button', { type: 'button', class: 'primary', 'data-testid': 'candidate-approve', onclick: () => candidate.onApprove?.() }, strings.candidates.approve),
        el('button', { type: 'button', class: 'secondary dim', 'data-testid': 'candidate-ignore', onclick: () => candidate.onIgnore?.() }, strings.candidates.ignore)));
}
/** 🔔 의 짧은 알림 행(형제 기기 초대 결과 등): 글 + 「확인」. note = {key, text, tone, onDismiss} */
function noteRow(note) {
  return el('li', { class: `invite-item notice-card note-item tone-${note.tone || 'info'}`, 'data-testid': 'notify-note', 'data-key': note.key },
    el('p', { class: 'body-line' }, note.text),
    note.onDismiss ? el('div', { class: 'actions' }, el('button', { type: 'button', class: 'secondary', onclick: () => note.onDismiss() }, strings.candidates.noteDismiss)) : null);
}

/** 목록 빈 상태의 꺼진 장작 그림(§A3 — 불 그림은 여기만): 장작 2 + 불씨 1점 + 둘러앉을 자리 점 2(흐림). */
function emptyLogsIcon() {
  return svgEl('svg', { width: '96', height: '64', viewBox: '0 0 96 64', fill: 'none', 'aria-hidden': 'true', class: 'empty-logs' },
    svgEl('path', { d: 'M18 50h60M22 58h52', class: 'log', 'stroke-width': '3', 'stroke-linecap': 'round' }),
    svgEl('path', { d: 'M30 46l14-12M66 46L52 34', class: 'log', 'stroke-width': '3', 'stroke-linecap': 'round' }),
    svgEl('circle', { cx: '48', cy: '30', r: '3', class: 'ember-spark' }),
    svgEl('circle', { cx: '20', cy: '40', r: '4', class: 'seat person' }),
    svgEl('circle', { cx: '76', cy: '40', r: '4', class: 'seat agent' }));
}
/** 꺼진 자리 안내 상자의 장작 아이콘(§A6). */
function closedLogIcon() {
  return svgEl('svg', { width: '28', height: '28', viewBox: '0 0 24 24', fill: 'none', 'aria-hidden': 'true', class: 'closed-log' },
    svgEl('path', { d: 'M4 14h12M4 18h12M4 14a2 2 0 1 0 0 4M16 14a2 2 0 1 1 0 4M9 10l4-4M14 10l3-3', 'stroke-width': '1.6', 'stroke-linecap': 'round' }));
}
const candidateFrame = (candidates) => candidates.map((c) => [c.deviceId, c.fingerprint, c.createdAt ?? null, c.expiresAt ?? null, Boolean(c.busy), c.message ?? null]);

function buildRoomList({ rooms = [], currentRoomId = null, onSelect, onOpenMenu, onOpenBox = null, sync = null, notice = null, deviceLabel = '', invites = [], candidates = [], notes = [], orderEditing = false, onToggleOrderEdit = null, onMoveRoom = null, onOpenNotify = null }) {
  const syncLabel = syncText(sync);
  const syncTone = sync?.reconnecting ? 'warn' : sync?.offlineSince ? 'danger' : 'ok';
  // 순서 편집은 방이 2개 이상이고 핸들러가 있을 때만(패밀리챗과 같음).
  const canReorder = rooms.length > 1 && typeof onMoveRoom === 'function' && typeof onToggleOrderEdit === 'function';
  const editing = canReorder && orderEditing;
  // 서명에서 동기화 줄(syncLabel·syncTone)은 뺀다 — 마지막 동기화 시각은 몇 초마다 바뀌어, 넣으면 pane 전체가
  // 동기화마다 교체돼 포커스·순서 편집이 끊긴다. 그 줄은 updateListPane 이 따로 갈아 끼운다.
  const frame = JSON.stringify([notice ? [notice.text, notice.tone] : null, rooms.length > 0, deviceLabel, Boolean(onOpenBox), canReorder, editing, invites.map((i) => [i.room, i.name ?? null, i.message ?? null, Boolean(i.busy), i.failed ? [i.failed.tries, i.failed.reason ?? null] : null]), Boolean(onOpenNotify),
    candidateFrame(candidates), notes.map((n) => [n.key, n.text, n.tone ?? null])]);
  const bellCount = invites.length + candidates.length + notes.length;
  // 빈 상태(§A3): 꺼진 장작 그림 + 「아직 피운 모닥불이 없습니다 / 운영자가 초대하면 여기에 자리가 생겨요.」 + 초대가 있으면 안내 카드(건수 대신 「있어요」).
  const body = rooms.length === 0
    ? el('div', { class: 'empty campfire-empty' }, emptyLogsIcon(), el('p', { class: 'empty-title' }, strings.rooms.empty), el('p', { class: 'hint' }, strings.empty.roomsHint),
      invites.length > 0 ? el('div', { class: 'card invite-hint-card' }, el('span', { class: 'ember-dot', 'aria-hidden': 'true' }), el('span', {}, strings.empty.invitesInBell)) : null)
    : el('ul', { class: 'rooms', 'aria-label': strings.rooms.listLabel }, rooms.map((room, index) => roomListItem(room, onSelect, room.roomId === currentRoomId,
      editing ? { index, count: rooms.length, onMove: onMoveRoom } : null)));
  return signed(el('aside', { class: 'pane pane-list', 'aria-label': strings.rooms.title, 'data-testid': 'room-list' },
    el('header', { class: 'appbar' },
      brand('s'),
      el('div', { class: 'tools', role: 'group', 'aria-label': strings.rooms.actions },
        canReorder ? el('button', { type: 'button', class: editing ? 'primary small order-toggle' : 'ghost small order-toggle', 'aria-pressed': editing ? 'true' : 'false', 'aria-label': editing ? strings.rooms.orderDoneLabel : strings.rooms.orderEditLabel, title: editing ? strings.rooms.orderDoneLabel : strings.rooms.orderEditLabel, 'data-testid': 'order-toggle', onclick: () => onToggleOrderEdit() },
          editing ? strings.rooms.orderDone : [el('span', { class: 'order-icon', 'aria-hidden': 'true' }, strings.rooms.orderEditIcon), el('span', { class: 'order-label' }, strings.rooms.orderEdit)]) : null,
        onOpenNotify ? bellButton(bellCount, onOpenNotify) : null,
        // 참여 요청·방 만들기는 ⚙ 설정 메뉴로(오너 2026-10-27): 헤더는 🔔·🗂·⚙ 만.
        onOpenBox ? toolButton('🗂', strings.box.toggle, 'open-box', onOpenBox) : null,
        toolButton('⚙', strings.rooms.settings, 'open-menu', onOpenMenu))),
    el('p', { class: `sync-line ${syncTone}`, role: 'status' }, el('span', { class: 'dot', 'aria-hidden': 'true' }), syncLabel),
    editing ? el('p', { class: 'order-hint', role: 'status' }, strings.rooms.orderHint) : null,
    notice ? el('div', { class: `status ${notice.tone || 'info'} notice`, role: notice.tone === 'danger' ? 'alert' : 'status' },
      el('span', {}, notice.text),
      notice.onClose ? el('button', { type: 'button', class: 'ghost small', 'aria-label': strings.close, onclick: notice.onClose }, '✕') : null) : null,
    // 새 기기 승인 카드(#574)가 초대 카드보다 위 — 같은 사람이 지금 기다리고 있는 일이다.
    candidates.length > 0 ? el('section', { class: 'card invites candidates', 'aria-label': strings.candidates.sectionTitle, 'data-testid': 'candidate-section' },
      el('h2', { class: 'section-title' }, strings.candidates.sectionTitle),
      el('ul', { class: 'invite-list' }, candidates.map(candidateCard))) : null,
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
  if (signatureOf(old) !== signatureOf(fresh)) {
    // The list pane is the room list's scroll container — a plain replace would throw a
    // scrolled-down list back to the top (2026-10-26, #502). Keep the reader's position.
    const top = old.scrollTop;
    old.replaceWith(fresh);
    if (top > 0) fresh.scrollTop = top;
    return;
  }
  // Same frame: the sync line (last sync time — changes every few seconds) is left out of the
  // signature, so swap just that <p>. A fresh node, not an in-place text edit, keeps the
  // role="status" region from being re-announced on every sync, as the whole-pane swap did.
  const oldLine = old.querySelector(':scope > .sync-line');
  const freshLine = fresh.querySelector(':scope > .sync-line');
  if (oldLine && freshLine && (oldLine.className !== freshLine.className || oldLine.textContent !== freshLine.textContent)) {
    oldLine.replaceWith(freshLine);
  }
  // rooms.length > 0 is in the frame, so both panes have the list or both show the empty card.
  const oldRooms = old.querySelector('ul.rooms');
  const freshRooms = fresh.querySelector('ul.rooms');
  if (oldRooms && freshRooms) reconcileChildren(oldRooms, [...freshRooms.children], keyOfRow);
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
    const {name, type} = downloadSpec(entry.seq, entry.image?.type ?? imageType(bytes), entry.fileName);
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

/** 서비스 봇 말풍선: 허용 링크(https://instagram.com/…)만 <a>, 나머지는 글 그대로(service-links.js). */
function serviceLinkNodes(text) {
  return linkParts(text).map((part) => (typeof part === 'string'
    ? part
    : el('a', { href: part.href, target: '_blank', rel: 'noopener noreferrer', class: 'service-link' }, part.text)));
}

function agentMarkdownBody(text) {
  return el('div', { class: 'body md', 'data-testid': 'agent-markdown' }, parseBlocks(text).map(markdownBlock));
}

/** 미리보기 실패 행(#544 B): 안내 + 「미리보기 다시 시도」. 다시 부르는 동안은 버튼을 잠그고 문구만 바꾼다. */
function previewRetry(entry, onRetryPreview) {
  if (!entry.previewFailed || !onRetryPreview) return null;
  const busy = Boolean(entry.previewBusy);
  return el('span', { class: 'preview-retry', role: 'status' },
    el('span', { class: 'meta' }, strings.chat.previewFailed),
    el('button', { type: 'button', class: 'ghost small retry-preview', 'data-testid': 'retry-preview', disabled: busy ? true : null, onclick: () => onRetryPreview(entry) },
      busy ? strings.chat.previewRetrying : strings.chat.previewRetry));
}

/** 보낸 이 라벨(디자인 1차): 에이전트는 「공명✴️ · 불지기」(점은 CSS ::before, 사람 크림·불지기 파랑). */
const senderLabel = (name, isAgent) => (isAgent && name ? `${name} · ${strings.chat.agentBadge}` : name);

// ---- 에이전트 선택지 카드(#620, AGENT-CHOICES-V1.md §3) ----
// 상태(open/answered)는 app.js 가 타임라인에서 계산해 넘긴다(agent-choices.js choiceState). 고른 번호는 이 화면만의 상태라
// 서명에 넣지 않는다: 같은 서명이면 붙어 있는 노드(그 DOM 의 선택)를 그대로 두고, 보내는 중 잠금·방 전환으로 다시 그려질 때는
// 아래 맵(choice.id = 방 + entry 키)에서 되살린다. 답이 오거나 카드가 닫히면 지운다.
const choiceSelection = new Map();

/** 말풍선 서명에 더할 카드 서명 — 선택은 빼고, open 일 때만 잠금(보내는 중·쓸 수 없는 방)을 넣는다. */
const choiceSignature = (choice) => (choice
  ? [choice.state, choice.number ?? null, choice.label ?? null, choice.choices?.items ?? null, choice.choices?.recommended ?? null,
    choice.state === 'open' ? Boolean(choice.sending) : null, choice.state === 'open' ? Boolean(choice.disabled) : null]
  : null);

function choiceCard(choice) {
  if (!choice) return null;
  const t = strings.choices;
  if (choice.state === 'answered') {
    choiceSelection.delete(choice.id);
    return el('p', { class: 'choices-answered', 'data-testid': 'choice-answered', title: t.answered(choice.number, choice.label) }, t.answered(choice.number, choice.label));
  }
  if (choice.state !== 'open') { choiceSelection.delete(choice.id); return null; }
  const { items, recommended } = choice.choices;
  const remembered = choiceSelection.get(choice.id);
  let selected = items.some((item) => item.number === remembered) ? remembered : null;
  let busy = false;   // 보내기를 누른 뒤 app 의 결과가 올 때까지(sendText false 면 풀린다)
  const rows = items.map((item) => el('button', {
    type: 'button', class: 'choice-row', 'data-testid': 'choice-row', 'data-number': String(item.number),
    'aria-label': t.row(item.number, item.label, item.number === recommended),
    onclick: () => select(selected === item.number ? null : item.number),   // 단일 선택 — 다시 누르면 해제
  },
  el('span', { class: 'choice-check', 'aria-hidden': 'true' }),
  el('span', { class: 'choice-num', 'aria-hidden': 'true' }, String(item.number)),
  el('span', { class: 'choice-label', 'aria-hidden': 'true' }, item.label),
  item.number === recommended ? el('span', { class: 'pill choice-recommended', 'aria-hidden': 'true' }, t.recommended) : null));
  const send = el('button', { type: 'button', class: 'primary small choice-send', 'data-testid': 'choice-send', onclick: () => submit() }, t.send);
  const card = el('div', { class: 'choices', role: 'group', 'aria-label': t.region, 'data-testid': 'agent-choices' },
    el('div', { class: 'choice-list' }, rows), el('div', { class: 'choice-actions' }, send));
  const paint = () => {
    const locked = busy || Boolean(choice.sending) || Boolean(choice.disabled);
    card.dataset.locked = locked ? 'true' : 'false';
    for (const row of rows) {
      const on = Number(row.dataset.number) === selected;
      row.setAttribute('aria-pressed', on ? 'true' : 'false');
      row.disabled = locked;
    }
    send.disabled = locked || selected === null;
    const label = busy || choice.sending ? t.sending : t.send;
    if (send.textContent !== label) send.textContent = label;
    if (selected !== null) send.setAttribute('aria-label', t.sendNumber(selected)); else send.removeAttribute('aria-label');
  };
  const select = (number) => {
    selected = number;
    if (number === null) choiceSelection.delete(choice.id); else choiceSelection.set(choice.id, number);
    paint();
  };
  // 평소 전송 경로(app.js sendText)로 `"N"` 을 보낸다. 보낸 글이 타임라인에 오면 상태 규칙으로 answered 가 된다.
  const submit = () => {
    if (selected === null || send.disabled) return;
    const screen = card.closest('.room-screen');
    const onChoose = screen ? liveProps.get(screen)?.onChoose : null;
    if (typeof onChoose !== 'function') return;
    busy = true; paint();
    const unlock = () => { busy = false; if (card.isConnected) paint(); };
    Promise.resolve(onChoose(selected)).then((ok) => { if (ok === false) unlock(); }, unlock);
  };
  paint();
  return card;
}

function bubble(entry, onOpenAttachment, onRetryPreview = null, choice = null) {
  const time = formatTime(entry.ts);
  const signature = JSON.stringify([entry.key, entry.kind, Boolean(entry.isMe), Boolean(entry.isAgent), entry.senderName ?? null, entry.body ?? '', time, entry.size ?? null, entry.image?.url ?? null, Boolean(entry.replay), entry.seq ?? null,
    entry.fileName ?? null, Boolean(entry.previewFailed), Boolean(entry.previewFailed) && Boolean(entry.previewBusy), choiceSignature(choice)]);
  if (entry.kind === 'system') {
    return signed(el('li', { class: 'system', 'data-key': entry.key, 'data-testid': 'system-row' }, el('span', { class: 'body' }, entry.body), time ? el('span', { class: 'foot' }, time) : null), signature);
  }
  let body;
  if (entry.kind === 'undecryptable') body = el('div', { class: 'body' }, strings.chat.undecryptable);
  else if (entry.kind === 'attachment') {
    const download = onOpenAttachment
      ? el('button', { type: 'button', class: 'ghost small download', onclick: (event) => downloadAttachment(entry, event.currentTarget, onOpenAttachment) }, strings.chat.download)
      : null;
    // 사진에는 「내려받기」 버튼을 두지 않는다(오너 요청 2026-10-27) — 크게 보기에서 길게 누르기·우클릭으로 저장된다.
    // 사진이 아닌 파일은 버튼이 유일한 받기 경로라 남긴다.
    body = entry.image
      ? el('div', { class: 'body media' },
          el('button', { type: 'button', class: 'media-open', title: strings.chat.viewImage, 'aria-label': strings.chat.viewImage, onclick: () => openImageViewer(entry) },
            el('img', { src: entry.image.url, alt: entry.image.alt || strings.chat.image, loading: 'lazy' })))
      // 파일명(#544 C): file-v2 수신분은 보낸 쪽 이름(file-v2.js safeFileName 으로 줄인 것)을, file-v1 은 와이어에 이름이 없어 「파일」.
      : el('div', { class: 'body file' }, el('span', { class: 'file-label' }, strings.chat.file(humanSize(entry.size ?? 0), entry.fileName)), previewRetry(entry, onRetryPreview), download);
  } else if (entry.isAgent && entry.kind === 'text' && hasMarkdown(entry.body)) body = agentMarkdownBody(entry.body);
  else if (entry.kind === 'text' && isServiceDevice(entry.sender)) body = el('div', { class: 'body' }, serviceLinkNodes(entry.body));
  else body = el('div', { class: 'body' }, entry.body);
  const foot = [entry.replay ? strings.chat.replay : null, time].filter(Boolean).join(' · ');
  return signed(el('li', { class: `bubble kind-${entry.kind}${entry.isAgent ? ' agent' : ''}`, 'data-key': entry.key, 'data-me': entry.isMe ? 'true' : 'false', 'data-testid': entry.kind === 'undecryptable' ? 'system-row' : 'bubble' },
    entry.isMe ? null : el('span', { class: 'who' }, senderLabel(entry.senderName || displayName(entry.sender), entry.isAgent)),
    body,
    choiceCard(choice),
    foot ? el('span', { class: 'foot' }, foot) : null), signature);
}

/**
 * status-v1(#560) 임시 말풍선: 에이전트의 「⏳ Working — 10s | Bash: …」 한 줄. 보낸이마다 하나, 키가 보낸이라서
 * 새 status 가 오면 같은 자리(맨 아래)의 본문만 바뀐다. `transient` 는 캐럿 이동·새 메시지 배지에서 빠진다.
 * 매 5초 갱신이 화면 낭독기로 계속 읽히지 않게 aria-live 는 끈다.
 */
function statusRow(st) {
  return signed(el('li', { class: 'bubble kind-status agent transient', 'data-key': `status:${st.sender}`, 'data-me': 'false', 'data-testid': 'status-bubble', 'aria-live': 'off' },
    el('span', { class: 'who' }, senderLabel(st.senderName || displayName(st.sender), true)),
    el('div', { class: 'body' }, st.text)),
  JSON.stringify(['status', st.sender, st.senderName ?? '', st.text]));
}

/** choices: entry 키 → 선택지 상태(#620, app.js 가 open·answered 인 에이전트 글만 넣는다). */
function timelineRows(timeline, onOpenAttachment, onRetryPreview = null, choices = null) {
  const rows = [];
  let day = '';
  for (const entry of timeline) {
    const key = dayKey(entry.ts);
    if (key && key !== day) {
      day = key;
      rows.push(signed(el('li', { class: 'day-divider', 'data-key': `day:${key}`, role: 'separator' }, el('span', {}, dayLabel(entry.ts))), key));
    }
    rows.push(bubble(entry, onOpenAttachment, onRetryPreview, choices?.get(entry.key) ?? null));
  }
  return rows;
}

/** 같은 방, 유지된 스크롤러: 행만 맞추고 스크롤 규칙(내 글 → 맨 아래, 아래 근처 → 따라감, 위에서 읽는 중 → 자리 유지 + 배지)을 적용. */
function updateTimeline(oldWrap, freshWrap) {
  const list = oldWrap.querySelector('.timeline');
  const freshList = freshWrap.querySelector('.timeline');
  const badge = oldWrap.querySelector('.new-messages');
  // 캐럿 모드(#284·#478)에서는 맨 아래에 있어도 새 메시지로 끌어내리지 않는다 — 선택하던 자리를 지킨다(패밀리챗 ui.js 와 같음, #541).
  const near = isNearBottom(list) && !isCaretMode(list);
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
  if (!near && !ownAdded && added.some((node) => node.classList.contains('bubble') && !node.classList.contains('transient')) && badge) badge.hidden = false;
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
    // 클립보드의 파일(스크린샷 등)은 첨부로 보낸다(#480 B). 글자만 있으면 브라우저 기본 붙여넣기.
    onpaste: (event) => {
      const file = pickTransferFile(event.clipboardData);
      if (!file || textarea.disabled) return;
      event.preventDefault();
      liveProps.get(form)?.onAttach?.(file);
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

/** 작성창 위 게이트: ⛔ 정지 > 미참여 > AI 동의 대기(#544 E — 「안내 보기」로 동의 시트를 다시 연다). live() 는 최신 props. */
function haltBanner(room, live = () => room) {
  const halted = room.halted;
  // 운영자가 닫은 자리(§A6)는 입력창 자리의 안내 상자가 설명한다 — 기술값(사유 코드)이 있는 정지 배너는 두지 않는다(진단 기록 몫).
  if (halted && halted.reason === 'room_closed' && !halted.removed) return null;
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
  if (room.consentRequired) {
    return signed(el('div', { class: 'status warn consent-gate', role: 'status', 'data-part': 'gate', 'data-testid': 'consent-gate' },
      el('span', {}, strings.consent.gateBody),
      el('button', { type: 'button', class: 'secondary small', 'data-testid': 'consent-open', onclick: () => live()?.onOpenConsent?.() }, strings.consent.gateButton)), 'consent-required');
  }
  return null;
}

function resendBar(pending) {
  if (!pending) return null;
  const size = humanSize(pending.size ?? 0);
  return signed(el('div', { class: 'resend-bar status warn', role: 'status', 'data-part': 'resend' },
    el('span', {}, el('strong', {}, strings.chat.resendTitle), ' ', strings.chat.resendBody(size)),
    el('button', { type: 'button', class: 'secondary small', onclick: () => pending.onRetry?.() }, strings.chat.resend)), `resend:${size}`);
}

// ---- 대화창 상단 "내 마지막 말" 바(패밀리챗 #300 이식, #480 C) ----
// 헤더 아래·타임라인 위의 보통 flex 자식. 같은 방 재렌더에서는 서명이 같으면 붙어 있는 노드를 그대로 둔다.
// 기본은 접힘: 키가 없으면 접힘, 펼친 방만 '0'으로 기억한다. 접힘에서 바를 누르면 이동 대신 펼치고,
// 접기는 오른쪽 화살표로만 한다. 펼친 뒤 바를 누르면 그 말풍선으로 스크롤하고 잠깐 밝힌다.
const FLASH_MS = 1600;
function readCollapsed(roomId) {
  try { return globalThis.localStorage?.getItem(collapsedKey(roomId)) !== '0'; } catch (_) { return true; }
}
function writeCollapsed(roomId, collapsed) {
  try {
    if (collapsed) globalThis.localStorage?.removeItem(collapsedKey(roomId));
    else globalThis.localStorage?.setItem(collapsedKey(roomId), '0');
  } catch (_) { /* 저장소가 막혀 있어도 접기는 이번 화면에서만 동작한다 */ }
}
/** 타임라인에서 그 말풍선(data-key)을 찾아 보이게 하고 잠깐 밝힌다. 없으면 false. */
export function jumpToBubble(list, key) {
  if (!list || typeof key !== 'string') return false;
  const bubble = list.querySelector(`li.bubble[data-key="${CSS.escape(key)}"]`);
  if (!bubble) return false;
  list.scrollTop = Math.max(0, (bubble.offsetTop - list.offsetTop) - 8);
  bubble.classList.remove('flash');
  void bubble.offsetWidth; // 같은 말풍선을 연달아 누르면 애니메이션을 다시 시작한다
  bubble.classList.add('flash');
  setTimeout(() => bubble.classList.remove('flash'), FLASH_MS);
  return true;
}
function lastSentBar(room) {
  const t = strings.chat.lastSent;
  const { lastSent, earlierSent } = lastSentView(room.timeline, { labels: { photo: t.photo, file: t.file } });
  if (!lastSent) return null;
  const roomId = room.roomId;
  const collapsed = readCollapsed(roomId);
  const barSignature = (isCollapsed) => JSON.stringify([
    lastSent.key, lastSent.text, lastSent.replies, lastSent.ts,
    earlierSent.map((item) => [item.key, item.text, item.replies, item.ts]), isCollapsed, roomId,
  ]);
  const hint = el('span', { class: 'hint', role: 'status', hidden: true }, t.notLoaded);
  const liveList = () => bar.closest('.room-screen')?.querySelector('.timeline') ?? null;
  const goTo = (key) => { hint.hidden = jumpToBubble(liveList(), key); };
  const chips = [
    el('span', { class: 'chip' }, t.replies(lastSent.replies ?? 0)),
    lastSent.ts ? el('span', { class: 'chip time' }, formatTime(lastSent.ts)) : null,
  ];
  const bar = el('div', { class: 'last-sent', role: 'region', 'aria-label': t.region, 'data-part': 'lastSent', 'data-testid': 'last-sent', 'data-collapsed': collapsed ? 'true' : 'false', 'data-key': lastSent.key ?? null });
  let toggle = null;
  const setCollapsed = (next) => {
    writeCollapsed(roomId, next);
    bar.dataset.collapsed = next ? 'true' : 'false';
    toggle.setAttribute('aria-label', next ? t.expand : t.collapse);
    toggle.setAttribute('aria-expanded', next ? 'false' : 'true');
    toggle.textContent = next ? '▾' : '▴';
    jump.title = next ? t.expand : t.jump;
    renderedSignature.set(bar, barSignature(next)); // 다음 재렌더가 같은 상태를 유지하게
  };
  const jump = el('button', { type: 'button', class: 'jump', 'data-testid': 'last-sent-jump', title: collapsed ? t.expand : t.jump,
    onclick: () => { if (bar.dataset.collapsed === 'true') setCollapsed(false); else goTo(lastSent.key); } },
    el('span', { class: 'kicker' }, el('span', { class: 'label' }, t.label), el('span', { class: 'inline-preview' }, lastSent.text), chips),
    el('span', { class: 'preview' }, lastSent.text),
    hint);
  const earlierList = earlierSent.length
    ? el('ul', { class: 'earlier', 'aria-label': t.earlierRegion }, earlierSent.map((item) => el('li', {},
      el('button', { type: 'button', class: 'earlier-jump', title: t.jump, 'data-key': item.key ?? null, onclick: () => goTo(item.key) },
        el('span', { class: 'text' }, item.text),
        el('span', { class: 'chip' }, t.replies(item.replies)),
        item.ts ? el('span', { class: 'chip time' }, formatTime(item.ts)) : null))))
    : null;
  const main = el('div', { class: 'main' }, jump, earlierList);
  toggle = el('button', { type: 'button', class: 'toggle', 'data-testid': 'last-sent-toggle', 'aria-label': collapsed ? t.expand : t.collapse, 'aria-expanded': collapsed ? 'false' : 'true',
    onclick: () => setCollapsed(bar.dataset.collapsed !== 'true') }, collapsed ? '▾' : '▴');
  setChildren(bar, main, toggle);
  return signed(bar, barSignature(collapsed));
}

/** 방 pane. parts 는 재렌더에서 따로따로 맞춘다(patchRoomScreen). */
function buildRoom(room) {
  // AI 동의 전에는 작성창을 잠근다(#544 E) — 읽기·내려받기는 그대로.
  const canCompose = Boolean(room.joined) && !room.halted && !room.consentRequired;
  const members = Array.isArray(room.members) ? room.members : [];
  const header = signed(el('header', { class: 'appbar', 'data-part': 'header' },
    el('button', { type: 'button', class: 'icon ghost back', 'aria-label': strings.chat.back, onclick: () => liveProps.get(screen)?.onBack?.() }, '←'),
    el('div', { class: 'titles' },
      el('h2', {}, el('span', { class: 'fire', 'aria-hidden': 'true' }, room.halted ? '🪵' : '🔥'), ' ', room.name || room.roomId),
      // 입력 중(#562): 머리글에만(목록 행에는 없음). 서명에 들어가므로 바뀔 때 머리글만 다시 그린다.
      room.typing ? el('span', { class: 'typing', role: 'status', 'aria-live': 'polite', 'data-testid': 'typing' }, room.typing) : null,
      // 멤버 수는 사람 단위(같은 사람의 PC·폰 = 한 명, 2026-10-28 오너) — 멤버 시트의 사람 묶음과 같은 수. 닫힌 방은 「불이 꺼진 자리」(§A6).
      el('span', { class: 'subtitle' }, room.halted?.reason === 'room_closed' ? strings.closed.subtitle : strings.chat.members(participantCount(members)))),
    el('div', { class: 'tools' },
      // 방별 알림(mute.go): 켜짐 🔔 / 꺼짐 🔕. muted 가 boolean 일 때만(옛 릴레이·미참여·정지 방은 버튼 없음).
      typeof room.muted === 'boolean' ? el('button', { type: 'button', class: 'ghost small mute-toggle', 'data-testid': 'room-mute',
        'aria-pressed': room.muted ? 'true' : 'false', 'aria-label': room.muted ? strings.chat.unmuteButton : strings.chat.muteButton,
        title: room.muted ? strings.chat.unmuteButton : strings.chat.muteButton,
        onclick: () => liveProps.get(screen)?.onToggleMute?.() }, room.muted ? '🔕' : '🔔') : null,
      room.onOpenBox ? el('button', { type: 'button', class: 'ghost small box-toggle', 'data-testid': 'open-box', 'aria-label': strings.box.toggle, onclick: () => liveProps.get(screen)?.onOpenBox?.() }, '🗂') : null,
      el('button', { type: 'button', class: 'ghost small', onclick: () => liveProps.get(screen)?.onOpenMembers?.() }, strings.chat.membersButton),
      el('button', { type: 'button', class: 'secondary small', 'data-testid': 'open-invite', disabled: room.joined ? null : true, onclick: () => liveProps.get(screen)?.onOpenInvite?.() }, strings.chat.invite))),
  JSON.stringify([room.name, room.roomId, participantCount(members), Boolean(room.halted), room.halted?.reason ?? null, Boolean(room.joined), Boolean(room.onOpenBox), room.typing ?? '', typeof room.muted === 'boolean' ? room.muted : null]));
  const notice = room.notice?.text ? signed(el('p', { class: `status ${room.notice.tone || 'info'}`, role: 'status', 'data-part': 'notice' }, room.notice.text), JSON.stringify(room.notice)) : null;
  const list = el('ul', { class: 'timeline', tabindex: '-1', 'aria-live': 'polite', 'aria-label': strings.chat.timelineLabel, 'data-testid': 'timeline' },
    room.timeline.length === 0 ? signed(el('li', { class: 'empty', 'data-key': 'empty' }, strings.chat.empty), 'empty') : timelineRows(room.timeline, room.onOpenAttachment, room.onRetryPreview ?? null, room.choices ?? null),
    (Array.isArray(room.statuses) ? room.statuses : []).map(statusRow));
  const badge = el('button', { type: 'button', class: 'new-messages', hidden: true, onclick: () => { list.scrollTop = list.scrollHeight; badge.hidden = true; } }, strings.chat.newMessages);
  list.addEventListener('scroll', () => { if (isNearBottom(list)) badge.hidden = true; });
  const timelineWrap = el('div', { class: 'timeline-wrap', 'data-part': 'timeline' }, list, badge);
  const composer = buildComposer(room);
  applyComposerState(composer, { enabled: canCompose, sending: room.sending });
  const composerWrap = el('div', { class: 'composer-wrap', 'data-part': 'composer' }, composer);
  // 꺼진 자리(§A6, 운영자가 닫은 방): 입력창 자리를 안내 상자로 — 장작 아이콘 + 한 문장 + 운영자 안내. 작성창 노드는 남기고(IME·같은 방 재렌더 규칙) CSS 로 숨긴다.
  const closed = room.halted && (room.halted.reason === 'room_closed')
    ? signed(el('div', { class: 'closed-notice', role: 'status', 'data-part': 'closed' }, closedLogIcon(),
      el('div', { class: 'texts' }, el('strong', {}, strings.closed.title), el('p', { class: 'hint' }, strings.closed.body))), 'closed')
    : null;
  // 연결 배너(§A4): 릴레이에 닿지 않을 때만(app.js 가 offline 을 준다). 면 warn 10% · 선 45% · 반경 12.
  const banner = room.offline
    ? signed(el('div', { class: 'relay-banner warn', role: 'status', 'data-part': 'banner' }, seatDots(['p', 'p', 'p'], 'thinking'), el('span', {}, strings.closed.relayUnreachable)), 'offline')
    : null;
  const parts = { header, banner, notice, lastSent: lastSentBar(room), gate: haltBanner(room, () => liveProps.get(screen)), timeline: timelineWrap, resend: resendBar(room.attachmentPending), closed, composer: composerWrap };
  const screen = el('section', { class: 'room-screen', 'data-room-id': room.roomId, 'data-halted': room.halted ? 'true' : null, 'data-closed': closed ? 'true' : null,
    // 방 화면 어디에나 파일을 끌어다 놓으면 첨부로 보낸다(#480 B). 글자 선택을 끌 때는 표시도 켜지 않는다.
    ondragenter: (event) => { if (transferHasFiles(event.dataTransfer)) { event.preventDefault(); screen.dataset.drop = 'over'; } },
    ondragover: (event) => { if (transferHasFiles(event.dataTransfer)) { event.preventDefault(); if (event.dataTransfer) event.dataTransfer.dropEffect = 'copy'; screen.dataset.drop = 'over'; } },
    ondragleave: (event) => { if (!event.relatedTarget || !screen.contains(event.relatedTarget)) delete screen.dataset.drop; },
    ondrop: (event) => {
      delete screen.dataset.drop;
      const file = pickTransferFile(event.dataTransfer);
      if (!file) return;
      event.preventDefault();
      const current = liveProps.get(screen);
      if (current && current.joined && !current.halted && !current.consentRequired) current.onAttach?.(file);
    },
  }, Object.values(parts));
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

const PART_ORDER = ['header', 'banner', 'notice', 'lastSent', 'gate', 'timeline', 'resend', 'closed', 'composer'];

/** 같은 방 재렌더: 작성창은 절대 교체하지 않고(IME), 타임라인은 행만 맞추고, 나머지는 서명이 바뀐 것만 교체. */
function patchRoomScreen(screen, built, room) {
  liveProps.set(screen, room);
  if (room.halted) screen.dataset.halted = 'true'; else delete screen.dataset.halted;
  if (built.parts.closed) screen.dataset.closed = 'true'; else delete screen.dataset.closed;
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

// ---- 오른쪽 보관함 pane (패밀리챗 web/app buildBox 와 같은 탭 2개: 「첨부」 + 파일보관함 임베드, #544 D) ----

/** 방 화면의 타임라인에서 그 말풍선(data-key)으로 스크롤·강조. 방 화면이 없거나 행이 없으면 false. */
export function jumpToEntry(root, key) {
  return jumpToBubble(root.querySelector('.room-screen .timeline'), key);
}

/** 「첨부」 행: 종류 표식 + 이름(파일명 또는 [사진]/[파일]) + 「방 · 보낸 사람 · 시각 · 크기」, 누르면 그 방·말풍선으로. 내려받기는 따로. */
function fileRow(file, onOpen, onDownload) {
  const title = attachmentTitle(file, { photo: strings.box.photo, file: strings.box.file });
  const foot = [file.roomName || null, file.senderName || null, file.ts ? relativeTime(file.ts, Date.now()) : null, file.size ? humanSize(file.size) : null].filter(Boolean).join(' · ');
  return el('li', { 'data-key': `${file.roomId}:${file.key}`, 'data-testid': 'box-file' },
    el('button', { type: 'button', class: 'file-item', title: strings.box.open, 'data-room-id': file.roomId, onclick: () => onOpen?.(file) },
      el('span', { class: `pill kind-${file.image ? 'photo' : 'file'}`, 'aria-hidden': 'true' }, file.image ? '🖼' : '📎'),
      el('span', { class: 'texts' }, el('span', { class: 'file-name' }, title), el('span', { class: 'meta' }, foot)),
      el('span', { class: 'chevron', 'aria-hidden': 'true' }, '›')),
    onDownload ? el('button', { type: 'button', class: 'ghost small download', 'aria-label': `${strings.chat.download}: ${title}`, onclick: (event) => downloadAttachment(file.entry, event.currentTarget, onDownload) }, strings.chat.download) : null);
}

/**
 * 보관함 pane. 파일보관함 탭 본체는 iframe 이라 다시 만들면 다시 로드된다 — 그 탭이 보일 때는 서명에서 첨부 목록을 빼
 * 새 첨부가 와도 pane 을 유지한다(패밀리챗 #194). 새로고침은 app.js 가 url 의 refresh 카운터를 올려 교체를 일으킨다.
 */
function buildBox({ open, tab = 'attachments', attachments = [], filebox = null, onToggle, onTab, onRefresh, onOpen, onDownload }) {
  const showFilebox = tab === 'filebox' && filebox;
  const url = filebox ? fileboxRefreshUrl(filebox.url, filebox.refresh ?? 0) : null;
  const signature = JSON.stringify([
    showFilebox ? 'filebox' : 'attachments', filebox ? [url, filebox.url, filebox.title] : null,
    showFilebox ? null : attachments.map((f) => [f.roomId, f.key, f.image, f.fileName, f.size, f.roomName, f.senderName, f.ts ? relativeTime(f.ts, Date.now()) : '']),
  ]);
  const tabs = filebox
    ? el('div', { class: 'box-tabs', role: 'tablist' },
        el('button', { type: 'button', role: 'tab', 'data-testid': 'box-tab-attachments', 'aria-selected': showFilebox ? 'false' : 'true', onclick: () => onTab?.('attachments') }, strings.box.tabAttachments),
        el('button', { type: 'button', role: 'tab', 'data-testid': 'box-tab-filebox', 'aria-selected': showFilebox ? 'true' : 'false', onclick: () => onTab?.('filebox') }, filebox.title))
    : null;
  const body = showFilebox
    ? el('div', { class: 'box-body filebox' },
        el('div', { class: 'filebox-tools' },
          el('button', { type: 'button', class: 'secondary small', onclick: onRefresh }, `🔄 ${strings.box.refresh}`),
          el('a', { class: 'button ghost small', href: filebox.url, target: '_blank', rel: 'noopener noreferrer' }, strings.box.newWindow)),
        el('p', { class: 'hint meta' }, strings.box.loginHint),
        el('div', { class: 'filebox-frame' },
          el('iframe', { src: url, title: filebox.title, loading: 'lazy', referrerpolicy: 'strict-origin-when-cross-origin' })))
    : el('div', { class: 'box-body attachments' },
        attachments.length === 0
          ? el('p', { class: 'empty', 'data-testid': 'box-empty' }, strings.box.empty)
          : el('ul', { class: 'files', 'aria-label': strings.box.tabAttachments }, attachments.map((f) => fileRow(f, onOpen, onDownload))),
        el('p', { class: 'hint meta' }, strings.box.scopeHint));
  return signed(el('section', { class: 'pane pane-box', 'aria-label': strings.box.title, 'data-testid': 'box-pane', 'data-tab': showFilebox ? 'filebox' : 'attachments' },
    el('header', { class: 'appbar' },
      el('button', { type: 'button', class: 'icon ghost back', 'aria-label': strings.box.close, onclick: onToggle }, '←'),
      el('div', { class: 'titles' }, el('h2', {}, '🗂 ', strings.box.title))),
    tabs, body), signature);
}

/** shell 의 보관함 pane 을 box(없으면 제거)에 맞춘다. 서명이 같으면(특히 iframe 탭) 노드를 건드리지 않는다. */
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
    el('div', { class: 'menu-items' }, items.map((item) => el('button', { type: 'button', class: item.tone === 'danger' ? 'danger block' : 'block', 'data-testid': item.testid ?? null, onclick: () => { close(); item.run?.(); } }, item.label))),
    closeRow(close));
  return { close };
}

/**
 * 🔔 알림 시트(#521 → 디자인 2차-A 2e): 머리 「알림」 + 오른쪽 위 글자 버튼 「기록 복사」(토스트 「복사했어요」).
 * 카드 = 새 기기 승인(2a 기기 카드) → 새 자리 초대(3상태) → 짧은 알림. 빈 상태 = 흐린 자리 점 3 + 「새 알림이 없어요」 + 한 줄.
 * 수락·승인·무시는 닫고 처리한다(결과는 목록·배지에 반영).
 */
export function openNotifySheet(root, { invites = [], candidates = [], notes = [], onCopyLogs = null, onClose }) {
  const { dialog, close } = openSheet(root, { className: 'notify', labelledBy: 'notify-title', onClose });
  const n = strings.notify2;
  const wrapped = invites.map((i) => ({ ...i, onAccept: () => { close(); i.onAccept?.(); }, onIgnore: () => { close(); i.onIgnore?.(); } }));
  const wrappedCandidates = candidates.map((c) => ({ ...c, onApprove: () => { close(); c.onApprove?.(); }, onIgnore: () => { close(); c.onIgnore?.(); } }));
  const wrappedNotes = notes.map((nt) => ({ ...nt, onDismiss: nt.onDismiss ? () => { close(); nt.onDismiss(); } : null }));
  const empty = wrapped.length === 0 && wrappedCandidates.length === 0 && wrappedNotes.length === 0;
  const copyLogs = onCopyLogs
    ? el('button', { type: 'button', class: 'more sheet-action', 'data-testid': 'notify-copy-logs', 'aria-label': strings.notify.copyLogs, title: strings.notify.copyLogs, onclick: async () => {
      const ok = await onCopyLogs();
      sheetToast(dialog, ok === false ? strings.app.copyFailed : n.copied);
    } }, n.copyLogsShort)
    : null;
  setChildren(dialog,
    el('div', { class: 'sheet-head' },
      el('button', { type: 'button', class: 'icon ghost close', 'aria-label': strings.close, title: strings.close, onclick: close }, '✕'),
      el('h2', { id: 'notify-title' }, strings.notify.title),
      copyLogs ?? el('span', { class: 'sheet-action-space', 'aria-hidden': 'true' })),
    empty
      ? el('div', { class: 'empty notify-empty', 'data-testid': 'notify-empty' }, seatDots(['p', 'p', 'a'], 'dim'), el('p', { class: 'empty-title' }, n.empty), el('p', { class: 'hint' }, n.emptyBody))
      : null,
    wrappedCandidates.length ? el('ul', { class: 'invite-list', 'aria-label': strings.notify.candidateNew }, wrappedCandidates.map(candidateCard)) : null,
    wrapped.length ? el('ul', { class: 'invite-list', 'aria-label': strings.notify.inviteNew }, wrapped.map(inviteCard)) : null,
    wrappedNotes.length ? el('ul', { class: 'invite-list', 'aria-label': strings.notify.notes }, wrappedNotes.map(noteRow)) : null,
    empty ? null : el('p', { class: 'hint notify-hint' }, n.hint));
  return { close };
}

/**
 * 설정 「화면」(한데 디자인 1차 → 2차-A 칩 탭): 밤 · 낮불 · 시스템 — 라디오를 칩 탭(높이 36·반경 10)으로 입힌다. 고르면 바로 적용(theme.js).
 * testid theme-row · theme-night/day/auto 는 그대로. 아래 힌트는 고른 테마 설명 한 줄.
 */
function themeRow(theme, onTheme) {
  const t = strings.settings2;
  const options = [['night', t.themeChipNight, t.themeNightHint], ['day', t.themeChipDay, t.themeDayHint], ['auto', t.themeChipAuto, t.themeAutoHint]];
  const hint = el('p', { class: 'hint theme-hint' }, options.find(([value]) => value === theme)?.[2] ?? t.themeNightHint);
  return el('fieldset', { class: 'theme-row', 'data-testid': 'theme-row' },
    el('legend', { class: 'visually-hidden' }, strings.settings.theme),
    el('div', { class: 'chip-tabs', role: 'radiogroup', 'aria-label': strings.settings.theme },
      options.map(([value, label, line]) => el('label', { class: 'chip-tab theme-option' },
        el('input', { type: 'radio', name: 'theme', value, checked: theme === value ? true : null, 'data-testid': `theme-${value}`, onchange: () => { hint.textContent = line; onTheme(value); } }),
        el('span', { class: 'name' }, label)))),
    hint);
}

/** 설정 칸: 머리 13/600 + 카드(행 48). tone 'danger' 면 머리가 warn 색. */
const section = (title, body, tone = null) => el('section', { class: `section${tone ? ` ${tone}` : ''}`, 'aria-label': title },
  el('h3', { class: 'section-title' }, title), body);
const sectionRow = (main, aside = null, attrs = {}) => el('div', { class: 'section-row', ...attrs }, el('div', { class: 'texts' }, main), aside);

/**
 * 설정 시트(디자인 2차-A §A5, 순서 = 자주 → 드물게 → 위험): 서버 → 화면 → 이 기기(ID + 복사 · 「운영자용 정보」 접힘) →
 * 기기 관리 → 위험 구역(「이 기기 지우기」 하나만). 웹에는 서버 바꾸기·로그아웃·버전이 없어 계정·정보 칸은 없다.
 * 운영자용 정보: 지문(묶음) · 이름 · 로그인 주체 · 정책 revision · 등록 정보 복사 · 신뢰 기기 승인(붙여넣기).
 */
export function openSettingsSheet(root, { deviceId, actor, fingerprint, subject = null, origin = '', policyRevision = null, onCopyRegistration, onOpenApprove = null, onOpenDevices = null, onWipe, onClose, theme = null, onTheme = null }) {
  const { dialog, close } = openSheet(root, { className: 'settings', labelledBy: 'settings-title', onClose });
  const t = strings.settings2;
  const operatorInfo = el('details', { class: 'operator-info' },
    el('summary', { class: 'section-row' }, el('span', {}, t.operatorInfo), el('span', { class: 'chevron', 'aria-hidden': 'true' }, '▸')),
    el('div', { class: 'operator-body' },
      el('dl', { class: 'facts' },
        fact(strings.settings.fingerprintLabel, el('code', { class: 'mono fingerprint-inline', 'aria-label': strings.settings.fingerprintLabel }, groupFingerprint(fingerprint))),
        fact(strings.settings.actorLabel, actor),
        fact(strings.settings.subjectLabel, subject || el('span', { class: 'meta' }, strings.enroll.subjectUnknown), Boolean(subject)),
        policyRevision != null ? fact(t.policyRevision, String(policyRevision), true) : null),
      el('p', { class: 'hint' }, t.lobbyHint),
      el('div', { class: 'menu-items' },
        el('button', { type: 'button', class: 'secondary block', onclick: async () => { const ok = await onCopyRegistration?.(); sheetToast(dialog, ok === false ? strings.app.copyFailed : t.copied); } }, strings.settings.copyRegistration),
        onOpenApprove ? el('button', { type: 'button', class: 'secondary block', onclick: () => { close(); onOpenApprove(); } }, strings.settings.openApprove) : null)));
  setChildren(dialog,
    el('h2', { id: 'settings-title' }, strings.settings.title),
    origin ? section(t.server, el('div', { class: 'section-card' }, sectionRow([el('span', {}, strings.settings.originLabel), el('code', { class: 'mono meta' }, origin)]))) : null,
    typeof onTheme === 'function' ? section(t.screen, el('div', { class: 'section-card padded' }, themeRow(theme ?? 'night', onTheme))) : null,
    section(t.thisDevice, el('div', { class: 'section-card' },
      sectionRow([el('span', { class: 'meta' }, strings.settings.deviceIdLabel), el('code', { class: 'mono' }, deviceId)], copyLink(dialog, () => copyText(deviceId)), { 'data-testid': 'settings-device-id' }),
      operatorInfo)),
    onOpenDevices ? section(t.deviceManage, el('div', { class: 'section-card' },
      el('button', { type: 'button', class: 'section-row link-row', 'data-testid': 'open-devices', onclick: () => { close(); onOpenDevices(); } }, el('span', {}, strings.settings.openDevices), el('span', { class: 'chevron', 'aria-hidden': 'true' }, '›')))) : null,
    section(t.danger, el('div', { class: 'danger-zone' },
      el('p', { class: 'hint' }, t.wipeDangerBody),
      el('button', { type: 'button', class: 'btn-danger block', onclick: () => { close(); onWipe?.(); } }, strings.settings.wipe)), 'danger'),
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

/**
 * 초대 + 멤버 목록(+ onRemove 가 있으면 멤버 제거 — 정책 체인에서 이미 폐기된 기기용).
 * 멤버는 **사람 단위**로 묶어 보인다(2026-10-28 오너): 같은 사람의 PC·폰이 「두 명」으로 서지 않고, 한 사람 행 아래에
 * 기기 줄(종류 · ID · 「이 기기」 · 제거)이 붙는다. MLS 좌석과 릴레이 명단은 그대로 기기 단위다.
 */
export function openInviteSheet(root, { roomId, roomName = roomId, members = [], onInvite, onRemove = null, onForget = null, onClose, busy = false, message = null, selfDevice = null }) {
  const selfKey = selfDevice ? participantOf(selfDevice) : null;
  const deviceRow = (device) => el('li', { class: 'device', 'data-device': device },
    el('span', { class: 'texts' },
      el('span', { class: 'kind' }, deviceKinds[deviceKind(device)] ?? deviceKind(device) ?? '', device === selfDevice ? el('span', { class: 'pill you' }, strings.invite.thisDevice) : null),
      el('code', { class: 'meta' }, device)),
    onRemove && device !== selfDevice
      ? el('button', { type: 'button', class: 'ghost small danger-text', onclick: () => openConfirmSheet(root, {
          title: strings.invite.remove, body: strings.invite.removeConfirm(device), confirmLabel: strings.invite.remove, tone: 'danger',
          onConfirm: () => onRemove(device),
        }) }, strings.invite.remove)
      : null);
  const memberRow = (group) => el('li', { class: 'member', 'data-participant': group.key },
    el('span', { class: 'texts' },
      el('span', { class: 'name' }, group.name, group.key === selfKey ? el('span', { class: 'pill you' }, strings.invite.you) : null,
        el('span', { class: 'pill' }, strings.invite.deviceCount(group.devices.length))),
      el('ul', { class: 'devices' }, group.devices.map(deviceRow))));
  const groups = groupParticipants(members);
  const sheet = openIdSheet(root, {
    className: 'invite', title: `${strings.invite.title} — ${roomId}`, hint: strings.invite.hint, fieldLabel: strings.invite.field, fieldName: 'device', placeholder: 'mom-iphone-1a2b3c',
    pattern: DEVICE, invalidText: strings.invite.invalid, submitLabel: strings.invite.button, busyLabel: strings.invite.busy,
    onSubmit: (value) => {
      if (selfDevice && value === selfDevice) throw new Error(strings.invite.self);
      return onInvite(value);
    },
    onClose, busy, message, testid: { input: 'invite-device', submit: 'invite-submit' },
    after: [el('section', { class: 'members-section', 'aria-label': strings.invite.membersTitle },
      el('h3', {}, strings.invite.membersTitle, ' ', el('span', { class: 'pill' }, String(groups.length))),
      groups.length === 0 ? el('p', { class: 'hint' }, strings.invite.membersEmpty) : el('ul', { class: 'members' }, groups.map(memberRow))),
    // 릴레이에 없는 로컬 전용 방만(app.js 가 onForget 을 준다): 확인 시트 → 지우고 이 시트도 닫는다.
    onForget ? el('section', { class: 'members-section forget-section' },
      el('button', { type: 'button', class: 'danger block', 'data-testid': 'forget-room', onclick: () => openConfirmSheet(root, {
        title: strings.forget.title, body: strings.forget.body(roomName), confirmLabel: strings.forget.confirm, tone: 'danger',
        onConfirm: async () => { await onForget(); sheet.close(); },
      }) }, strings.forget.button),
      el('p', { class: 'hint' }, strings.forget.hint)) : null],
  });
  return sheet;
}

/**
 * 신뢰 기기 승인(E2). mode 'paste'(기존): 등록 JSON → 지문 보기 → 비교 → 승인 서명 → 증거 JSON 복사(운영자에게 전달).
 * mode 'relay'(#574): 우편함 후보 `candidate = {deviceId, fingerprint}` 로 비교 단계부터 시작, onApprove() 가 릴레이에 올리고 끝나면 완료 문구(JSON 없음).
 */
export function openApproveSheet(root, { onOffer = null, onApprove, onReject = null, onCopyDiagnostics = null, onClose, mode = 'paste', candidate: initial = null }) {
  const { dialog, close } = openSheet(root, { className: 'approve', labelledBy: 'approve-title', onClose });
  const a = strings.approve2;
  const relay = mode === 'relay';
  let step = relay && initial ? 'compare' : 'input';
  let candidate = relay ? initial : null;
  let evidence = '';
  let error = null;
  let busy = false;
  // 지문 대조 게이트(§A1): 행마다 직접 눌러 표시해야 하고, 전부 표시되기 전까지 「승인」은 꺼짐. 후보가 바뀌면 표시를 비운다.
  let ticks = new Set();
  let rejected = null;   // 「다릅니다」를 누른 기기 — 결과 화면 문구용
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
    ticks = new Set();
    step = 'compare';
  });
  const approve = () => run(async () => { evidence = await onApprove(); step = 'done'; });
  const reject = () => {
    rejected = candidate;
    step = 'rejected'; candidate = null; ticks = new Set();
    render();
    onReject?.(rejected);
  };
  const copyDiagnostics = () => (onCopyDiagnostics ? onCopyDiagnostics() : copyText(`${rejected?.deviceId ?? ''}\n${groupFingerprint(rejected?.fingerprint ?? '')}`));
  const compareBody = () => {
    const rows = fingerprintRows(candidate.fingerprint);
    const total = rows.length;
    const done = ticks.size >= total && total > 0;
    const times = candidate.createdAt && candidate.expiresAt ? a.times(formatTime(candidate.createdAt), formatTime(candidate.expiresAt)) : candidate.expiresAt ? a.expiresOnly(formatTime(candidate.expiresAt)) : null;
    const approveButton = el('button', { type: 'button', class: 'primary block tall', 'data-testid': 'approve-accept', disabled: busy || !done ? true : null,
      'aria-describedby': done ? null : 'approve-gate-hint', onclick: approve }, busy ? a.signing : done ? a.approve : a.disabled(total));
    return [
      el('div', { class: 'card device-card' },
        el('span', { class: 'hint' }, a.incoming),
        el('code', { class: 'mono big-id' }, candidate.deviceId),
        times ? el('span', { class: 'meta' }, times) : null),
      el('p', { class: 'compare' }, a.compareTitle),
      renderFingerprintRows(rows, { ticks, onToggle: (index) => { if (busy) return; if (ticks.has(index)) ticks.delete(index); else ticks.add(index); render(); }, label: strings.approve.fingerprint, 'data-testid': 'approve-fingerprint' }),
      el('p', { class: 'hint progress-line', role: 'status', 'data-testid': 'approve-progress' }, done ? a.allMatched : a.progress(ticks.size, total)),
      el('div', { class: 'warn-box', role: 'note' }, el('span', { class: 'warn-dot', 'aria-hidden': 'true' }), el('span', {}, a.warning)),
      el('span', { id: 'approve-gate-hint', class: 'visually-hidden' }, a.disabledAccessibility(total)),
      el('div', { class: 'column approve-actions' },
        approveButton,
        el('div', { class: 'actions' },
          el('button', { type: 'button', class: 'btn-danger', 'data-testid': 'approve-reject', disabled: busy || null, onclick: reject }, a.mismatch),
          el('button', { type: 'button', class: 'secondary', 'data-testid': 'approve-later', disabled: busy || null, onclick: close }, a.later))),
    ];
  };
  const render = () => {
    const body = step === 'input'
      ? [el('p', { class: 'hint' }, strings.approve.intro),
        el('div', { class: 'field' }, el('label', { for: 'f-candidate' }, strings.approve.field), textarea),
        el('button', { type: 'button', class: 'primary block', disabled: busy || null, onclick: offer }, busy ? strings.approve.checking : strings.approve.show)]
      : step === 'compare'
        ? compareBody()
        : step === 'done'
          ? relay
            // 성공 표시는 글자로만(체크 배지 없음): 크림 점 3 + 「○○를 승인했어요」 + 자동 초대 안내.
            ? [el('div', { class: 'result-state', role: 'status', 'data-testid': 'approve-done' },
                seatDots(['p', 'p', 'p']),
                el('p', { class: 'result-title' }, a.approvedTitle(initial?.deviceId ?? '')),
                el('p', { class: 'hint' }, a.approvedBody)),
              el('button', { type: 'button', class: 'primary block', onclick: close }, a.confirm)]
            : [statusLine(strings.room.approvalSigned, 'ok'),
              el('div', { class: 'json-block' },
                el('div', { class: 'row between' }, el('span', { class: 'label' }, strings.approve.evidenceTitle), copyButton(() => copyText(evidence))),
                el('pre', { class: 'json', tabindex: '0' }, evidence)),
              el('p', { class: 'hint' }, strings.approve.evidenceHint)]
          : [el('div', { class: 'result-state', role: 'status', 'data-testid': 'approve-rejected' },
              el('span', { class: 'seat-dot ash', 'aria-hidden': 'true' }),
              el('p', { class: 'result-title' }, a.rejectedTitle),
              el('p', { class: 'hint' }, a.rejectedBody(rejected?.deviceId ?? ''))),
            el('button', { type: 'button', class: 'secondary block', onclick: async () => { const ok = await copyDiagnostics(); sheetToast(dialog, ok === false ? strings.app.copyFailed : strings.settings2.copied); } }, a.copyDiagnostics),
            relay ? null : el('button', { type: 'button', class: 'block', onclick: () => { step = 'input'; render(); textarea.focus(); } }, strings.retry)];
    // 비교 단계는 「나중에」가, 릴레이 승인 완료는 「확인」이 닫는다 — 그 밖은 「닫기」 행.
    const hasOwnClose = step === 'compare' || (step === 'done' && relay);
    setChildren(dialog,
      el('h2', { id: 'approve-title' }, relay ? a.title : strings.approve.title),
      body,
      statusLine(error, 'danger'),
      hasOwnClose ? null : closeRow(close));
  };
  render();
  if (step === 'input') textarea.focus();
  return { close };
}

/**
 * 「내 기기」 시트(#574 E5): 체인에 있는 내 subject 의 기기(self-service.js rolesActions 결과)와 registrar 부여·해제.
 * onGrant(deviceId) / onRelease(deviceId) 는 끝나면 새 행 목록을 돌려준다(또는 던진다) — 시트는 제자리에서 다시 그린다.
 * view = {canSign, actor, devices:[{deviceId, actor, status, registrar, isSelf, grant, release, lastRegistrar}]} · null 이면 옛 릴레이.
 */
export function openDevicesSheet(root, { view, onGrant, onRelease, onClose }) {
  const { dialog, close } = openSheet(root, { className: 'devices', labelledBy: 'devices-title', onClose });
  let current = view;
  let busyId = null;
  let error = null;
  const act = async (deviceId, grant) => {
    busyId = deviceId; error = null; render();
    try { const next = await (grant ? onGrant : onRelease)(deviceId); if (next) current = next; }
    catch (e) { error = e?.message || strings.errors.generic; }
    busyId = null; render();
  };
  const row = (d) => {
    const busy = busyId === d.deviceId;
    const button = d.grant || d.release
      ? el('button', { type: 'button', class: d.release ? 'ghost small danger-text' : 'secondary small', 'data-testid': d.release ? 'device-release' : 'device-grant', disabled: busyId ? true : null, onclick: () => act(d.deviceId, d.grant) }, busy ? strings.devices.busy : d.grant ? strings.devices.grant : strings.devices.release)
      : null;
    return el('li', { class: `member device-row status-${d.status}`, 'data-device': d.deviceId, 'data-registrar': d.registrar ? 'true' : 'false' },
      el('span', { class: 'texts' },
        el('span', { class: 'name' }, displayName(d.deviceId),
          d.isSelf ? el('span', { class: 'pill you' }, strings.invite.thisDevice) : null,
          el('span', { class: `pill state-${d.status === 'active' ? 'joined' : 'closed'}` }, d.status === 'active' ? strings.devices.active : strings.devices.revoked),
          d.registrar ? el('span', { class: 'pill registrar' }, strings.devices.registrar) : null),
        el('code', { class: 'meta' }, d.deviceId),
        d.fingerprint ? el('code', { class: 'meta fingerprint-inline' }, groupFingerprint(d.fingerprint)) : null,
        d.lastRegistrar ? el('span', { class: 'meta' }, strings.devices.lastRegistrar) : null),
      button);
  };
  const render = () => {
    const devices = current?.devices ?? [];
    setChildren(dialog,
      el('h2', { id: 'devices-title' }, strings.devices.title),
      el('p', { class: 'hint' }, strings.devices.hint),
      current === null
        ? el('p', { class: 'status warn', role: 'status' }, strings.devices.unsupported)
        : devices.length === 0
          ? el('p', { class: 'hint', 'data-testid': 'devices-empty' }, strings.devices.empty)
          : el('ul', { class: 'members devices-list', 'aria-label': strings.devices.title }, devices.map(row)),
      current && devices.length && !current.canSign ? el('p', { class: 'meta', role: 'status' }, strings.devices.cannotSign) : null,
      statusLine(error, 'danger'),
      closeRow(close));
  };
  render();
  return { close, update: (next) => { current = next; render(); } };
}

/**
 * AI 참여 동의 시트(#544 E, 패밀리챗 초대 카드의 동의 블록과 같은 문구): 안내 + 참여자 + 체크 → 「동의하고 대화하기」.
 * 「나중에」는 동의 없이 닫는다(작성창은 잠긴 채, 게이트의 「안내 보기」로 다시 연다).
 */
export function openConsentSheet(root, { roomName, agentNames = [], onConsent, onClose }) {
  const { dialog, close } = openSheet(root, { className: 'consent', labelledBy: 'consent-title', onClose });
  const hint = el('p', { class: 'hint', role: 'status' }, strings.consent.required);
  const button = el('button', { type: 'button', class: 'primary', disabled: true, 'data-testid': 'consent-confirm', onclick: () => { close(); onConsent?.(); } }, strings.consent.confirm);
  const check = el('input', { type: 'checkbox', 'data-testid': 'consent-check', onchange: (event) => { button.disabled = !event.target.checked; hint.hidden = event.target.checked; } });
  setChildren(dialog,
    el('h2', { id: 'consent-title' }, strings.consent.title),
    el('p', { class: 'meta' }, roomName),
    el('p', { class: 'confirm-body' }, strings.consent.body),
    agentNames.length ? el('p', { class: 'consent-agents' }, strings.consent.agents(agentNames.join(', '))) : null,
    el('label', { class: 'consent-check' }, check, el('span', {}, strings.consent.label)),
    hint,
    el('div', { class: 'row end gap' }, el('button', { type: 'button', class: 'ghost', 'data-testid': 'consent-later', onclick: close }, strings.consent.later), button));
  check.focus();
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
