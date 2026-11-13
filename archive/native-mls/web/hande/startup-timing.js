// 시작 구간 계측(#766 I): 페이지를 연 순간부터 첫 화면(방 목록·등록 화면 등)까지 구간별로 몇 ms 가
// 걸렸는지 한 줄로 남긴다. 줄은 앱 기록(「진단 기록 복사」)에 들어가므로 DevTools 없이도 현장 값을 받을
// 수 있다 — #766 의 나머지 항목(B·C·H)은 이 줄의 before/after 로 효과를 잰다.
//
// 순수 모듈(DOM·전역 시계 없음, node --test). 시계는 주입한다: 브라우저에서는 performance.now() 라
// 0 이 「페이지를 연 순간」(timeOrigin)이고, 첫 구간(script)이 HTML·모듈을 받아 실행하기까지의 시간이 된다.
//
// 기록하는 것은 구간 이름과 ms 뿐이다 — 방 이름·기기 ID·주소는 넣지 않는다.

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
export const STARTUP_PHASE_LABELS = {ready: '대화 화면', enroll: '등록 화면', needsActor: '이름 정하기', fatal: '오류 화면'};

/** 앱 기록 한 줄. labels: 구간 이름 → 화면 말(없으면 이름 그대로). */
export function startupLine(summary, {labels = STARTUP_LABELS, phaseLabels = STARTUP_PHASE_LABELS} = {}) {
  if (!summary) return '';
  const parts = summary.stages.map(s => `${labels[s.name] ?? s.name} ${s.ms}`);
  const phase = phaseLabels[summary.phase] ?? summary.phase;
  return `첫 화면까지 ${summary.total} ms (${phase})` + (parts.length ? ` — ${parts.join(' · ')}` : '');
}
