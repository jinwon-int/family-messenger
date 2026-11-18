// 시작 구간 계측(#766 I): 페이지를 연 순간부터 첫 화면(방 목록·등록 화면 등)까지 구간별로 몇 ms 가
// 걸렸는지 한 줄로 남긴다. 줄은 앱 기록(「진단 기록 복사」)에 들어가므로 DevTools 없이도 현장 값을 받을
// 수 있다 — #766 의 나머지 항목(B·C·H)은 이 줄의 before/after 로 효과를 잰다.
//
// 순수 모듈(DOM·전역 시계 없음, node --test). 시계는 주입한다: 브라우저에서는 performance.now() 라
// 0 이 「페이지를 연 순간」(timeOrigin)이고, 첫 구간(script)이 HTML·모듈을 받아 실행하기까지의 시간이 된다.
//
// 기록하는 것은 구간 이름과 ms 뿐이다 — 방 이름·기기 ID·주소는 넣지 않는다.
//
// 둘째 줄 「시작 네트워크」(아래 summarizeStartupNetwork): 첫 구간(스크립트)이 리다이렉트·HTML·정적 파일 받기·
// 실행 중 어디서 걸렸는지 브라우저의 Navigation/Resource Timing 으로 나눈다. 거기에 더 들어가는 것은 우리 정적
// 파일의 이름(ui.js 같은 basename) 하나뿐이다.

/** 한 번의 시작에서 남기는 구간 수 상한(다시 시작·복구 경로가 같은 구간을 또 지나도 줄이 길어지지 않게). */
export const MAX_STAGES = 16;

const clean = name => String(name ?? '').replace(/[^\p{L}\p{N}_-]/gu, '').slice(0, 24) || 'stage';
const whole = ms => Math.max(0, Math.round(Number.isFinite(ms) ? ms : 0));

/**
 * @param {{now?: () => number}} [opts] now: 「페이지를 연 순간」부터의 ms(브라우저 performance.now)
 */
export function createStartupTiming({now = () => 0} = {}) {
  /** @type {{name: string, at: number}[]} */
  const marks = [];
  let end = null;   // {phase, at}
  const read = () => { try { return whole(now()); } catch (_) { return 0; } };
  return {
    /** 구간 하나가 방금 끝났다. 같은 이름은 처음 것만 남긴다(복구 경로의 재시도가 구간을 늘리지 않는다). */
    mark(name) {
      if (end || marks.length >= MAX_STAGES) return;
      const key = clean(name);
      if (marks.some(m => m.name === key)) return;
      // 시계가 뒤로 가도(절전 복귀 등) 구간이 음수가 되지 않게 앞 구간 뒤로 맞춘다.
      marks.push({name: key, at: Math.max(read(), marks.length ? marks[marks.length - 1].at : 0)});
    },
    /** 첫 화면이 그려졌다. 처음 한 번만 요약을 돌려주고, 그 뒤로는 null(다시 그릴 때마다 줄이 남지 않게). */
    finish(phase) {
      if (end) return null;
      end = {phase: clean(phase), at: Math.max(read(), marks.length ? marks[marks.length - 1].at : 0)};
      return this.summary();
    },
    get finished() { return end !== null; },
    /** {phase, total, stages:[{name, ms, at}]} — ms 는 앞 구간이 끝난 뒤부터 걸린 시간, at 은 페이지를 연 뒤 누적. */
    summary() {
      if (!end) return null;
      let prev = 0;
      const stages = marks.map(m => { const ms = m.at - prev; prev = m.at; return {name: m.name, ms, at: m.at}; });
      if (end.at > prev) stages.push({name: 'paint', ms: end.at - prev, at: end.at});
      return {phase: end.phase, total: end.at, stages};
    },
  };
}

