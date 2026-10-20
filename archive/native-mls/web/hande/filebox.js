// 오른쪽 보관함 pane 의 파일보관함 임베드(패밀리챗 web/app `filebox` 설정과 같은 모양).
// 배포 시 config.json 의 `filebox: {url, title}` — 공개 레포에는 실제 호스트가 없다. https 만 받는다.
// iframe 은 다시 붙이면 다시 로드되므로(패밀리챗 #194) url 의 refresh 카운터로만 재로드를 일으킨다.

/** https URL 문자열 또는 null. */
export function httpsUrl(value) {
  if (typeof value !== 'string') return null;
  try {
    const url = new URL(value);
    return url.protocol === 'https:' ? url.toString() : null;
  } catch (_) { return null; }
}

/** config.json 의 filebox → {url, title} 또는 null(없음·형식 오류). */
export function fileboxConfig(raw, {defaultTitle}) {
  if (!raw || typeof raw !== 'object') return null;
  const url = httpsUrl(raw.url);
  if (!url) return null;
  const title = typeof raw.title === 'string' && raw.title.trim() ? raw.title.trim() : defaultTitle;
  return {url, title};
}

/** 새로고침 버튼: 쿼리 `_files_refresh=<n>` 를 바꿔 iframe src 교체를 일으킨다(0 이면 원래 주소). */
export function fileboxRefreshUrl(base, refresh = 0) {
  const url = new URL(base);
  if (refresh > 0) url.searchParams.set('_files_refresh', String(refresh));
  return url.toString();
}
