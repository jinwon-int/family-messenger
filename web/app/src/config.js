// Deploy-time configuration (dist/config.json). The public repo never holds
// real hostnames: build.mjs copies web/app/config.json (git-ignored) when it
// exists and writes `{}` otherwise. Only https URLs are accepted.

export const DEFAULT_CONFIG = Object.freeze({ filebox: null, homeserverUrl: null, push: null });

/** https URL string or null. */
function httpsUrl(value) {
  if (typeof value !== 'string') return null;
  try {
    const url = new URL(value);
    return url.protocol === 'https:' ? url.toString() : null;
  } catch {
    return null;
  }
}

// 웹푸시 설정. 셋 다 공개값이므로 config.json에 둔다(deploy/sygnal/gen-vapid-key.sh가
// 만드는 vapid_application_server_key.txt, sygnal.yaml의 apps: 키, 터널이 노출하는 notify URL).
//
// **셋 중 하나라도 없거나 형식이 틀리면 push 전체를 null로 만든다.** 반쪽 설정으로
// 구독을 시작하면 브라우저에는 구독이 생기는데 게이트웨이가 서명하지 못해, 알림이
// 조용히 사라지는 상태가 기기에 남는다(SYGNAL-DEPLOY.md §진단의 "조용히 사라지는" 경로).

// sygnal의 find_pushkins가 2개 이상 매칭하면 pushkey를 reject하고 홈서버가 pusher를
// 지운다. 그래서 app_id에 글로브 문자를 허용하지 않는다(sygnal.yaml.example의 경고).
// 길이 상한 64는 Synapse의 app_id 제약과 같은 값으로 잡았다.
const APP_ID = /^[A-Za-z0-9._-]{1,64}$/;

/**
 * VAPID Application Server Key: 비압축 P-256 점 65바이트의 패딩 없는 base64url(87자).
 * 길이만 보지 않고 실제로 디코딩해 65바이트·0x04 시작까지 확인한다 — 잘린 키는
 * PushManager.subscribe가 던지지만, "그럴듯하지만 틀린" 키는 구독이 만들어진 뒤
 * 게이트웨이에서야 실패해서 원인을 찾기 어렵다.
 */
function applicationServerKey(value) {
  if (typeof value !== 'string' || !/^[A-Za-z0-9_-]{87}$/.test(value)) return null;
  try {
    // replaceAll은 ES2021이다. build.mjs가 target es2020을 명시하고 있고(구형 모바일
    // 브라우저에서 파싱 실패로 빈 화면이 났던 2026-09-16 사고), esbuild는 메서드를
    // 폴리필하지 않는다. 정규식 replace로 둔다.
    const binary = atob(value.replace(/-/g, '+').replace(/_/g, '/'));
    if (binary.length !== 65 || binary.charCodeAt(0) !== 0x04) return null;
    // 87번째 문자는 쓰이지 않는 2비트를 싣는다. 같은 65바이트로 디코딩되는 변종이
    // 네 가지 있어서 길이·접두 검사만으로는 오타를 잡지 못한다. 다시 인코딩해
    // 정준형과 같은지 본다.
    const canonical = btoa(binary).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
    if (canonical !== value) return null;
  } catch {
    return null;
  }
  return value;
}

/** @returns {null|{gatewayUrl: string, appId: string, applicationServerKey: string}} */
function pushConfig(raw) {
  if (!raw || typeof raw !== 'object') return null;
  const gatewayUrl = httpsUrl(raw.gatewayUrl);
  const appId = typeof raw.appId === 'string' && APP_ID.test(raw.appId) ? raw.appId : null;
  const key = applicationServerKey(raw.applicationServerKey);
  if (!gatewayUrl || !appId || !key) return null;
  return { gatewayUrl, appId, applicationServerKey: key };
}

/** @returns {{filebox: null|{url: string, title: string|null}, homeserverUrl: string|null, push: null|{gatewayUrl: string, appId: string, applicationServerKey: string}}} */
export function sanitizeConfig(raw) {
  let filebox = null;
  // 로그인 화면의 기본 홈서버 주소(가족은 아이디·비밀번호만 입력). 끝 슬래시는 뗀다.
  const homeserverUrl = httpsUrl(raw && typeof raw === 'object' ? raw.homeserverUrl : null)?.replace(/\/$/, '') ?? null;
  const candidate = raw && typeof raw === 'object' ? raw.filebox : null;
  if (candidate && typeof candidate.url === 'string') {
    try {
      const url = new URL(candidate.url);
      if (url.protocol === 'https:') {
        filebox = { url: url.toString(), title: typeof candidate.title === 'string' && candidate.title.length > 0 ? candidate.title : null };
      }
    } catch {
      filebox = null;
    }
  }
  return { filebox, homeserverUrl, push: pushConfig(raw && typeof raw === 'object' ? raw.push : null) };
}

/** Fetch ./config.json; any failure yields the defaults (the app works without it). */
export async function loadConfig(fetchFn = globalThis.fetch) {
  try {
    const response = await fetchFn('./config.json', { cache: 'no-store' });
    if (!response.ok) return DEFAULT_CONFIG;
    return sanitizeConfig(await response.json());
  } catch {
    return DEFAULT_CONFIG;
  }
}
