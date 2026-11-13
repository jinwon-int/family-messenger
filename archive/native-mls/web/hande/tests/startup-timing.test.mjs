// #766 I: 시작 구간 계측(startup-timing.js) — 구간별 ms, 합 = 전체, 한 번만 끝남, 기록에 식별값 없음.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { createStartupTiming, startupLine, MAX_STAGES, STARTUP_LABELS, STARTUP_PHASE_LABELS } from '../startup-timing.js';

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
  for (const phase of ['ready', 'enroll', 'needsActor', 'fatal']) assert.ok(STARTUP_PHASE_LABELS[phase], phase);
});

test('앱 배선: 시작 화면을 벗어난 첫 그리기에서만 끝내고, 진단 복사 요약에도 싣는다', () => {
  const app = readFileSync(new URL('../app.js', import.meta.url), 'utf8');
  assert.match(app, /updatePhase\(\); paint\(\); noteFirstScreen\(\);/);
  assert.match(app, /function noteFirstScreen\(\) \{\s*if \(timing\.finished \|\| app\.phase === 'starting'\) return;/);
  assert.match(app, /const startup = app\.startup \? `startup: \$\{startupLine\(app\.startup\)\}` : 'startup: -';/);
  assert.match(app, /, me, startup, 'rooms:',/);
});

test('startup-timing.js 가 build.sh 배포 목록·SHELL_ASSETS·modulepreload 에 있다', async () => {
  const { SHELL_ASSETS } = await import('../sw-policy.js');
  assert.ok(SHELL_ASSETS.includes('./startup-timing.js'));
  assert.match(readFileSync(new URL('../build.sh', import.meta.url), 'utf8'), /\sstartup-timing\.js\s/);
  assert.match(readFileSync(new URL('../index.html', import.meta.url), 'utf8'), /modulepreload" href="\.\/startup-timing\.js"/);
});
