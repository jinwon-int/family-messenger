// #766 I: 시작 구간 계측(startup-timing.js) — 구간별 ms, 합 = 전체, 한 번만 끝남, 기록에 식별값 없음.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { createStartupTiming, startupLine, MAX_STAGES, STARTUP_LABELS, STARTUP_PHASE_LABELS } from '../startup-timing.js';
import { summarizeStartupNetwork, readStartupNetwork, startupNetworkLine } from '../startup-timing.js';

/** 대본 시계: 부를 때마다 다음 값을 준다(끝나면 마지막 값 유지). */
function clockOf(...values) {
  let i = 0;
  return () => values[Math.min(i++, values.length - 1)];
}

test('구간 ms 는 앞 구간이 끝난 뒤부터의 시간이고 합은 전체와 같다', () => {
  const t = createStartupTiming({ now: clockOf(412, 427, 2330, 2418, 2431, 2440) });
  for (const name of ['script', 'config', 'identity', 'rooms', 'listing']) t.mark(name);
  const s = t.finish('ready');
  assert.deepEqual(s.stages.map((x) => [x.name, x.ms]), [['script', 412], ['config', 15], ['identity', 1903], ['rooms', 88], ['listing', 13], ['paint', 9]]);
  assert.equal(s.total, 2440);
  assert.equal(s.stages.reduce((n, x) => n + x.ms, 0), s.total);
  assert.equal(s.phase, 'ready');
  assert.equal(s.stages.at(-1).at, 2440);
});

test('앱 기록 한 줄: 화면 말로 바꾸고 전체 ms 를 앞에 둔다', () => {
  const t = createStartupTiming({ now: clockOf(412, 427, 2330, 2418, 2431, 2431) });
  for (const name of ['script', 'config', 'identity', 'rooms', 'listing']) t.mark(name);
  assert.equal(startupLine(t.finish('ready')),
    '첫 화면까지 2431 ms (대화 화면) — 스크립트 412 · 설정 15 · 신원 열기 1903 · 방 열기 88 · 방 목록 13');
  assert.equal(startupLine(null), '');
});

test('저장분으로 먼저 그린 첫 화면(#766 B)은 화면 이름으로 구분되고 방 목록 구간이 없다', () => {
  const t = createStartupTiming({ now: clockOf(412, 427, 628, 652, 660, 2000) });
  for (const name of ['script', 'config', 'identity', 'rooms']) t.mark(name);
  const s = t.finish('stored');
  t.mark('listing');   // 그린 뒤에 온 방 목록 응답은 줄에 들어가지 않는다
  assert.equal(startupLine(s), '첫 화면까지 660 ms (대화 화면 · 저장분) — 스크립트 412 · 설정 15 · 신원 열기 201 · 방 열기 24 · 그리기 8');
  assert.equal(startupLine(t.summary()), startupLine(s));
  assert.notEqual(STARTUP_PHASE_LABELS.stored, STARTUP_PHASE_LABELS.ready);
});

test('마지막 구간과 같은 시각에 끝나면 그리기 구간을 만들지 않는다', () => {
  const t = createStartupTiming({ now: clockOf(100, 100) });
  t.mark('script');
  assert.deepEqual(t.finish('needsActor').stages.map((x) => x.name), ['script']);
});

test('finish 는 처음 한 번만 요약을 준다 — 다시 그려도 줄이 또 남지 않는다', () => {
  const t = createStartupTiming({ now: clockOf(10, 20, 999) });
  t.mark('script');
  assert.equal(t.finished, false);
  const first = t.finish('ready');
  assert.equal(first.total, 20);
  assert.equal(t.finished, true);
  assert.equal(t.finish('enroll'), null);
  assert.deepEqual(t.summary(), first);
});

test('끝난 뒤의 mark 와 같은 이름의 두 번째 mark 는 무시한다(복구 경로 재시도)', () => {
  const t = createStartupTiming({ now: clockOf(10, 20, 30, 40, 50) });
  t.mark('script'); t.mark('identity'); t.mark('identity');
  const s = t.finish('ready');
  t.mark('listing');
  assert.deepEqual(t.summary().stages.map((x) => x.name), ['script', 'identity', 'paint']);
  assert.equal(s.stages[1].ms, 10);
});

