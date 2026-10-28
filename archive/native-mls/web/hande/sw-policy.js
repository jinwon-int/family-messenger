// 서비스 워커 캐시 정책(#480 D) — 패밀리챗 web/app/sw.js 규칙을 한데에 맞춘 순수 함수(DOM·SW 전역 없음, 테스트 가능).
//
// 패밀리챗은 빌드 해시가 붙은 자산을 캐시 우선으로 둔다. 한데는 빌드 도구 없이 같은 이름의 파일을 제자리 교체로
// 배포하므로(README 「왜 릴레이가 서빙하나」) 캐시 우선이면 핫픽스가 기기 캐시에 갇힌다 → **같은 origin 은 전부
// 네트워크 우선**, 캐시는 오프라인 폴백(설치한 PWA 가 비행기 모드에서도 셸을 띄우게)으로만 쓴다.
// `/v2/*`(릴레이 API, CF Access JWT 뒤)와 다른 origin 은 절대 가로채지 않는다.

export const CACHE_NAME = 'hande-shell-v1';

/** 설치 때 프리캐시하는 셸(오프라인에서 첫 화면·워커·wasm 이 뜨게). 없는 파일이 있어도 설치는 계속된다(allSettled). */
export const SHELL_ASSETS = [
  './', './index.html', './styles.css', './manifest.webmanifest', './icons/icon.svg',
  './main.js', './app.js', './ui.js', './strings.js', './room.js', './device.js', './relay.js', './identity.js',
  './worker-bridge.js', './attachment-view.js', './agent-markdown.js', './filebox.js', './keyboard.js', './timeline-caret.js',
  './shortcuts.js', './room-order.js', './drafts.js', './read-seq.js', './composer-files.js', './last-sent.js', './sync-recovery.js', './preview-loader.js', './attachments.js', './agent-consent.js', './local-room.js', './service-links.js',
  './durable-worker.js', './session-store.js', './history-store.js', './commit-policy.js', './relay-attachments.js', './file-v2.js', './file-v2-outbox.js',
  './pkg/family_mls_browser_experiment.js', './pkg/family_mls_browser_experiment_bg.wasm', './pkg/custody.js',
];

/** 릴레이 API 는 절대 가로채지 않는다(Access 쿠키·JWT·CAS 재시도는 네트워크의 몫). */
export function isApiPath(pathname) {
  return typeof pathname === 'string' && (pathname === '/v2' || pathname.startsWith('/v2/'));
}

/**
 * 이 요청을 서비스 워커가 다룰지. GET · 같은 origin · API 가 아닐 때만.
 * @param {{method?: string, url?: string}} request
 * @param {string} origin self.location.origin
 */
export function shouldHandle(request, origin) {
  if (!request || request.method !== 'GET' || typeof request.url !== 'string') return false;
  let url;
  try { url = new URL(request.url); } catch (_) { return false; }
  if (url.origin !== origin) return false;
  if (isApiPath(url.pathname)) return false;
  return true;
}

/** 오프라인 폴백: 탐색(문서) 요청은 캐시된 index.html 로, 나머지는 같은 요청의 캐시로. */
export function fallbackKey(request) {
  if (request?.mode === 'navigate') return './index.html';
  return null;
}
