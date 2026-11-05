/**
 * x.com 링크 미리보기 카드(#683 2단계, 「2단계 API 계약 v1」 클라이언트 절) — 순수 모듈(DOM 없음, node:test 로 검증).
 *
 * - `previewTarget(text)`: 사람·서비스 봇 말풍선 글에서 **첫 번째 x.com 글(status) 주소**를 정규 URL 로, 없으면 null.
 *   1단계 `xHosts`·`linkParts` 규칙(https, 사용자 정보·포트 없음, 호스트 정확히 일치) 위에 경로 규칙을 더한다:
 *   `/{handle}/status/{id}` 또는 `/i/web/status/{id}` (handle = `[A-Za-z0-9_]{1,15}`, id = 숫자 1–25자리).
 *   뒤 경로(`/photo/1` 등)·쿼리·조각은 버린다 — 릴레이 정규화와 같은 모양이라 캐시 키가 맞는다.
 *   에이전트 말풍선을 빼는 것은 부르는 쪽(ui.js)의 몫이다.
 * - `createLinkPreviews({fetch})`: 같은 origin `GET /v2/preview?url=…`(기존 릴레이 요청처럼 `credentials: 'same-origin'` —
 *   Access 쿠키가 실리고 엣지가 JWT 를 붙인다). URL 마다 앱 메모리에 한 번만 묻는다 — 성공·「카드 없음」 둘 다 기억한다.
 *   404(라우트 꺼짐 `-link-preview` off · no_preview)·502·400·401·네트워크 실패·이상한 본문은 전부 조용히 「카드 없음」(null).
 * - 응답의 `image` 는 릴레이 상대 경로 `/v2/preview/image?u=…` 일 때만 받는다(그 밖의 값은 버림). 같은 origin 이라
 *   CSP `img-src 'self'` 안이고, <img> 요청에도 같은 Access 쿠키가 실린다.
 * iOS·Android 클라이언트도 같은 규칙(계약 v1).
 */
import {linkParts, xHosts} from './service-links.js';

const HANDLE = /^[A-Za-z0-9_]{1,15}$/;
const STATUS_ID = /^[0-9]{1,25}$/;
/** 응답 image 로 받아들이는 릴레이 상대 경로 접두(계약 v1). */
export const IMAGE_PREFIX = '/v2/preview/image?u=';
/** 앱 메모리 캐시 상한(릴레이 캐시와 같은 512개, 오래된 것부터 버림). */
export const MAX_ENTRIES = 512;

/**
 * x.com 계열 https 주소 → 정규 글 주소(`https://x.com/{handle}/status/{id}` · `https://x.com/i/web/status/{id}`), 아니면 null.
 * @param {string} href 1단계 `allowedHref(…, xHosts)` 를 통과한 주소(여기서도 다시 확인한다)
 */
export function statusUrl(href) {
  let url;
  try {
    url = new URL(href);
  } catch {
    return null;
  }
  if (url.protocol !== 'https:' || url.username || url.password || url.port) return null;
  if (!xHosts.has(url.hostname.toLowerCase())) return null;
  const segments = url.pathname.split('/').slice(1);
  if (segments[0] === 'i' && segments[1] === 'web' && segments[2] === 'status' && STATUS_ID.test(segments[3] ?? '')) {
    return `https://x.com/i/web/status/${segments[3]}`;
  }
  if (HANDLE.test(segments[0] ?? '') && segments[1] === 'status' && STATUS_ID.test(segments[2] ?? '')) {
    return `https://x.com/${segments[0]}/status/${segments[2]}`;
  }
  return null;
}

/**
 * 말풍선 글에서 미리보기를 붙일 첫 x.com 글 주소(정규형), 없으면 null.
 * x.com 링크라도 글 주소가 아니면(프로필 `https://x.com/name` 등) 건너뛰고 다음 링크를 본다.
 * @param {string} text
 * @returns {string|null}
 */
export function previewTarget(text) {
  for (const part of linkParts(text, xHosts)) {
    if (typeof part === 'string') continue;
    const target = statusUrl(part.href);
    if (target) return target;
  }
  return null;
}

/** 릴레이 응답 본문 → 카드 `{url, title, description, image}`, 쓸 수 없으면 null. 문자열은 화면에서 텍스트 노드로만 쓴다. */
export function cardFrom(target, body) {
  if (!body || typeof body !== 'object') return null;
  const text = (value) => (typeof value === 'string' ? value.trim() : '');
  const title = text(body.title);
  const description = text(body.description);
  if (!title && !description) return null;
  const image = typeof body.image === 'string' && body.image.startsWith(IMAGE_PREFIX) && !/[\s\\]/.test(body.image) ? body.image : null;
  return {url: target, title, description, image};
}

/**
 * @param {object} [deps]
 * @param {typeof fetch} [deps.fetch] 주입용(테스트). 기본은 전역 fetch.
 * @param {number} [deps.maxEntries]
 */
export function createLinkPreviews({fetch = (...args) => globalThis.fetch(...args), maxEntries = MAX_ENTRIES} = {}) {
  /** 정규 URL → 끝난 결과(카드 또는 null). */
  const done = new Map();
  /** 정규 URL → 진행 중 Promise(같은 URL 을 겹쳐 물으면 한 번만 요청). */
  const pending = new Map();

  function remember(target, card) {
    done.delete(target);
    done.set(target, card);
    while (done.size > maxEntries) done.delete(done.keys().next().value);
  }

  async function request(target) {
    try {
      const response = await fetch(`/v2/preview?url=${encodeURIComponent(target)}`, {method: 'GET', credentials: 'same-origin'});
      if (!response || response.status !== 200) return null;
      let body = null;
      try { body = await response.json(); } catch (_) { body = null; }
      return cardFrom(target, body);
    } catch (_) {
      return null;   // 네트워크 실패·터널 끊김 — 링크만 둔다(오프라인 표시는 본 폴링의 몫).
    }
  }

  return {
    /** 이미 끝난 결과: 카드 · null(카드 없음) · undefined(아직 모름). 재렌더에서 깜빡임 없이 바로 그리는 데 쓴다. */
    peek(target) {
      return done.has(target) ? done.get(target) : undefined;
    },
    /** 카드 또는 null. 같은 URL 은 한 번만 요청한다(결과가 null 이어도 다시 묻지 않는다). */
    get(target) {
      if (typeof target !== 'string' || !target) return Promise.resolve(null);
      if (done.has(target)) return Promise.resolve(done.get(target));
      const inFlight = pending.get(target);
      if (inFlight) return inFlight;
      const promise = request(target).then((card) => {
        pending.delete(target);
        remember(target, card);
        return card;
      });
      pending.set(target, promise);
      return promise;
    },
    get size() { return done.size; },
  };
}