test('시계가 뒤로 가도 구간은 음수가 되지 않고 합은 전체와 같다', () => {
  const t = createStartupTiming({ now: clockOf(500, 300, 900, 100) });
  t.mark('script'); t.mark('config'); t.mark('identity');
  const s = t.finish('ready');
  assert.ok(s.stages.every((x) => x.ms >= 0), JSON.stringify(s.stages));
  assert.equal(s.stages.reduce((n, x) => n + x.ms, 0), s.total);
  assert.equal(s.total, 900);
});

test('시계가 없거나 던지거나 숫자가 아니어도 죽지 않는다', () => {
  for (const now of [undefined, () => { throw new Error('no clock'); }, () => NaN, () => 'x', () => -5]) {
    const t = now === undefined ? createStartupTiming() : createStartupTiming({ now });
    t.mark('script');
    const s = t.finish('ready');
    assert.equal(s.total, 0);
    assert.equal(startupLine(s), '첫 화면까지 0 ms (대화 화면) — 스크립트 0');
  }
});

test('구간 수 상한을 넘기지 않는다', () => {
  let n = 0;
  const t = createStartupTiming({ now: () => ++n });
  for (let i = 0; i < MAX_STAGES + 10; i++) t.mark(`s${i}`);
  assert.equal(t.finish('ready').stages.filter((x) => x.name !== 'paint').length, MAX_STAGES);
});

test('구간·화면 이름은 글자·숫자·-_ 만 남기고 24자에서 자른다(주소·기호가 기록 줄에 섞이지 않는다)', () => {
  const t = createStartupTiming({ now: clockOf(1, 3) });
  t.mark('rooms owner-web-87576b https://relay.example/v2/rooms?x=1');
  const line = startupLine(t.finish('ready <script>'), { labels: {}, phaseLabels: {} });
  assert.equal(line, '첫 화면까지 3 ms (readyscript) — roomsowner-web-87576bhtt 1 · paint 2');
  assert.doesNotMatch(line, /https|\/\/|[?=<>]/);
});

test('모르는 구간·화면 이름은 그대로 보여 준다', () => {
  const t = createStartupTiming({ now: clockOf(5, 9) });
  t.mark('extra');
  assert.equal(startupLine(t.finish('later')), '첫 화면까지 9 ms (later) — extra 5 · 그리기 4');
});

