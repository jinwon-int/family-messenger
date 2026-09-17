// Deploy-time configuration (dist/config.json). The public repo never holds
// real hostnames: build.mjs copies web/app/config.json (git-ignored) when it
// exists and writes `{}` otherwise. Only https URLs are accepted.

export const DEFAULT_CONFIG = Object.freeze({ filebox: null });

/** @returns {{filebox: null|{url: string, title: string|null}}} */
export function sanitizeConfig(raw) {
  let filebox = null;
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
  return { filebox };
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