/** 앱이 남기는 구간(순서대로)과 기록에 쓰는 말. paint 는 마지막 구간 뒤 첫 화면이 그려지기까지 남은 시간. */
export const STARTUP_LABELS = {script: '스크립트', config: '설정', identity: '신원 열기', rooms: '방 열기', listing: '방 목록', paint: '그리기'};
// stored(#766 B): 릴레이의 방 목록 응답 전에 이 기기에 저장된 방·대화로 그린 대화 화면. ready 는 그 응답 뒤에 그린 것.
export const STARTUP_PHASE_LABELS = {ready: '대화 화면', stored: '대화 화면 · 저장분', enroll: '등록 화면', needsActor: '이름 정하기', fatal: '오류 화면'};

/** 앱 기록 한 줄. labels: 구간 이름 → 화면 말(없으면 이름 그대로). */
export function startupLine(summary, {labels = STARTUP_LABELS, phaseLabels = STARTUP_PHASE_LABELS} = {}) {
  if (!summary) return '';
  const parts = summary.stages.map(s => `${labels[s.name] ?? s.name} ${s.ms}`);
  const phase = phaseLabels[summary.phase] ?? summary.phase;
  return `첫 화면까지 ${summary.total} ms (${phase})` + (parts.length ? ` — ${parts.join(' · ')}` : '');
}

// ---- 시작 네트워크: 「스크립트」 구간을 브라우저 타이밍으로 나눈다 ----
//
// 입력은 PerformanceNavigationTiming 하나와 PerformanceResourceTiming 배열(모양만 같으면 된다 — 순수 함수),
// 그리고 앱 스크립트가 돌기 시작한 시각(위 'script' 구간의 at). 모든 ms 는 「페이지를 연 순간」(timeOrigin)부터의
// 값을 정수로 반올림한 것이고 음수는 0 으로 올린다.
//
// 문서(HTML):
//   redirect      = redirectEnd − redirectStart. 리다이렉트가 없거나, **다른 origin 을 거친 리다이렉트**(로그인 확인 등)면
//                   브라우저가 두 값을 0 으로 가린다 → 0. 그래서 fetchStart 를 같이 남긴다: 리다이렉트 0 인데
//                   「HTML 요청」이 크면 가려진 리다이렉트(또는 앞 문서 내리기)에서 걸렸을 수 있다.
//   workerStart   = 문서 요청이 서비스 워커를 거쳤을 때 워커를 깨우기 시작한 시각(안 거쳤으면 0 → 줄에서 생략).
//                   「HTML 요청 − 워커 시작」 ≈ 워커 기동 시간.
//   fetchStart    = 마지막(리다이렉트 뒤) 문서를 받기 시작한 시각.
//   responseStart = 문서 첫 바이트, responseEnd = 문서 끝.
//
// 파일: 문서와 **같은 origin**(http/https)이고 경로가 `/v2` · `/v2/…`(릴레이 API)가 아니며, 앱 스크립트 시작 전에
// 끝난(반올림한 responseEnd ≤ scriptAt, > 0) 리소스만 센다. 그 시각 전에는 index.html 이 적어 둔 정적 파일(모듈·
// CSS·아이콘) 말고는 요청이 없다 — 앱이 만드는 요청(config.json·/v2/…)은 모두 그 뒤다.
//   분류(파일마다 위에서부터 처음 맞는 것):
//     재검증  responseStatus === 304(값을 주는 브라우저만), 또는 0 < transferSize < encodedBodySize
//             (304 는 헤더만 오므로 전송량이 본문보다 작다).
//     받음    transferSize > 0 인 나머지(헤더 + 본문을 다 받음).
//     캐시    transferSize === 0 이고 본문 크기(encodedBodySize 나 decodedBodySize)가 0 보다 크거나
//             deliveryType === 'cache' — 네트워크를 타지 않았다.
//     모름    transferSize === 0 이고 크기도 0 — 브라우저가 크기를 알려 주지 않았다(줄에는 0 이 아닐 때만 나온다).
//   전송 KB = 위 파일들의 transferSize 합 / 1024(반올림).
//   알려진 모호함:
//     · 본문이 헤더(약 300바이트)보다 작은 파일의 304 는 transferSize ≥ encodedBodySize 라 「받음」으로 센다
//       (responseStatus 를 주는 브라우저에서는 「재검증」으로 맞게 센다).
//     · transferSize 는 Timing-Allow-Origin 없는 다른 origin 리소스에서 항상 0 이다 — 여기서는 같은 origin 만 세므로
//       해당 없지만, 그래서 다른 origin 파일은 아예 세지 않는다.
//     · **서비스 워커가 답한 응답**은 브라우저에 따라 transferSize 가 0 으로 나올 수 있다(워커가 네트워크에서 받아 넘겼어도).
//       「서비스 워커 경유」가 0 이 아니면 캐시·모름 수는 「네트워크를 안 탔다」가 아니라 「전송량을 알 수 없다」로 읽고,
//       분류 대신 시각(마지막 파일 ms · 파일 뒤 실행)으로 판단한다.
//     · Resource Timing 버퍼는 기본 250개다(늘리지 않는다). 그보다 많이 받은 페이지에서는 뒤의 것이 빠진다 —
//       한데 셸은 50개 안쪽이라 시작 구간은 다 들어온다.
//   서비스 워커 경유 = workerStart > 0 인 파일 수. controlled = 이 페이지를 서비스 워커가 잡고 있는지(모르면 null).
//   gap(파일 뒤 실행) = scriptAt − 마지막 파일의 responseEnd — 받기가 끝난 뒤 모듈 평가·메인 스레드 대기로 쓴 시간.
//
// 줄에 나오는 글자는 구간 말·정수·정적 파일 basename 뿐이다: 쿼리·전체 주소·호스트·API 경로는 넣지 않고, basename 도
// 정적 파일 이름 모양([A-Za-z0-9._-] + 아는 확장자)이 아니면 「기타」로 바꾼다.