test('앱이 쓰는 구간·화면에는 모두 화면 말이 있다', () => {
  const app = readFileSync(new URL('../app.js', import.meta.url), 'utf8');
  const marks = [...app.matchAll(/timing\.mark\('([^']+)'\)/g)].map((m) => m[1]);
  assert.deepEqual(marks, ['script', 'config', 'identity', 'rooms', 'listing']);
  for (const name of [...marks, 'paint']) assert.ok(STARTUP_LABELS[name], name);
  for (const phase of ['ready', 'stored', 'enroll', 'needsActor', 'fatal']) assert.ok(STARTUP_PHASE_LABELS[phase], phase);
});

test('앱 배선: 시작 화면을 벗어난 첫 그리기에서만 끝내고, 진단 복사 요약에도 싣는다', () => {
  const app = readFileSync(new URL('../app.js', import.meta.url), 'utf8');
  assert.match(app, /updatePhase\(\); paint\(\); noteFirstScreen\(\);/);
  assert.match(app, /function noteFirstScreen\(\) \{\s*if \(timing\.finished \|\| app\.phase === 'starting'\) return;/);
  // #766 B: 방 목록 응답 전에 그린 대화 화면은 'stored' 로 끝낸다.
  assert.match(app, /timing\.finish\(app\.phase === 'ready' && app\.dev\?\.state\.enrolled !== true \? 'stored' : app\.phase\)/);
  assert.match(app, /const startup = app\.startup \? `startup: \$\{startupLine\(app\.startup\)\}` : 'startup: -';/);
  assert.match(app, /, me, startup, 'rooms:',/);
});

test('startup-timing.js 가 build.sh 배포 목록·SHELL_ASSETS·modulepreload 에 있다', async () => {
  const { SHELL_ASSETS } = await import('../sw-policy.js');
  assert.ok(SHELL_ASSETS.includes('./startup-timing.js'));
  assert.match(readFileSync(new URL('../build.sh', import.meta.url), 'utf8'), /\sstartup-timing\.js\s/);
  assert.match(readFileSync(new URL('../index.html', import.meta.url), 'utf8'), /modulepreload" href="\.\/startup-timing\.js"/);
});

// ---- 시작 네트워크 줄: 「스크립트」 구간을 Navigation/Resource Timing 으로 나눈다 ----

const ORIGIN = 'https://app.example';
const nav = (over = {}) => ({ name: `${ORIGIN}/`, redirectStart: 0, redirectEnd: 0, workerStart: 0, fetchStart: 12.4, responseStart: 309.6, responseEnd: 325.2, ...over });
/** 리소스 항목. 기본은 304 재검증(헤더 300바이트, 본문 9000바이트는 캐시에서). */
const res = (path, responseEnd, over = {}) => ({ name: /^[a-z]+:/.test(path) ? path : `${ORIGIN}/${path}`, responseEnd, transferSize: 300, encodedBodySize: 9000, decodedBodySize: 30000, workerStart: 0, ...over });
const full = (path, responseEnd, bytes, over = {}) => res(path, responseEnd, { transferSize: bytes + 300, encodedBodySize: bytes, decodedBodySize: bytes * 3, ...over });
const cached = (path, responseEnd, over = {}) => res(path, responseEnd, { transferSize: 0, ...over });

test('시작 네트워크 — 보통: 문서 시각, 파일 수·분류·전송량, 마지막 파일, 그 뒤 실행 시간', () => {
  const resources = [
    ...Array.from({ length: 40 }, (_, i) => res(`m${i}.js`, 400 + i * 30)),   // 재검증 40
    res('styles.css', 380.2),                                                 // 재검증
    full('ui.js', 1889.7, 12000),                                             // 다 받음(12 KB) — 가장 늦게 끝남
  ];
  const s = summarizeStartupNetwork(nav(), resources, { scriptAt: 2576, controlled: false });
  assert.deepEqual(s, {
    redirect: 0, workerStart: 0, fetchStart: 12, responseStart: 310, responseEnd: 325, scriptAt: 2576, controlled: false,
    files: { count: 42, cached: 0, revalidated: 41, transferred: 1, unknown: 0, kb: 24, viaWorker: 0, lastAt: 1890, lastName: 'ui.js', gap: 686 },
  });
  assert.equal(startupNetworkLine(s),
    '시작 네트워크: 리다이렉트 0 · HTML 요청 12 · HTML 응답 310 · HTML 끝 325 · 파일 42개 (캐시 0 · 재검증 41 · 받음 1 · 전송 24 KB)'
    + ' · 마지막 파일 ui.js 1890 · 서비스 워커 경유 0 (제어 없음) · 파일 뒤 실행 686 · 스크립트 시작 2576');
  assert.equal(s.files.lastAt + s.files.gap, s.scriptAt);
  assert.equal(s.files.cached + s.files.revalidated + s.files.transferred + s.files.unknown, s.files.count);
});

test('시작 네트워크 — 리다이렉트는 redirectEnd − redirectStart, 없으면 0', () => {
  assert.equal(summarizeStartupNetwork(nav({ redirectStart: 3.2, redirectEnd: 843.9 }), [], { scriptAt: 2000 }).redirect, 841);
  assert.equal(summarizeStartupNetwork(nav({ redirectStart: undefined, redirectEnd: undefined }), [], { scriptAt: 2000 }).redirect, 0);
  // 시계가 어긋나도 음수는 없다.
  assert.equal(summarizeStartupNetwork(nav({ redirectStart: 50, redirectEnd: 10 }), [], { scriptAt: 2000 }).redirect, 0);
});

test('시작 네트워크 — 모두 캐시: 네트워크를 타지 않은 파일은 캐시로 세고 전송 0 KB', () => {
  const resources = [cached('app.js', 40), cached('ui.js', 55.5), cached('styles.css', 31), cached('icons.js', 44, { encodedBodySize: 0, decodedBodySize: 0, deliveryType: 'cache' })];
  const s = summarizeStartupNetwork(nav({ fetchStart: 2, responseStart: 9, responseEnd: 11 }), resources, { scriptAt: 120 });
  assert.deepEqual(s.files, { count: 4, cached: 4, revalidated: 0, transferred: 0, unknown: 0, kb: 0, viaWorker: 0, lastAt: 56, lastName: 'ui.js', gap: 64 });
  assert.equal(startupNetworkLine(s),
    '시작 네트워크: 리다이렉트 0 · HTML 요청 2 · HTML 응답 9 · HTML 끝 11 · 파일 4개 (캐시 4 · 재검증 0 · 받음 0 · 전송 0 KB)'
    + ' · 마지막 파일 ui.js 56 · 서비스 워커 경유 0 · 파일 뒤 실행 64 · 스크립트 시작 120');
});

test('시작 네트워크 — 분류 경계: 304 는 전송량 < 본문, 작은 파일의 304 는 responseStatus 가 있어야 재검증', () => {
  const one = (entry) => {
    const f = summarizeStartupNetwork(nav(), [entry], { scriptAt: 1000 }).files;
    return ['cached', 'revalidated', 'transferred', 'unknown'].filter((k) => f[k] === 1).join();
  };
  assert.equal(one(res('a.js', 500)), 'revalidated');
  assert.equal(one(full('a.js', 500, 9000)), 'transferred');
  assert.equal(one(cached('a.js', 500)), 'cached');
  assert.equal(one(cached('a.js', 500, { encodedBodySize: 0, decodedBodySize: 4000 })), 'cached');
  // 크기를 하나도 알려 주지 않은 응답은 모름 — 캐시로 세지 않는다.
  assert.equal(one(cached('a.js', 500, { encodedBodySize: 0, decodedBodySize: 0 })), 'unknown');
  // 본문 120바이트 파일의 304: 헤더(300)가 본문보다 커서 크기만으로는 「받음」, responseStatus 가 있으면 「재검증」.
  assert.equal(one(res('tiny.js', 500, { transferSize: 300, encodedBodySize: 120 })), 'transferred');
  assert.equal(one(res('tiny.js', 500, { transferSize: 300, encodedBodySize: 120, responseStatus: 304 })), 'revalidated');
  assert.equal(one(full('a.js', 500, 9000, { responseStatus: 200 })), 'transferred');
});

test('시작 네트워크 — 서비스 워커: 경유한 파일 수·문서의 워커 시작·제어 여부, 크기를 못 받은 응답은 모름', () => {
  const resources = [
    res('app.js', 900, { workerStart: 330 }),
    full('ui.js', 1400, 50000, { workerStart: 331 }),
    cached('strings.js', 700, { workerStart: 332, encodedBodySize: 0, decodedBodySize: 0 }),   // 워커가 답했고 브라우저가 크기를 주지 않음
    res('styles.css', 600),                                                                     // 워커를 거치지 않음
  ];
  const s = summarizeStartupNetwork(nav({ workerStart: 4.6, fetchStart: 180.2 }), resources, { scriptAt: 1500, controlled: true });
  assert.equal(s.workerStart, 5);
  assert.deepEqual(s.files, { count: 4, cached: 0, revalidated: 2, transferred: 1, unknown: 1, kb: 50, viaWorker: 3, lastAt: 1400, lastName: 'ui.js', gap: 100 });
  assert.equal(startupNetworkLine(s),
    '시작 네트워크: 리다이렉트 0 · 워커 시작 5 · HTML 요청 180 · HTML 응답 310 · HTML 끝 325 · 파일 4개 (캐시 0 · 재검증 2 · 받음 1 · 모름 1 · 전송 50 KB)'
    + ' · 마지막 파일 ui.js 1400 · 서비스 워커 경유 3 (제어 중) · 파일 뒤 실행 100 · 스크립트 시작 1500');
});

test('시작 네트워크 — 문서 항목이 없으면 요약도 줄도 없다', () => {
  for (const missing of [undefined, null, 0, 'navigation']) {
    assert.equal(summarizeStartupNetwork(missing, [res('app.js', 100)], { scriptAt: 500 }), null);
  }
  assert.equal(startupNetworkLine(null), '');
  assert.equal(startupNetworkLine(undefined), '');
});

test('시작 네트워크 — 리소스 목록이 비었거나 없으면 문서 시각만 남기는 짧은 줄', () => {
  for (const list of [[], null, undefined]) {
    const s = summarizeStartupNetwork(nav(), list, { scriptAt: 900, controlled: true });
    assert.equal(s.files, null);
    assert.equal(startupNetworkLine(s), '시작 네트워크: 리다이렉트 0 · HTML 요청 12 · HTML 응답 310 · HTML 끝 325 · 파일 기록 없음 · 서비스 워커 (제어 중) · 스크립트 시작 900');
  }
  // 문서 주소를 읽지 못하면 같은 origin 인지 가릴 수 없다 — 파일을 세지 않는다.
  const s = summarizeStartupNetwork(nav({ name: 'about:blank' }), [res('app.js', 100)], { scriptAt: 900 });
  assert.equal(startupNetworkLine(s), '시작 네트워크: 리다이렉트 0 · HTML 요청 12 · HTML 응답 310 · HTML 끝 325 · 파일 기록 없음 · 스크립트 시작 900');
});

test('시작 네트워크 — 앱 스크립트가 시작한 뒤에 끝난 리소스·아직 안 끝난 리소스는 세지 않는다', () => {
  const resources = [
    res('app.js', 700),
    res('main.js', 800.4),                 // 반올림 800 = 스크립트 시작과 같은 ms → 포함
    full('config.json', 950, 200),         // 앱이 시작한 뒤 받은 것
    full('late-icon.png', 4000, 90000),
    res('pending.js', 0),                  // 끝난 시각이 없는 항목
  ];
  const s = summarizeStartupNetwork(nav(), resources, { scriptAt: 800 });
  assert.deepEqual(s.files, { count: 2, cached: 0, revalidated: 2, transferred: 0, unknown: 0, kb: 1, viaWorker: 0, lastAt: 800, lastName: 'main.js', gap: 0 });
  assert.doesNotMatch(startupNetworkLine(s), /config|icon|pending/);
  // 스크립트 시작 시각을 모르면(0) 아무것도 세지 않는다.
  assert.equal(summarizeStartupNetwork(nav(), resources, {}).files, null);
  assert.equal(summarizeStartupNetwork(nav(), resources).files, null);
});

test('시작 네트워크 — 줄에는 구간 말·정수·정적 파일 basename 만: 쿼리·다른 origin·API 경로·식별값이 섞이지 않는다', () => {
  const resources = [
    res('app.js', 500),
    res('ui.js?v=20261118&token=secret-token-1', 1200),                                        // 쿼리 — 이름만 남는다
    full('https://cdn.other.example/vendor/tracker.js', 1900, 80000),                           // 다른 origin
    full('http://app.example/insecure.js', 1900, 80000),                                        // 같은 호스트, 다른 scheme = 다른 origin
    full('https://app.example:8443/port.js', 1900, 80000),                                      // 다른 포트
    full(`${ORIGIN}/v2/rooms/family-room-secret/events?device=mom-web-aaaaaa&after=7`, 1800, 4000),   // 릴레이 API
    full(`${ORIGIN}/v2`, 1800, 4000),
    full(`blob:${ORIGIN}/0b0c7c1e-aaaa-bbbb-cccc-121212121212`, 1850, 4000),                    // http(s) 가 아닌 주소
    full('data:text/plain,owner-web-87576b', 1850, 10),
    { name: 'not a url', responseEnd: 1850, transferSize: 99999 },
  ];
  const s = summarizeStartupNetwork(nav({ name: `${ORIGIN}/?next=%2Fprivate&user=owner-web-87576b#frag` }), resources, { scriptAt: 2000, controlled: true });
  assert.deepEqual(s.files, { count: 2, cached: 0, revalidated: 2, transferred: 0, unknown: 0, kb: 1, viaWorker: 0, lastAt: 1200, lastName: 'ui.js', gap: 800 });
  const line = startupNetworkLine(s);
  assert.match(line, / · 마지막 파일 ui\.js 1200 · /);
  assert.doesNotMatch(line, /https?|\/\/|[/?=&#%@]|example|other|cdn|token|secret|v2|rooms|family|device|mom-web|owner-web|87576b|tracker|insecure|port|blob|private|20261118/);
  // 요약 값에도 주소가 남지 않는다(앱은 줄만 쓰지만, 값이 새어 나갈 틈을 두지 않는다).
  assert.doesNotMatch(JSON.stringify(s), /example|secret|token|\?|\/\//);
  // 줄의 모양 전체: 아는 말 + 정수 + basename 하나.
  assert.match(line, /^시작 네트워크: 리다이렉트 \d+ · HTML 요청 \d+ · HTML 응답 \d+ · HTML 끝 \d+ · 파일 \d+개 \(캐시 \d+ · 재검증 \d+ · 받음 \d+ · 전송 \d+ KB\) · 마지막 파일 [A-Za-z0-9._-]+ \d+ · 서비스 워커 경유 \d+ \(제어 중\) · 파일 뒤 실행 \d+ · 스크립트 시작 \d+$/);
});

test('시작 네트워크 — 정적 파일 이름 모양이 아닌 마지막 파일은 「기타」로 남긴다', () => {
  for (const path of ['files/owner-web-87576b', 'share/mom-web-aaaaaa.bin', 'docs/', 'a/%EA%B0%80%EC%A1%B1.js', `x/${'a'.repeat(60)}.js`, 'p/.env', 'q/report.js.exe']) {
    const s = summarizeStartupNetwork(nav(), [res('app.js', 100), res(path, 300)], { scriptAt: 500 });
    assert.equal(s.files.count, 2, path);
    assert.equal(s.files.lastName, '기타', path);
    assert.match(startupNetworkLine(s), / · 마지막 파일 기타 300 · /, path);
  }
  // 손으로 만든 요약이 들어와도 이름 자리는 basename 모양만 통과한다.
  const forged = summarizeStartupNetwork(nav(), [res('app.js', 100)], { scriptAt: 500 });
  forged.files.lastName = 'https://app.example/v2/rooms?device=x';
  assert.match(startupNetworkLine(forged), / · 마지막 파일 기타 100 · /);
  // 하위 경로의 정적 파일은 디렉터리 없이 이름만.
  assert.equal(summarizeStartupNetwork(nav(), [res('icons/icon-192.png', 100)], { scriptAt: 500 }).files.lastName, 'icon-192.png');
});

test('시작 네트워크 — 던지는 getter·이상한 값·이상한 항목이 섞여도 죽지 않고 음수·NaN 이 없다', () => {
  const thrower = new Proxy({}, { get() { throw new Error('blocked'); } });
  assert.deepEqual(summarizeStartupNetwork(thrower, [thrower], { scriptAt: 500 }),
    { redirect: 0, workerStart: 0, fetchStart: 0, responseStart: 0, responseEnd: 0, scriptAt: 500, controlled: null, files: null });
  const odd = [thrower, null, undefined, 7, 'x', {}, res('app.js', NaN), res('ui.js', -5), res('room.js', Infinity), res('ok.js', 200, { transferSize: -900, encodedBodySize: 'big', decodedBodySize: null, workerStart: NaN })];
  const s = summarizeStartupNetwork(nav({ fetchStart: -3, responseStart: NaN, responseEnd: '9' }), odd, { scriptAt: 500, controlled: 'yes' });
  assert.deepEqual(s, { redirect: 0, workerStart: 0, fetchStart: 0, responseStart: 0, responseEnd: 0, scriptAt: 500, controlled: null,
    files: { count: 1, cached: 0, revalidated: 0, transferred: 0, unknown: 1, kb: 0, viaWorker: 0, lastAt: 200, lastName: 'ok.js', gap: 300 } });
  assert.doesNotMatch(startupNetworkLine(s), /NaN|undefined|null|-\d/);
  // 순회 자체가 던지는 목록 → 요약 없음(줄 없음).
  const badList = { get length() { throw new Error('no'); }, [Symbol.iterator]() { throw new Error('no'); } };
  assert.equal(summarizeStartupNetwork(nav(), badList, { scriptAt: 500 }), null);
  for (const scriptAt of [NaN, -1, 'x', null]) assert.equal(summarizeStartupNetwork(nav(), [res('app.js', 1)], { scriptAt }).scriptAt, 0);
});

test('시작 네트워크 — 브라우저 접착: 종류별로 한 번씩만 읽고, API 가 없거나 던지면 null', () => {
  const asked = [];
  const performance = { getEntriesByType(type) { asked.push(type); return type === 'navigation' ? [nav()] : [res('app.js', 400), full('ui.js', 900, 2048)]; } };
  const s = readStartupNetwork({ performance, navigator: { serviceWorker: { controller: {} } }, scriptAt: 1000 });
  assert.deepEqual(asked, ['navigation', 'resource']);
  assert.equal(s.controlled, true);
  assert.equal(s.files.count, 2);
  assert.equal(readStartupNetwork({ performance, navigator: { serviceWorker: { controller: null } }, scriptAt: 1000 }).controlled, false);
  // serviceWorker 가 없는 브라우저(또는 읽다 던짐)는 제어 여부를 모른다 — 줄에서 뺀다.
  assert.equal(readStartupNetwork({ performance, navigator: {}, scriptAt: 1000 }).controlled, null);
  assert.equal(readStartupNetwork({ performance, scriptAt: 1000 }).controlled, null);
  assert.equal(readStartupNetwork({ performance, navigator: { get serviceWorker() { throw new Error('insecure'); } }, scriptAt: 1000 }).controlled, null);

  assert.equal(readStartupNetwork(), null);
  assert.equal(readStartupNetwork({}), null);
  assert.equal(readStartupNetwork({ performance: {} }), null);
  assert.equal(readStartupNetwork({ performance: { getEntriesByType() { throw new Error('nope'); } } }), null);
  assert.equal(readStartupNetwork({ performance: { getEntriesByType: () => [] }, scriptAt: 5 }), null);      // 문서 항목 없음
  assert.equal(readStartupNetwork({ performance: { getEntriesByType: () => undefined }, scriptAt: 5 }), null);
  // 리소스 읽기만 던져도 줄 없이 끝난다.
  assert.equal(readStartupNetwork({ performance: { getEntriesByType(type) { if (type === 'resource') throw new Error('x'); return [nav()]; } }, scriptAt: 5 }), null);
});

test('시작 네트워크 — 앱 배선: 첫 화면 줄 바로 뒤에 한 번, 진단 복사 요약에는 startup: 다음 줄', () => {
  const app = readFileSync(new URL('../app.js', import.meta.url), 'utf8');
  assert.match(app, /logLine\(startupLine\(summary\)\);\s*(?:\/\/[^\n]*\n\s*)*app\.startupNet = startupNetworkLine\(readStartupNetwork\(\{performance: perf, navigator: globalThis\.navigator,\s*scriptAt: summary\.stages\.find\(s => s\.name === 'script'\)\?\.at\}\)\);\s*if \(app\.startupNet\) logLine\(app\.startupNet\);/);
  assert.equal(app.match(/readStartupNetwork\(/g).length, 1, '읽는 곳은 첫 화면 한 군데');
  assert.match(app, /lines\.splice\(lines\.indexOf\('rooms:'\), 0, app\.startupNet \? `startup-net: \$\{app\.startupNet\}` : 'startup-net: -'\);/);
  // 버퍼 크기는 건드리지 않는다.
  const source = readFileSync(new URL('../startup-timing.js', import.meta.url), 'utf8');
  assert.doesNotMatch(app + source, /setResourceTimingBufferSize\(|clearResourceTimings\(/);
});
