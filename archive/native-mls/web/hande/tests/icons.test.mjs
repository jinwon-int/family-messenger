// 한데 고유 UI 아이콘(디자인 2차-B §B2) 테스트. node --test archive/native-mls/web/hande/tests/icons.test.mjs
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import path from 'node:path';
import { ICON_IDS, STROKE_WIDTH, VIEW_BOX, iconSpec, iconMarkup, icon, resolveIconId, fireLevel, recentMessageCount, FIRE_WINDOW_MS } from '../icons.js';
import { SHELL_ASSETS } from '../sw-policy.js';

const EXPECTED_IDS = ['flame-1', 'flame-2', 'flame-3', 'embers-out', 'keeper', 'fingerprint-rows', 'device-iphone', 'device-android', 'device-pc', 'device-web', 'seat', 'invite-bell', 'reorder', 'cover'];
/** <path> 태그 목록(낮불 ◆ 대체 경로 .seat-diamond 는 정본에 없으므로 뺀다). */
const pathTags = (svg) => [...svg.matchAll(/<path\b[^>]*>/g)].map((m) => m[0]).filter((tag) => !tag.includes('class="seat-diamond"'));
const dList = (svg) => pathTags(svg).map((tag) => tag.match(/\bd="([^"]+)"/)[1]);
const roleList = (svg) => pathTags(svg).map((tag) => tag.match(/data-role="([^"]+)"/)?.[1] ?? null);
const roles = (svg) => [...svg.matchAll(/data-role="([^"]+)"/g)].map((m) => m[1]);

