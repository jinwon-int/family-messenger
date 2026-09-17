import test from 'node:test';
import assert from 'node:assert/strict';
import { allStringsFilled, strings } from '../src/strings.js';

test('모든 문자열 표 항목이 채워져 있다', () => {
  assert.equal(allStringsFilled(), true);
});

test('주요 화면의 키가 존재한다', () => {
  for (const key of ['appName', 'login', 'rooms', 'invite', 'chat', 'participants', 'verification', 'recovery', 'media', 'errors']) {
    assert.ok(key in strings, `strings.${key} missing`);
  }
  for (const key of ['submit', 'submitting', 'error', 'homeserverLabel', 'userLabel', 'passwordLabel']) {
    assert.ok(key in strings.login, `strings.login.${key} missing`);
  }
  for (const key of ['start', 'same', 'different', 'done', 'cancelled', 'close']) {
    assert.ok(key in strings.verification, `strings.verification.${key} missing`);
  }
  for (const key of ['showOnceHeading', 'confirm', 'mismatch', 'done', 'privacy']) {
    assert.ok(key in strings.recovery, `strings.recovery.${key} missing`);
  }
});

test('사용자에게 보이는 문구는 한국어다', () => {
  const korean = (value) => /[\uAC00-\uD7A3]/.test(value);
  assert.ok(korean(strings.appName));
  // 입력 예시(placeholder)는 URL 등 비한국어 값이 될 수 있으므로 제외한다.
  const visible = (obj) => Object.entries(obj).filter(([key, value]) => typeof value === 'string' && !key.endsWith('Placeholder'));
  for (const [, value] of visible(strings.login)) {
    assert.ok(korean(value), `non-Korean login copy: ${value}`);
  }
  for (const [, value] of visible(strings.recovery)) {
    assert.ok(korean(value), `non-Korean recovery copy: ${value}`);
  }
  for (const value of Object.values(strings.errors)) {
    assert.ok(korean(value), `non-Korean error copy: ${value}`);
  }
});

test('동적 문구(함수)는 문자열을 반환한다', () => {
  assert.equal(strings.rooms.memberCount(3), '멤버 3명');
  assert.equal(strings.invite.from('아빠'), '아빠님이 초대했습니다');
});

// 미사용 문구 방지(2026-09-17 #126): strings의 모든 리프는 src/에서 한 번은 참조돼야 한다.
import { readdirSync, readFileSync } from 'node:fs';
import { join } from 'node:path';
test('strings 리프는 전부 src에서 참조된다', () => {
  const SRC = join(import.meta.dirname, '..', 'src');
  const sources = readdirSync(SRC).filter((n) => n.endsWith('.js') && n !== 'strings.js').map((n) => readFileSync(join(SRC, n), 'utf-8')).join('\n')
    + readFileSync(join(SRC, 'matrix', 'client.js'), 'utf-8');
  const unused = [];
  const walk = (node, path) => {
    if (typeof node === 'string' || typeof node === 'function') {
      const leaf = path[path.length - 1];
      const pattern = new RegExp(`strings\\.${path.join('\\.')}\\b|\\b${leaf}\\b`);
      if (!pattern.test(sources)) unused.push(path.join('.'));
      return;
    }
    for (const [key, value] of Object.entries(node)) walk(value, [...path, key]);
  };
  walk(strings, []);
  assert.deepEqual(unused, []);
});
