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
  // 정규식 대신 문자열 검사(CodeQL js/bad-tag-filter 회피): 인라인 <script>·style= 속성이 없어야 CSP가 통한다.
  const lower = html.toLowerCase();
  assert.ok(!lower.includes('<script>'), '인라인 <script> 금지(CSP script-src self)');
  assert.ok(!lower.includes('style='), '인라인 style 속성 금지(CSP style-src self)');
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

// 휴대폰 가로모드 2열(2026-09-17 오너 요청): landscape 640~899px에서 목록·대화가 나란히 보여야 한다.
test('styles.css: 휴대폰 가로모드 미디어 쿼리가 목록|대화 2열을 켠다', () => {
  const css = readFileSync(join(import.meta.dirname, '..', 'styles.css'), 'utf-8');
  const block = /@media \(orientation: landscape\) and \(min-width: 640px\) and \(max-width: 899px\) \{[\s\S]*?\n\}/.exec(css)?.[0] ?? '';
  assert.ok(block, '가로모드 미디어 쿼리 블록이 있어야 한다');
  assert.match(block, /main\.shell \{ flex-direction: row; \}/);
  assert.match(block, /main\.shell\[data-view="room"\] \.pane-list \{ display: flex; \}/);
  assert.match(block, /\.pane-list \{[^}]*flex: 0 0 280px/);
});

// 2분할 미리보기(Page Up/Down)가 CSS가 실제로 두 pane을 보여주는 구간에서만 켜지게 한다.
test('keyboard.js 2분할 쿼리는 styles.css 미디어 쿼리와 같다', () => {
  const kb = readFileSync(join(SRC, 'keyboard.js'), 'utf-8');
  const css = readFileSync(join(import.meta.dirname, '..', 'styles.css'), 'utf-8');
  assert.match(kb, /const SPLIT_WIDE = '\(min-width: 900px\)'/);
  assert.match(kb, /const SPLIT_LANDSCAPE = '\(orientation: landscape\) and \(min-width: 640px\) and \(max-width: 899px\)'/);
  assert.match(css, /@media \(min-width: 900px\)/);
  assert.match(css, /@media \(orientation: landscape\) and \(min-width: 640px\) and \(max-width: 899px\)/);
});

// IME 회귀 방지(2026-09-17 실기기): 같은 방을 다시 그릴 때 작성창 요소를 교체하면 한글 조합이 끊겨
// "내가"가 "ㄴㅐㄱㅏ"로 깨지고 화면이 깜빡였다. renderShell은 부분 교체 경로를 유지해야 한다.
test('ui.js renderShell은 같은 방이면 composer-wrap을 교체하지 않는 부분 갱신 경로를 갖는다', () => {
  const ui = readFileSync(join(SRC, 'ui.js'), 'utf-8');
  const fn = ui.slice(ui.indexOf('export function renderShell('));
  assert.match(fn, /existingScreen\.dataset\.roomId === \(room\.room\.roomId \?\? ''\)/);
  assert.match(fn, /existingScreen\.querySelector\('\.composer-wrap'\)/);
  assert.match(fn, /built\.mount\(\{ keepComposer: true \}\)/);
  const roomSwitch = fn.indexOf('oldRoomPane.replaceWith(roomPane)');
  assert.ok(roomSwitch > 0, '방 전환은 방 pane만 교체해야 한다');
  assert.ok(fn.indexOf('built.mount({ keepComposer: true })') < roomSwitch, '부분 갱신 경로가 전체 재구성보다 먼저 와야 한다');
  // #194 후속: 방 전환에서 main.shell을 통째 바꾸면 보관함(파일보관함 iframe)이 다시 로드된다.
  assert.equal(fn.indexOf('existingShell.replaceWith('), -1, '방 전환이 main.shell을 통째로 교체하면 안 된다');
  // 시트 회귀 방지(2026-09-17 실기기): 전체 재구성이 열린 <dialog>를 떼었다 붙이면 top layer에서 빠져
  // "첨부처럼" 인라인으로 깔린다. root.replaceChildren()로 전부 지우는 경로가 있으면 안 된다.
  assert.equal(fn.indexOf('root.replaceChildren()'), -1, '전체 재구성은 root를 통째로 비우면 안 된다');
});

