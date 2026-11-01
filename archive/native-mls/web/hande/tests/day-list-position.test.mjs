// #640: 낮불 대화 목록에서 PageUp/PageDown 위치(열린 방·키 포커스)가 먹 테두리에 묻히지 않게 하는 규칙의 회귀 검사.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

const css = readFileSync(new URL('../styles.css', import.meta.url), 'utf8');
// 오너 2026-11-01 "더 얇게, 테두리만 구분이 가면 돼": 막대 없이 안쪽 링 1px 로 테두리만 2.5px(다른 행 1.5).
const RING = 'box-shadow: inset 0 0 0 1px var(--room-current-line);';

/** 줄 첫머리부터 선택자 목록 전체가 `selector` 인 규칙의 본문(첫 일치). 없으면 null.
 *  (선택자 목록의 꼬리만 같은 규칙 — `a, b {` 의 `b {` — 을 잘못 집지 않게 줄 시작에 고정한다.) */
function ruleBody(selector) {
  const escaped = selector.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  const match = new RegExp(`^[ \\t]*${escaped} \\{([^}]*)\\}`, 'm').exec(css);
  return match ? match[1].trim() : null;
}

for (const theme of ['day', 'auto']) {
  test(`${theme}: 열린 방과 키 포커스 행 = 안쪽 링 1px(테두리 2.5px), 막대 없음`, () => {
    const selector = `html[data-theme="${theme}"] .room-item[aria-current="true"], html[data-theme="${theme}"] .room-item:focus-visible`;
    assert.equal(ruleBody(selector), RING);
    assert.ok(!css.includes('inset 8px 0 0'), '왼쪽 막대는 쓰지 않는다');
  });

  test(`${theme}: 키 포커스는 전역 3px 외곽선을 끄고 링만 쓴다(이중선 없음)`, () => {
    assert.equal(ruleBody(`html[data-theme="${theme}"] .room-item:focus-visible`), 'outline: none;');
  });
}

test('auto 규칙은 밝은 시스템(prefers-color-scheme: light) 안에서만 적용된다', () => {
  const media = css.lastIndexOf('@media (prefers-color-scheme: light) {', css.indexOf('html[data-theme="auto"] .room-item[aria-current="true"]'));
  assert.ok(media >= 0, 'auto 규칙 앞에 라이트 미디어 쿼리가 있어야 한다');
  const between = css.slice(media, css.indexOf('html[data-theme="auto"] .room-item[aria-current="true"]'));
  assert.ok(!between.includes('\n}'), 'auto 규칙이 미디어 쿼리 블록 밖으로 빠지면 밤(auto-dark)에도 막대가 그려진다');
});

test('밤(기본) 규칙은 그대로 — 열린 방은 테두리색·면만', () => {
  assert.equal(ruleBody('.room-item[aria-current="true"]'), 'border-color: var(--room-current-line); background: var(--brand-soft);');
  assert.ok(!/^\.room-item:focus-visible\s*\{/m.test(css), '밤 키 포커스는 전역 :focus-visible(크림 3px)을 그대로 쓴다');
});
