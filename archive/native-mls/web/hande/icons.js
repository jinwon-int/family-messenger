// 한데 고유 UI 아이콘 세트(디자인 2차-B §B2) — docs/design/icons/ui/*.svg 의 경로를 그대로 모듈에 심었다(네트워크 fetch 없음, CSP 인라인 스크립트 없음).
// 24 뷰박스 · 선 1.6 currentColor · 둥근 끝. 역할색 채움(data-role="ember|ember-deep|person|agent|ink")은 styles.css 가 테마 토큰으로 칠하고,
// 꺼진 불꽃 갈래(data-role="unlit")는 선만(밤 35% / 낮불 먹 선 100%). 낮불 `seat` 의 에이전트 점은 ◆(.seat-diamond) 로 바뀐다(.seat-circle 숨김).
// 순수 모듈: iconSpec()/iconMarkup() 은 DOM 없이 쓰고(테스트), icon() 만 document 로 요소를 만든다. 글은 넣지 않는다(aria-hidden 장식).

export const STROKE_WIDTH = '1.6';
export const VIEW_BOX = '0 0 24 24';

/** 불꽃 3갈래(왼쪽 · 가운데 · 오른쪽). 켜진 갈래 수 = 단계(1 = 가운데, 2 = 가운데+왼쪽, 3 = 모두). */
const FLAME_LEFT = 'M5.5 20.5c-1.7 0-2.7-1.2-2.7-2.8 0-1.9 1.6-3 2.7-5.2 1.1 2.2 2.7 3.3 2.7 5.2 0 1.6-1 2.8-2.7 2.8Z';
const FLAME_CENTER = 'M12 20.5c-2.1 0-3.4-1.6-3.4-3.7 0-2.9 2.2-4.8 3.4-8.8 1.2 4 3.4 5.9 3.4 8.8 0 2.1-1.3 3.7-3.4 3.7Z';
const FLAME_RIGHT = 'M18.5 20.5c-1.7 0-2.7-1.2-2.7-2.8 0-1.9 1.6-3 2.7-5.2 1.1 2.2 2.7 3.3 2.7 5.2 0 1.6-1 2.8-2.7 2.8Z';

const circle = (cx, cy, r) => `M${cx - r} ${cy}a${r} ${r} 0 1 0 ${r * 2} 0a${r} ${r} 0 1 0 ${-r * 2} 0Z`;
const diamond = (cx, cy, r) => `M${cx} ${cy - r}l${r} ${r}-${r} ${r}-${r}-${r}Z`;

const lit = (d, role) => ({ d, role, fill: true });
const unlit = (d) => ({ d, role: 'unlit' });
const stroke = (d) => ({ d });

/** 불 세기 1~3 → 갈래 셋(왼쪽 ember-deep · 가운데 ember · 오른쪽 ember-deep, 꺼진 갈래는 unlit). */
function flamePaths(level) {
  const n = Math.min(3, Math.max(1, Number(level) || 1));
  return [
    n >= 2 ? lit(FLAME_LEFT, 'ember-deep') : unlit(FLAME_LEFT),
    lit(FLAME_CENTER, 'ember'),
    n >= 3 ? lit(FLAME_RIGHT, 'ember-deep') : unlit(FLAME_RIGHT),
  ];
}

const DEVICE_PHONE = 'M8 3h8a2 2 0 0 1 2 2v14a2 2 0 0 1-2 2H8a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2Z';