// 매번 기기 검증 회귀 방지(2026-09-17 실기기): 재로그인이 저장된 device_id를 재사용해야 새 기기가 생기지 않는다.
test('main.js는 같은 계정 재로그인에 저장된 deviceId를 넘긴다', () => {
  const main = readFileSync(join(SRC, 'main.js'), 'utf-8');
  assert.match(main, /deviceId: sameUser \? stored\.deviceId : undefined/);
  // 저장소 없는 ID 재사용 금지(2026-09-18): 재사용 조건에 cryptoDeviceId 일치가 포함돼야 한다.
  assert.match(main, /stored\.cryptoDeviceId === stored\.deviceId/);
  assert.match(main, /session\.saveSession\(\{ cryptoDeviceId: creds\.deviceId \}, stores\)/);
  assert.match(main, /deviceDisplayName: strings\.login\.deviceName/);
});

// 재로그인 저장소 불일치 회귀 방지(2026-09-17): 새 로그인은 저장소를 먼저 비우고, 복원 세션은 불일치일 때만 비우고 재시도.
test('main.js는 로그인 시 저장소를 지우지 않고, 불일치·손상 오류에 한해 기기별 저장소를 비우고 재시도한다', () => {
  const main = readFileSync(join(SRC, 'main.js'), 'utf-8');
  assert.match(main, /account in the store doesn't match/);
  assert.match(main, /if \(isStoreMismatch\(error\) \|\| isBrokenStore\(error\)\)/);
  assert.doesNotMatch(main, /if \(fresh\) \{\s*try \{\s*await client\.resetLocalStores/, '로그인 시 저장소 삭제는 blocked 경쟁을 만든다 — 기기별 이름으로 대체');
});

// 타이핑 표시 정합성(2026-09-18): 초안 복원이 만드는 프로그램적 input 이벤트(isTrusted=false)를
// 타이핑으로 치면 방을 열기만 해도 상대에게 "입력중입니다"가 떴다. 가드는 onTyping 호출보다 앞에 있어야 한다.
test('composer oninput은 isTrusted 가드 뒤에서만 onTyping을 부른다', () => {
  const source = readFileSync(join(SRC, 'ui.js'), 'utf-8');
  const guardAt = source.indexOf('if (event.isTrusted)');
  const callAt = source.indexOf('onTyping?.(');
  assert.ok(guardAt >= 0, 'isTrusted 가드가 있어야 한다');
  assert.ok(callAt > guardAt, 'onTyping 호출은 가드 뒤에 있어야 한다');
});

// ES2020 하한 회귀 방지(#167): build.mjs가 target es2020을 명시하는 근거는 실제
// 사고다 — esnext 기본값이 구형 모바일 브라우저에서 파싱 실패로 빈 화면을 만들었다
// (2026-09-16 첫 공개 관측). esbuild는 문법은 낮춰도 **메서드는 폴리필하지 않으므로**
// ES2021+ 메서드를 쓰면 번들에 그대로 남아 런타임에서 조용히 터진다.
// sw.js는 번들조차 거치지 않아 소스가 곧 배포본이다.
test('런타임 소스는 ES2021+ 메서드를 쓰지 않는다', () => {
  const banned = [
    ['replaceAll', /\.replaceAll\s*\(/],      // ES2021
    ['at', /\.at\s*\(\s*-/],                  // ES2022 (음수 인덱스 용법)
    ['findLast', /\.findLast(Index)?\s*\(/],  // ES2023
    ['hasOwn', /\bObject\.hasOwn\s*\(/],      // ES2022
    ['structuredClone', /\bstructuredClone\s*\(/],
  ];
  const files = [
    ...readdirSync(SRC).filter((n) => n.endsWith('.js')).map((n) => ['src/' + n, join(SRC, n)]),
    ['sw.js', join(import.meta.dirname, '..', 'sw.js')],
  ];
  const offenders = [];
  for (const [label, path] of files) {
    const source = readFileSync(path, 'utf-8');
    for (const [name, pattern] of banned) {
      if (pattern.test(source)) offenders.push(`${label}: ${name}`);
    }
  }
  assert.deepEqual(offenders, []);
});

// 사용자 제스처 보존(#167 C): Notification.requestPermission()은 사용자 제스처
// 안에서 불려야 한다. 다른 비동기 작업을 먼저 기다리면 제스처가 끊겨 브라우저가
// 요청을 조용히 무시하고, 알림 켜기 버튼이 아무 일도 안 하는 것처럼 보인다.
// 이 클래스의 회귀는 시험으로 잡기 어려워(제스처는 모킹되지 않는다) 정적으로 막는다.
test('알림 켜기: requestPermission이 클릭 핸들러의 첫 await다', () => {
  const source = readFileSync(join(SRC, 'main.js'), 'utf-8');
  const enableBlock = source.slice(source.indexOf('enable: async () =>'));
  assert.ok(enableBlock.length > 0, 'enable 핸들러를 찾지 못했다');
  const body = enableBlock.slice(0, enableBlock.indexOf('disable: async () =>'));
  const firstAwait = body.match(/await\s+([^\s;(]+)/);
  assert.ok(firstAwait, 'enable 핸들러에 await가 없다');
  assert.equal(firstAwait[1], 'Notification.requestPermission', `첫 await가 ${firstAwait[1]}이다 — 제스처가 끊긴다`);
});

// #176 검토(2026-09-21) High 1·2, Medium 3b — 셋 다 main.js에 있어 DOM/단위 시험이
// 닿지 않는다. 배선이 빠지면 조용히 옛 결함으로 돌아가므로 정적으로 막는다.
test('알림 재개·상태 판정 배선: 끄기 선호를 존중하고, pusher를 교차 확인하고, SW ready에 상한을 둔다', () => {
  const source = readFileSync(join(SRC, 'main.js'), 'utf-8');
  const block = (start, end) => {
    const from = source.indexOf(start);
    assert.ok(from >= 0, `${start}를 찾지 못했다`);
    const to = source.indexOf(end, from);
    return source.slice(from, to > from ? to : undefined);
  };

  // High 1: 사용자가 끈 뒤 새로고침하면 권한이 granted라도 되살리지 않는다.
  const resume = block('async function resumePush()', 'catch (error)');
  const guardAt = resume.indexOf("readPushPreference(stores) === 'off'");
  const enableAt = resume.indexOf('enablePush(');
  assert.ok(guardAt >= 0, 'resumePush가 끄기 선호를 읽지 않는다 — 끄기가 새로고침 한 번에 무효가 된다');
  assert.ok(enableAt > guardAt, '끄기 선호 확인이 enablePush보다 뒤에 있다');

  // High 2: 브라우저 구독만으로 "켜짐"이라 하지 않는다 — 홈서버 pusher를 교차 확인한다.
  const availability = block('async function readPushAvailability()', 'return pushAvailability(');
  assert.ok(availability.includes('hasMatchingPusher('), 'readPushAvailability가 pusher를 확인하지 않는다 — 구독만 있고 pusher가 없으면 거짓 "켜짐"이 뜬다');
  assert.ok(availability.includes('getPushers()'), 'readPushAvailability가 홈서버 pusher 목록을 조회하지 않는다');

  // Medium 3b: navigator.serviceWorker.ready는 등록이 없으면 영원히 pending이라
  // 반드시 상한이 있는 serviceWorkerReady()를 통해서만 기다린다.
  const codeOnly = source.split('\n').filter((line) => !line.trim().startsWith('//')).join('\n');
  const rawReady = codeOnly.split('navigator.serviceWorker.ready').length - 1;
  assert.equal(rawReady, 1, `navigator.serviceWorker.ready 직접 참조가 ${rawReady}곳 — serviceWorkerReady() 안 한 곳만 허용`);
  const helper = block('async function serviceWorkerReady()', '\n}\n');
  assert.ok(helper.includes('navigator.serviceWorker.ready') && helper.includes('Promise.race('), 'serviceWorkerReady()가 상한 없이 ready를 기다린다');
});
