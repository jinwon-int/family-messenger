/**
 * 서비스 봇(알림 전용) 말풍선의 링크 — 허용한 호스트의 https 주소만 누를 수 있는 조각으로 나눈다.
 *
 * 에이전트 답장은 링크를 만들지 않는다(agent-markdown 은 링크 문법을 글로 둔다). 서비스 봇은 사람이 쓴 글을
 * 옮기지 않고 고정 형식의 알림만 보내므로, 그 말풍선에 한해 **https + 허용 호스트**만 링크로 바꾼다.
 * 그 밖의 주소(http, 다른 호스트, 사용자 정보·포트가 붙은 주소)는 글 그대로 둔다. iOS `ServiceLinks` 와 같은 규칙.
 */

/** 링크로 바꿀 호스트(소문자, 정확히 일치). 인스타그램 새 글 알림(`insta` 봇)용. */
export const linkHosts = new Set(['instagram.com', 'www.instagram.com']);

const CANDIDATE = /https:\/\/[^\s<>"'`]+/g;
/** 문장부호로 끝나는 주소에서 떼어 낼 꼬리(괄호·마침표 등은 주소가 아니라 문장의 일부일 때가 많다). */
const TRAILING = /[.,!?;:)\]}'"…]+$/u;

/** `https://…` 한 덩어리가 허용 링크면 URL 문자열, 아니면 null. */
export function allowedHref(candidate) {
  let url;
  try {
    url = new URL(candidate);
  } catch {
    return null;
  }
  if (url.protocol !== 'https:' || url.username || url.password || url.port) return null;
  if (!linkHosts.has(url.hostname.toLowerCase())) return null;
  return url.href;
}

/**
 * 글 → 조각 배열. 문자열은 글 그대로, `{text, href}` 는 링크. 조각을 이으면 원래 글과 같다.
 * @param {string} text
 * @returns {Array<string | {text: string, href: string}>}
 */
export function linkParts(text) {
  const source = String(text ?? '');
  const parts = [];
  let last = 0;
  for (const match of source.matchAll(CANDIDATE)) {
    const raw = match[0];
    const tail = raw.match(TRAILING)?.[0] ?? '';
    const candidate = tail ? raw.slice(0, raw.length - tail.length) : raw;
    const href = allowedHref(candidate);
    if (!href) continue;
    if (match.index > last) parts.push(source.slice(last, match.index));
    parts.push({ text: candidate, href });
    last = match.index + candidate.length;
  }
  if (last < source.length) parts.push(source.slice(last));
  return parts.length ? parts : [source];
}
