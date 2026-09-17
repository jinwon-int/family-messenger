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
  const boot = readFileSync(join(import.meta.dirname, '..', 'boot.js'), 'utf-8');
  assert.match(boot, /window\.onerror/);
  assert.match(html, /시작 중…/);
  assert.match(html, /<noscript>/);
});

// 시트 렌더 회귀 방지(2026-09-17): dialog.replaceChildren(..., null, ...)이 텍스트 "null"을
// 화면에 그렸다. 조건부 자식은 반드시 null을 거르는 setChildren/el 경유로만 넣는다.
test('ui.js는 인자 있는 replaceChildren을 직접 호출하지 않는다', () => {
  const source = readFileSync(join(SRC, 'ui.js'), 'utf-8');
  const calls = [...source.matchAll(/replaceChildren\(([^)]*)\)/g)].map((m) => m[1].trim());
  const withArgs = calls.filter((args) => args.length > 0 && !args.startsWith('...children'));
  assert.deepEqual(withArgs, []);
});

// 해시 파일명 규칙(2026-09-17): 소스 index.html은 자리표시 참조만 갖고, build.mjs가 해시 이름으로 바꾼다.
// 수동 ?v= 버전이 다시 들어오면 옛 서비스 워커에 갇히는 회귀(#120~#122)가 재발할 수 있다.
test('index.html은 ?v= 없는 자리표시 참조만 갖고, sw.js는 템플릿 자리표시자를 갖는다', () => {
  const html = readFileSync(join(import.meta.dirname, '..', 'index.html'), 'utf-8');
  const sw = readFileSync(join(import.meta.dirname, '..', 'sw.js'), 'utf-8');
  assert.match(html, /href="\.\/styles\.css"/);
  assert.match(html, /src="\.\/boot\.js"/);
  assert.match(html, /src="\.\/main\.js"/);
  assert.doesNotMatch(html, /\?v=/);
  assert.doesNotMatch(html, /<script>|style="/, '인라인 스크립트·스타일 속성 금지(CSP)');
  assert.ok(sw.includes("'__CACHE_NAME__'") && sw.includes('__SHELL_ASSETS__'));
});

// 전송 순서 회귀 방지(2026-09-17 실기기): onSend가 동기 로컬 에코로 renderRoom을 재진입시키므로
// 작성창은 onSend 호출 *전에* 비워야 초안 보존이 보낸 본문을 되살리지 않는다.
test('composer submit은 onSend 호출 전에 작성창을 비운다', () => {
  const source = readFileSync(join(SRC, 'ui.js'), 'utf-8');
  const start = source.indexOf("class: 'composer',");
  assert.ok(start >= 0, 'composer 폼을 찾지 못했다');
  const handler = /onsubmit: \(event\) => \{[\s\S]*?\n      \},/.exec(source.slice(start))?.[0];
  assert.ok(handler, 'composer onsubmit 핸들러를 찾지 못했다');
  const clearAt = handler.indexOf("input.value = ''");
  const sendAt = handler.indexOf('onSend(');
  assert.ok(clearAt >= 0 && sendAt >= 0);
  assert.ok(clearAt < sendAt, `input.value=''(${clearAt})가 onSend(${sendAt})보다 앞서야 한다`);
});

// 스크롤 회귀 방지(2026-09-17 실기기): 셸은 높이를 고정하고 타임라인만 스크롤해야 한다.
// 기본 main의 flex:1(=basis 0%)이 height:100dvh를 덮어써 셸이 내용만큼 늘어나면
// 타임라인이 넘치지 않는 스크롤 컨테이너가 되고 overscroll-behavior:contain이 휠·터치를 삼킨다.
test('styles.css: main.shell은 flex:none + 고정 높이, .timeline은 min-height:0 스크롤러다', () => {
  const css = readFileSync(join(import.meta.dirname, '..', 'styles.css'), 'utf-8');
  const shell = /main\.shell \{[^}]*\}/.exec(css)?.[0] ?? '';
  assert.match(shell, /flex:\s*none/);
  assert.match(shell, /height:\s*100dvh/);
  const timeline = /\n\.timeline \{[^}]*\}/.exec(css)?.[0] ?? '';
  assert.match(timeline, /min-height:\s*0/);
  assert.match(timeline, /overflow-y:\s*auto/);
});

test('ui.js는 renderShell을 내보내고 main.js는 그것으로 화면을 그린다', () => {
  const ui = readFileSync(join(SRC, 'ui.js'), 'utf-8');
  const main = readFileSync(join(SRC, 'main.js'), 'utf-8');
  assert.match(ui, /export function renderShell\(/);
  assert.match(main, /ui\.renderShell\(/);
});