const STATIC_NAME = /^[A-Za-z0-9][A-Za-z0-9._-]{0,39}\.(?:js|mjs|css|html|json|wasm|webmanifest|svg|png|ico|woff2)$/;
const OTHER_NAME = '기타';

/** 항목의 숫자 필드. getter 가 던지거나 숫자가 아니면 0. */
function field(entry, key) {
  try { const v = entry[key]; return Number.isFinite(v) ? v : 0; } catch (_) { return 0; }
}
function textField(entry, key) {
  try { const v = entry[key]; return typeof v === 'string' ? v : ''; } catch (_) { return ''; }
}
function httpUrl(text) {
  try { const u = new URL(text); return u.protocol === 'https:' || u.protocol === 'http:' ? u : null; } catch (_) { return null; }
}
function resourceClass(entry) {
  const transfer = field(entry, 'transferSize');
  const encoded = field(entry, 'encodedBodySize');
  if (field(entry, 'responseStatus') === 304) return 'revalidated';
  if (transfer > 0) return encoded > 0 && transfer < encoded ? 'revalidated' : 'transferred';
  return encoded > 0 || field(entry, 'decodedBodySize') > 0 || textField(entry, 'deliveryType') === 'cache' ? 'cached' : 'unknown';
}

/**
 * @param {object|null|undefined} navigation PerformanceNavigationTiming 모양(name = 문서 주소)
 * @param {ArrayLike<object>|null|undefined} resources PerformanceResourceTiming 모양들
 * @param {{scriptAt?: number, controlled?: boolean|null}} [opts] scriptAt: 앱 스크립트 시작(ms), controlled: 서비스 워커가 페이지를 잡고 있나
 * @returns {null | {redirect: number, workerStart: number, fetchStart: number, responseStart: number, responseEnd: number,
 *   scriptAt: number, controlled: boolean|null, files: null | {count: number, cached: number, revalidated: number,
 *   transferred: number, unknown: number, kb: number, viaWorker: number, lastAt: number, lastName: string, gap: number}}}
 *   문서 항목이 없으면(옛 브라우저) null — 줄을 남기지 않는다. 센 파일이 없으면 files 가 null 인 짧은 줄.
 */