/** id → 경로 목록. {d, role?, fill?, cls?} — fill 이면 fill=currentColor stroke=none(역할색 채움), 아니면 선. */
const ICONS = {
  'flame-1': () => flamePaths(1),
  'flame-2': () => flamePaths(2),
  'flame-3': () => flamePaths(3),
  'embers-out': () => [
    stroke('M3.5 19.5L20.5 14.5'),
    stroke('M3.5 14.5L20.5 19.5'),
    stroke(circle(3.5, 19.5, 1.4)),
    stroke(circle(20.5, 14.5, 1.4)),
    stroke('M12 11.5c-1.4-1.4 1.4-2.8 0-4.2'),
    stroke('M15 10c-.9-.9.9-1.8 0-2.7'),
  ],
  keeper: () => [
    stroke(circle(10, 8, 3.2)),
    stroke('M4 20.5c0-3.7 2.7-6.2 6-6.2s6 2.5 6 6.2'),
    lit('M18.5 3.5l2 2-2 2-2-2Z', 'agent'),
  ],
  'fingerprint-rows': () => [
    stroke('M5 3.5h14a1.5 1.5 0 0 1 1.5 1.5v14a1.5 1.5 0 0 1-1.5 1.5H5A1.5 1.5 0 0 1 3.5 19V5A1.5 1.5 0 0 1 5 3.5Z'),
    stroke('M7 7.5h4M13 7.5h4M7 10.5h4M13 10.5h4M7 13.5h4M13 13.5h4M7 16.5h4M13 16.5h4'),
  ],
  'device-iphone': () => [stroke(DEVICE_PHONE), stroke('M10.5 5.5h3')],
  'device-android': () => [stroke(DEVICE_PHONE), stroke('M10 18.5h4'), lit(circle(12, 6, 0.9), 'ink')],
  'device-pc': () => [
    stroke('M5 4.5h14a1.5 1.5 0 0 1 1.5 1.5v8.5a1.5 1.5 0 0 1-1.5 1.5H5a1.5 1.5 0 0 1-1.5-1.5V6A1.5 1.5 0 0 1 5 4.5Z'),
    stroke('M12 16v3.5M8.5 19.5h7'),
  ],
  'device-web': () => [
    stroke('M5 4.5h14a1.5 1.5 0 0 1 1.5 1.5v12a1.5 1.5 0 0 1-1.5 1.5H5A1.5 1.5 0 0 1 3.5 18V6A1.5 1.5 0 0 1 5 4.5Z'),
    stroke('M3.5 8.5h17'),
    stroke('M6.5 6.5h.01M9 6.5h.01'),
  ],
  // 자리: 작은 불 + 둘러앉은 점 5(사람 ● · 에이전트 ● / 낮불 ◆). 에이전트 점은 원·마름모를 둘 다 두고 CSS 가 테마별로 하나만 보인다.
  seat: () => [
    stroke('M12 14.5c-1.3 0-2.1-.9-2.1-2.1 0-1.5 1.3-2.5 2.1-4.6.8 2.1 2.1 3.1 2.1 4.6 0 1.2-.8 2.1-2.1 2.1Z'),
    lit(circle(4, 13.5, 1.4), 'person'),
    { ...lit(circle(6.6, 18.5, 1.4), 'agent'), cls: 'seat-circle' },
    { ...lit(diamond(6.6, 18.5, 1.7), 'agent'), cls: 'seat-diamond' },
    lit(circle(12, 20.5, 1.4), 'person'),
    { ...lit(circle(17.4, 18.5, 1.4), 'agent'), cls: 'seat-circle' },
    { ...lit(diamond(17.4, 18.5, 1.7), 'agent'), cls: 'seat-diamond' },
    lit(circle(20, 13.5, 1.4), 'person'),
  ],
  'invite-bell': () => [stroke('M6 10a6 6 0 0 1 12 0v4l1.5 2.5h-15L6 14Z'), stroke('M10 19.5a2 2 0 0 0 4 0')],
  reorder: () => [stroke('M4 7h10M4 12h10M4 17h10'), stroke('M19 5v14'), stroke('M17 7l2-2 2 2M17 17l2 2 2-2')],
  cover: () => [
    stroke('M4 16a8 8 0 0 1 16 0Z'),
    stroke('M3 19h18'),
    stroke('M12 8V6.5'),
    stroke('M12 14c-.8 0-1.3-.5-1.3-1.2 0-.9.8-1.5 1.3-2.8.5 1.3 1.3 1.9 1.3 2.8 0 .7-.5 1.2-1.3 1.2Z'),
  ],
};

export const ICON_IDS = Object.freeze(Object.keys(ICONS));

/** 'flame' + level → 'flame-N'. 그 밖은 그대로. */
export function resolveIconId(id, level) {
  if (id === 'flame') return `flame-${Math.min(3, Math.max(1, Number(level) || 1))}`;
  return id;
}

