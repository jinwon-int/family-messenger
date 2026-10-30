import test from 'node:test';
import assert from 'node:assert/strict';
import { THEME_KEY, THEMES, DEFAULT_THEME, THEME_COLORS, readTheme, writeTheme, resolveTheme, applyTheme } from '../theme.js';

const fakeStorage = (init = {}) => {
  const map = new Map(Object.entries(init));
  return { map, getItem: (k) => (map.has(k) ? map.get(k) : null), setItem: (k, v) => map.set(k, String(v)), removeItem: (k) => map.delete(k) };
};
const fakeDoc = () => {
  const meta = { attrs: {}, setAttribute(k, v) { this.attrs[k] = v; } };
  return { documentElement: { dataset: {} }, querySelector: (sel) => (sel === 'meta[name="theme-color"]' ? meta : null), meta };
};

test('readTheme: 기본은 밤 — 저장값 없음·모르는 값·막힌 저장소 모두 night (시스템 라이트를 따라가지 않는다)', () => {
  assert.equal(DEFAULT_THEME, 'night');
  assert.deepEqual(THEMES, ['night', 'day', 'auto']);
  assert.equal(THEME_KEY, 'hande:theme');
  assert.equal(readTheme(fakeStorage()), 'night');
  assert.equal(readTheme(fakeStorage({ [THEME_KEY]: 'light' })), 'night');
  assert.equal(readTheme({ getItem() { throw new Error('blocked'); } }), 'night');
  assert.equal(readTheme(null), 'night');
  assert.equal(readTheme(fakeStorage({ [THEME_KEY]: 'day' })), 'day');
  assert.equal(readTheme(fakeStorage({ [THEME_KEY]: 'auto' })), 'auto');
});

test('writeTheme: day/auto 는 저장, night(기본)는 키를 지운다, 모르는 값은 night', () => {
  const storage = fakeStorage();
  assert.equal(writeTheme(storage, 'day'), 'day');
  assert.equal(storage.getItem(THEME_KEY), 'day');
  assert.equal(writeTheme(storage, 'auto'), 'auto');
  assert.equal(storage.getItem(THEME_KEY), 'auto');
  assert.equal(writeTheme(storage, 'night'), 'night');
  assert.equal(storage.getItem(THEME_KEY), null);
  assert.equal(writeTheme(storage, 'bogus'), 'night');
  assert.equal(storage.getItem(THEME_KEY), null);
  assert.equal(writeTheme({ setItem() { throw new Error('blocked'); }, removeItem() {} }, 'day'), 'day', '저장 실패해도 값은 돌려준다');
});

test('resolveTheme: auto 만 시스템을 본다', () => {
  assert.equal(resolveTheme('night', true), 'night');
  assert.equal(resolveTheme('day', false), 'day');
  assert.equal(resolveTheme('auto', true), 'day');
  assert.equal(resolveTheme('auto', false), 'night');
  assert.equal(resolveTheme(undefined, true), 'night');
});

test('applyTheme: html[data-theme] + theme-color 메타(밤 #0F1324 / 낮불 #F7F3EA)', () => {
  const doc = fakeDoc();
  assert.equal(applyTheme('day', doc), 'day');
  assert.equal(doc.documentElement.dataset.theme, 'day');
  assert.equal(doc.meta.attrs.content, THEME_COLORS.day);
  assert.equal(THEME_COLORS.day, '#F7F3EA');
  applyTheme('night', doc, true);
  assert.equal(doc.documentElement.dataset.theme, 'night');
  assert.equal(doc.meta.attrs.content, '#0F1324');
  applyTheme('auto', doc, true);
  assert.equal(doc.documentElement.dataset.theme, 'auto', 'auto 는 CSS 미디어 쿼리가 고르도록 속성값을 그대로 둔다');
  assert.equal(doc.meta.attrs.content, '#F7F3EA');
  applyTheme('auto', doc, false);
  assert.equal(doc.meta.attrs.content, '#0F1324');
  applyTheme('weird', doc);
  assert.equal(doc.documentElement.dataset.theme, 'night');
  assert.doesNotThrow(() => applyTheme('day', { documentElement: { dataset: {} }, querySelector: () => null }), '메타가 없어도 된다');
});