test('14종 모두 24 뷰박스 · 선 1.6 · 둥근 끝 · currentColor · 장식(aria-hidden) <svg>', () => {
  assert.deepEqual([...ICON_IDS], EXPECTED_IDS);
  assert.equal(VIEW_BOX, '0 0 24 24');
  assert.equal(STROKE_WIDTH, '1.6');
  for (const id of ICON_IDS) {
    const svg = iconMarkup(id);
    assert.match(svg, /^<svg class="ic ic-[a-z0-9-]+" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true" focusable="false">/, id);
    assert.ok(svg.endsWith('</svg>'), id);
    assert.ok(dList(svg).length >= 2, `${id}: 경로 2개 이상`);
    assert.ok(!/<text|<script|<image/.test(svg), `${id}: 글·스크립트 없음`);
  }
  assert.match(iconMarkup('seat', { size: 48 }), /width="48" height="48" viewBox="0 0 24 24"/);
});

test('경로는 docs/design/icons/ui/*.svg 정본과 순서까지 같다(seat 의 낮불 ◆ 대체 경로는 제외)', () => {
  const here = path.dirname(fileURLToPath(import.meta.url));
  const dir = path.resolve(here, '../../../../../docs/design/icons/ui');
  for (const id of ICON_IDS) {
    const source = readFileSync(path.join(dir, `hande-${id}.svg`), 'utf8');
    assert.deepEqual(dList(iconMarkup(id)), dList(source), id);
    assert.deepEqual(roleList(iconMarkup(id)), roleList(source), `${id}: 경로별 역할색`);
  }
});

test('불 세기: 켜진 갈래 수 = 단계(1 가운데 ember · 2 +왼쪽 ember-deep · 3 모두), 꺼진 갈래는 unlit 선 35%', () => {
  assert.deepEqual(roles(iconMarkup('flame-1')), ['unlit', 'ember', 'unlit']);
  assert.deepEqual(roles(iconMarkup('flame-2')), ['ember-deep', 'ember', 'unlit']);
  assert.deepEqual(roles(iconMarkup('flame-3')), ['ember-deep', 'ember', 'ember-deep']);
  assert.equal((iconMarkup('flame-1').match(/stroke-opacity=".35"/g) ?? []).length, 2);
  assert.equal((iconMarkup('flame-3').match(/stroke-opacity/g) ?? []).length, 0);
  // 켜진 갈래는 채움(currentColor → CSS 역할색), 꺼진 갈래는 선만.
  assert.match(iconMarkup('flame-2'), /d="[^"]+" data-role="ember" fill="currentColor" stroke="none"/);
  assert.doesNotMatch(iconMarkup('flame-2'), /data-role="unlit" fill="currentColor"/);
  // 'flame' + level 은 flame-N 으로, 범위 밖은 1~3 으로 묶인다.
  assert.equal(resolveIconId('flame', 2), 'flame-2');
  assert.equal(iconSpec('flame', { level: 0 }).id, 'flame-1');
  assert.equal(iconSpec('flame', { level: 9 }).id, 'flame-3');
  assert.equal(iconSpec('flame').id, 'flame-1');
  assert.equal(iconMarkup('flame', { level: 3 }), iconMarkup('flame-3'));
});

test('seat: 에이전트 점은 ●(.seat-circle)과 ◆(.seat-diamond)를 둘 다 두고 CSS 가 테마별로 하나만 보인다 · keeper 의 불티는 agent 채움', () => {
  const seat = iconMarkup('seat');
  assert.equal((seat.match(/class="seat-circle"/g) ?? []).length, 2);
  assert.equal((seat.match(/class="seat-diamond"/g) ?? []).length, 2);
  assert.deepEqual(roles(seat), ['person', 'agent', 'agent', 'person', 'agent', 'agent', 'person']);
  assert.deepEqual(roles(iconMarkup('keeper')), ['agent']);
  assert.deepEqual(roles(iconMarkup('device-android')), ['ink']);
});

test('모르는 id 는 던진다(오타가 빈 자리로 조용히 지나가지 않게)', () => {
  assert.throws(() => iconMarkup('flame-4'), /unknown icon: flame-4/);
  assert.throws(() => iconSpec('bell'), /unknown icon/);
  assert.throws(() => icon('nope', { doc: { createElementNS() { throw new Error('should not be called'); } } }), /unknown icon/);
});

test('icon(): DOM 요소를 createElementNS 로만 만든다(innerHTML 없음) — 속성·경로 수가 markup 과 같다', () => {
  const made = [];
  const fakeDoc = { createElementNS(ns, tag) {
    const node = { ns, tag, attrs: {}, children: [], setAttribute(k, v) { this.attrs[k] = v; }, append(child) { this.children.push(child); } };
    made.push(node);
    return node;
  } };
  const svg = icon('flame', { level: 2, size: 26, doc: fakeDoc });
  assert.equal(svg.tag, 'svg');
  assert.equal(svg.ns, 'http://www.w3.org/2000/svg');
  assert.equal(svg.attrs.width, '26');
  assert.equal(svg.attrs.viewBox, '0 0 24 24');
  assert.equal(svg.attrs['stroke-width'], '1.6');
  assert.equal(svg.attrs['aria-hidden'], 'true');
  assert.equal(svg.children.length, 3);
  assert.deepEqual(svg.children.map((p) => p.attrs['data-role']), ['ember-deep', 'ember', 'unlit']);
  assert.equal(svg.children[2].attrs['stroke-opacity'], '.35');
  assert.equal(svg.children[1].attrs.fill, 'currentColor');
  assert.ok(made.every((n) => n.ns === 'http://www.w3.org/2000/svg'));
});

test('오늘의 불 세기: 24시간 글 수 0~2 → 1 · 3~11 → 2 · 12+ → 3(iOS RoomGlance.fireLevel 과 같다), 하루 지난 글·ts 없는 글은 세지 않는다', () => {
  assert.equal(fireLevel(0), 1);
  assert.equal(fireLevel(2), 1);
  assert.equal(fireLevel(3), 2);
  assert.equal(fireLevel(11), 2);
  assert.equal(fireLevel(12), 3);
  assert.equal(fireLevel(undefined), 1);
  const now = 200_000_000;
  const at = (secondsAgo, kind = 'text') => ({ kind, ts: now - secondsAgo * 1000 });
  assert.equal(recentMessageCount([at(90_000), at(90_001), at(90_002)], now), 0, '모두 하루 넘음');
  assert.equal(recentMessageCount([at(90_000), at(10), at(20), at(30, 'attachment')], now), 3);
  assert.equal(recentMessageCount([at(10, 'system'), at(10, 'undecryptable'), { kind: 'text', ts: null }, { kind: 'text' }], now), 0);
  assert.equal(recentMessageCount([at(-5)], now), 0, '미래 ts 는 세지 않는다');
  assert.equal(recentMessageCount([], now), 0);
  assert.equal(recentMessageCount(null, now), 0);
  assert.equal(FIRE_WINDOW_MS, 86_400_000);
  assert.equal(fireLevel(recentMessageCount(Array.from({ length: 12 }, (_, i) => at(i + 1)), now)), 3);
});

test('icons.js 는 셸 프리캐시(SHELL_ASSETS)에 들어 있다 — build.sh 복사 목록과 함께', () => {
  assert.ok(SHELL_ASSETS.includes('./icons.js'));
  const here = path.dirname(fileURLToPath(import.meta.url));
  const build = readFileSync(path.resolve(here, '../build.sh'), 'utf8');
  assert.match(build, /\bicons\.js\b/);
});