/**
 * 아이콘 명세(DOM 없음): {id, size, paths:[{d, role?, fill?, cls?}]}. 모르는 id 는 던진다(오타가 조용히 빈 자리가 되지 않게).
 * @param {string} id ICON_IDS 중 하나, 또는 'flame'(+ level)
 * @param {{size?: number, level?: number}} [options]
 */
export function iconSpec(id, { size = 24, level = 1 } = {}) {
  const key = resolveIconId(id, level);
  const build = ICONS[key];
  if (!build) throw new Error(`unknown icon: ${id}`);
  return { id: key, size: Number(size) || 24, paths: build() };
}

const pathAttrs = (p) => ({
  d: p.d,
  ...(p.role ? { 'data-role': p.role } : {}),
  ...(p.fill ? { fill: 'currentColor', stroke: 'none' } : {}),
  ...(p.role === 'unlit' ? { 'stroke-opacity': '.35' } : {}),
  ...(p.cls ? { class: p.cls } : {}),
});

const svgAttrs = (spec) => ({
  class: `ic ic-${spec.id}`,
  width: String(spec.size),
  height: String(spec.size),
  viewBox: VIEW_BOX,
  fill: 'none',
  stroke: 'currentColor',
  'stroke-width': STROKE_WIDTH,
  'stroke-linecap': 'round',
  'stroke-linejoin': 'round',
  'aria-hidden': 'true',
  focusable: 'false',
});

const escapeAttr = (value) => String(value).replace(/&/g, '&amp;').replace(/"/g, '&quot;').replace(/</g, '&lt;');
const attrString = (attrs) => Object.entries(attrs).map(([k, v]) => ` ${k}="${escapeAttr(v)}"`).join('');

/** 인라인 <svg> 문자열(테스트·정적 문서용). 앱은 icon() 으로 요소를 만든다 — innerHTML 을 쓰지 않는다. */
export function iconMarkup(id, options) {
  const spec = iconSpec(id, options);
  return `<svg${attrString(svgAttrs(spec))}>${spec.paths.map((p) => `<path${attrString(pathAttrs(p))}/>`).join('')}</svg>`;
}

const SVG_NS = 'http://www.w3.org/2000/svg';

/**
 * 인라인 <svg> 요소. 장식(aria-hidden) — 뜻은 곁의 글이나 버튼의 aria-label 이 맡는다.
 * @param {string} id
 * @param {{size?: number, level?: number, doc?: Document}} [options]
 */
export function icon(id, { doc = globalThis.document, ...options } = {}) {
  const spec = iconSpec(id, options);
  const svg = doc.createElementNS(SVG_NS, 'svg');
  for (const [k, v] of Object.entries(svgAttrs(spec))) svg.setAttribute(k, v);
  for (const p of spec.paths) {
    const path = doc.createElementNS(SVG_NS, 'path');
    for (const [k, v] of Object.entries(pathAttrs(p))) path.setAttribute(k, v);
    svg.append(path);
  }
  return svg;
}

// ---- 오늘의 불 세기(iOS RoomGlance.fireLevel 과 같은 문턱) ----

export const FIRE_WINDOW_MS = 24 * 60 * 60 * 1000;

/** 최근 24시간 글 수 → 1~3: 0~2 조용함 · 3~11 보통 · 12 이상 활발. 숫자는 화면에 내지 않는다. */
export function fireLevel(recentCount) {
  const n = Number(recentCount) || 0;
  return n >= 12 ? 3 : n >= 3 ? 2 : 1;
}

/**
 * 타임라인에서 최근 24시간의 글(text·attachment) 수. ts(ms) 가 없는 항목은 세지 않는다(iOS: 하루 지난 글은 세지 않는다).
 * @param {Array<{kind?: string, ts?: number|null}>} entries
 * @param {number} now ms
 */
export function recentMessageCount(entries, now = Date.now(), windowMs = FIRE_WINDOW_MS) {
  if (!Array.isArray(entries)) return 0;
  let count = 0;
  for (const e of entries) {
    if (!e || (e.kind !== 'text' && e.kind !== 'attachment')) continue;
    if (!Number.isFinite(e.ts) || e.ts > now || now - e.ts >= windowMs) continue;
    count += 1;
  }
  return count;
}