export function summarizeStartupNetwork(navigation, resources, {scriptAt = 0, controlled = null} = {}) {
  try {
    if (!navigation || typeof navigation !== 'object') return null;
    const start = whole(scriptAt);
    const out = {
      redirect: whole(field(navigation, 'redirectEnd') - field(navigation, 'redirectStart')),
      workerStart: whole(field(navigation, 'workerStart')),
      fetchStart: whole(field(navigation, 'fetchStart')),
      responseStart: whole(field(navigation, 'responseStart')),
      responseEnd: whole(field(navigation, 'responseEnd')),
      scriptAt: start, controlled: typeof controlled === 'boolean' ? controlled : null, files: null,
    };
    const origin = httpUrl(textField(navigation, 'name'))?.origin;
    if (!origin) return out;
    const files = {count: 0, cached: 0, revalidated: 0, transferred: 0, unknown: 0, kb: 0, viaWorker: 0, lastAt: 0, lastName: OTHER_NAME, gap: 0};
    let bytes = 0;
    for (const entry of Array.from(resources ?? [])) {
      if (!entry || typeof entry !== 'object') continue;
      const url = httpUrl(textField(entry, 'name'));
      if (!url || url.origin !== origin || url.pathname === '/v2' || url.pathname.startsWith('/v2/')) continue;
      const end = whole(field(entry, 'responseEnd'));
      if (end <= 0 || end > start) continue;
      files.count++;
      files[resourceClass(entry)]++;
      bytes += Math.max(0, field(entry, 'transferSize'));
      if (field(entry, 'workerStart') > 0) files.viaWorker++;
      if (end > files.lastAt) {
        const base = url.pathname.slice(url.pathname.lastIndexOf('/') + 1);
        files.lastAt = end;
        files.lastName = STATIC_NAME.test(base) ? base : OTHER_NAME;
      }
    }
    if (!files.count) return out;
    files.kb = whole(bytes / 1024);
    files.gap = whole(start - files.lastAt);
    out.files = files;
    return out;
  } catch (_) { return null; }
}

/**
 * 브라우저 접착: 첫 화면에서 한 번 부른다(뜨거운 길에서 읽지 않는다). performance·navigator 는 주입한다.
 * API 가 없거나 던지거나 문서 항목이 없으면 null — 시작을 막지 않는다.
 * @param {{performance?: object, navigator?: object, scriptAt?: number}} [env]
 */
export function readStartupNetwork({performance, navigator, scriptAt = 0} = {}) {
  try {
    if (typeof performance?.getEntriesByType !== 'function') return null;
    const navigation = performance.getEntriesByType('navigation')?.[0];
    if (!navigation) return null;
    let controlled = null;
    try { const sw = navigator?.serviceWorker; if (sw) controlled = !!sw.controller; } catch (_) { controlled = null; }
    return summarizeStartupNetwork(navigation, performance.getEntriesByType('resource'), {scriptAt, controlled});
  } catch (_) { return null; }
}

/** 앱 기록 둘째 줄. 요약이 없으면 ''(줄을 남기지 않는다). */
export function startupNetworkLine(summary) {
  if (!summary) return '';
  const parts = [`리다이렉트 ${summary.redirect}`];
  if (summary.workerStart > 0) parts.push(`워커 시작 ${summary.workerStart}`);
  parts.push(`HTML 요청 ${summary.fetchStart}`, `HTML 응답 ${summary.responseStart}`, `HTML 끝 ${summary.responseEnd}`);
  const f = summary.files;
  const held = summary.controlled === true ? ' (제어 중)' : summary.controlled === false ? ' (제어 없음)' : '';
  if (f) {
    const split = [`캐시 ${f.cached}`, `재검증 ${f.revalidated}`, `받음 ${f.transferred}`];
    if (f.unknown > 0) split.push(`모름 ${f.unknown}`);
    split.push(`전송 ${f.kb} KB`);
    parts.push(`파일 ${f.count}개 (${split.join(' · ')})`, `마지막 파일 ${STATIC_NAME.test(f.lastName) ? f.lastName : OTHER_NAME} ${f.lastAt}`,
      `서비스 워커 경유 ${f.viaWorker}${held}`, `파일 뒤 실행 ${f.gap}`);
  } else {
    parts.push('파일 기록 없음');
    if (held) parts.push(`서비스 워커${held}`);
  }
  parts.push(`스크립트 시작 ${summary.scriptAt}`);
  return `시작 네트워크: ${parts.join(' · ')}`;
}
