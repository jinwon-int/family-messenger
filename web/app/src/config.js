// Deploy-time configuration (dist/config.json). The public repo never holds
// real hostnames: build.mjs copies web/app/config.json (git-ignored) when it
// exists and writes `{}` otherwise. Only https URLs are accepted.

export const DEFAULT_CONFIG = Object.freeze({ filebox: null, homeserverUrl: null });

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

/** @returns {{filebox: null|{url: string, title: string|null}, homeserverUrl: string|null}} */
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
  return { filebox, homeserverUrl };
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
