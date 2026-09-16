// 빈 화면 회귀 방지(#92, 2026-09-16): ui.js가 strings를 import하지 않은 채 62회
// 참조해 첫 렌더 ReferenceError → 전 브라우저 빈 화면이 된 실측 결함의 정적 방어.
// node --test는 DOM 없이 모듈만 검사하므로 이 클래스의 결함을 못 잡았다.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readdirSync, readFileSync } from 'node:fs';
import { join } from 'node:path';

const SRC = join(import.meta.dirname, '..', 'src');

test('strings.을 쓰는 모든 src 모듈은 strings.js를 import한다', () => {
  const offenders = [];
  for (const name of readdirSync(SRC)) {
    if (!name.endsWith('.js')) continue;
    const source = readFileSync(join(SRC, name), 'utf-8');
    const usesStrings = /(^|[^.\w])strings\./m.test(source);
    const importsStrings = /import\s*\{[^}]*\bstrings\b[^}]*\}\s*from\s*'\.\/strings\.js'/.test(source);
    if (usesStrings && !importsStrings) offenders.push(name);
  }
  assert.deepEqual(offenders, []);
});

test('index.html은 모듈 실패 시 사용자에게 보이는 폴백을 가진다', () => {
  const html = readFileSync(join(import.meta.dirname, '..', 'index.html'), 'utf-8');
  assert.match(html, /window\.onerror/);
  assert.match(html, /시작 중…/);
  assert.match(html, /<noscript>/);
});
