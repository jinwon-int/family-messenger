/**
 * 말풍선의 링크 — 허용한 호스트의 https 주소만 누를 수 있는 조각으로 나눈다.
 *
 * 서비스 봇(알림 전용)은 사람이 쓴 글을 옮기지 않고 고정 형식의 알림만 보내므로 `linkHosts`(인스타그램 + x.com)를,
 * 사람 말풍선은 `xHosts`(x.com·twitter.com, #683)만 링크로 바꾼다 — 릴레이가 미리보기 사이트 목록(v2, #690)을 주면
 * 두 집합 모두 그 목록의 hosts 합집합으로 넓어진다(preview-sites.js). 에이전트 말풍선은 아래 `agentLinkParts`(호스트 제한 없음).
 * 사람·서비스 봇 말풍선에서 그 밖의 주소(http, 다른 호스트, 사용자 정보·포트가 붙은 주소)는 글 그대로 둔다.
 * iOS `ServiceLinks`·Android `TextLinks` 와 같은 규칙.
 */

/** 사람·서비스 봇 말풍선에서 링크로 바꿀 x.com 계열 호스트(소문자, 정확히 일치, #683). */
export const xHosts = new Set(['x.com', 'www.x.com', 'mobile.x.com', 'twitter.com', 'www.twitter.com', 'mobile.twitter.com']);

/** 서비스 봇 말풍선에만 더하는 인스타그램 호스트(`insta` 봇 새 글 알림). */
export const instagramHosts = new Set(['instagram.com', 'www.instagram.com']);

/**
 * 서비스 봇 말풍선에서 링크로 바꿀 v1 기본 호스트. 인스타그램 + x.com 계열.
 * 미리보기 사이트 목록 v2(#690)가 오면 ui.js 는 preview-sites.js 의 `serviceHosts`(합집합 + 인스타그램)를 넘긴다.
 */
export const linkHosts = new Set([...instagramHosts, ...xHosts]);

const CANDIDATE = /https:\/\/[^\s<>"'`]+/g;
/** 문장부호로 끝나는 주소에서 떼어 낼 꼬리(괄호·마침표 등은 주소가 아니라 문장의 일부일 때가 많다). */
const TRAILING = /[.,!?;:)\]}'"…]+$/u;

/** `https://…` 한 덩어리가 허용 링크면 URL 문자열, 아니면 null. `hosts` 기본은 서비스 봇 집합. */
export function allowedHref(candidate, hosts = linkHosts) {
  let url;
  try {
    url = new URL(candidate);
  } catch {
    return null;
  }
  if (url.protocol !== 'https:' || url.username || url.password || url.port) return null;
  if (!hosts.has(url.hostname.toLowerCase())) return null;
  return url.href;
}

/**
 * 글 → 조각 배열. 문자열은 글 그대로, `{text, href}` 는 링크. 조각을 이으면 원래 글과 같다.
 * @param {string} text
 * @param {Set<string>} [hosts] 링크로 바꿀 호스트(기본: 서비스 봇 집합 `linkHosts`)
 * @returns {Array<string | {text: string, href: string}>}
 */
export function linkParts(text, hosts = linkHosts) {
  const source = String(text ?? '');
  const parts = [];
  let last = 0;
  for (const match of source.matchAll(CANDIDATE)) {
    const raw = match[0];
    const tail = raw.match(TRAILING)?.[0] ?? '';
    const candidate = tail ? raw.slice(0, raw.length - tail.length) : raw;
    const href = allowedHref(candidate, hosts);
    if (!href) continue;
    if (match.index > last) parts.push(source.slice(last, match.index));
    parts.push({ text: candidate, href });
    last = match.index + candidate.length;
  }
  if (last < source.length) parts.push(source.slice(last));
  return parts.length ? parts : [source];
}

// ---- 에이전트 말풍선의 링크(오너 2026-11-16 「에이전트가 주는 url 은 어떤 주소든 링크로」) ----
// 호스트 목록 없이 http·https 주소면 모두 링크(포트 허용 — 노드 내부 주소 `http://100.x.y.z:8080` 같은 것).
// 사용자 정보가 붙은 주소(`https://id@host`)도 링크(오너 2026-11-16 「말 그대로 어떤 주소든」). 막는 것은 다른 스킴
// (javascript:·data: 등 — 후보 정규식이 http(s) 만 잡는다)과 호스트 없는 주소뿐. iOS `ServiceLinks.agentLinks`·Android `TextLinks.agentLinks` 와 같은 규칙.

/** 에이전트 글의 주소 후보. 한국어 글에서 주소를 감싸는 낫표·괄호(「」『』【】〈〉《》（）)에서 끊는다. */
const AGENT_CANDIDATE = /https?:\/\/[^\s<>"'`「」『』【】〈〉《》（）]+/giu;
/** 에이전트 주소 끝에서 떼어 낼 문장부호 — 사람 말풍선 규칙 + 한국어 마침표·쉼표. */
const AGENT_TRAILING = new Set([...'.,!?;:)]}\'"…。、，']);

/** 주소 끝 문장부호를 뗀 길이. `)` 는 주소 안에 짝이 되는 `(` 가 있으면 남긴다(위키백과 `Foo_(bar)`). */
export function trimTrailing(candidate) {
  let end = candidate.length;
  while (end > 0 && AGENT_TRAILING.has(candidate[end - 1])) {
    if (candidate[end - 1] === ')') {
      const head = candidate.slice(0, end);
      if (head.split('(').length >= head.split(')').length) break;
    }
    end -= 1;
  }
  return end;
}

/**
 * 사람 말풍선의 마크다운 링크 `[글자](주소)`(전달·붙여넣은 에이전트 글): 주소가 허용 호스트(`hosts`)면 `{text, href}`,
 * 아니면 「글자 (주소)」 글 그대로 — 사람 말풍선의 링크 규칙(#690)은 넓히지 않고 주소도 잃지 않는다.
 * @param {{text: string, href: string}} link
 * @param {Set<string>} hosts
 * @returns {string | {text: string, href: string}}
 */
export function personMarkdownLink(link, hosts) {
  const href = allowedHref(link.href, hosts);
  if (href) return { text: link.text, href };
  return link.text === link.href ? link.href : `${link.text} (${link.href})`;
}

/** 에이전트 글의 `http(s)://…` 한 덩어리가 링크로 열 수 있는 주소면 URL 문자열, 아니면 null(호스트 제한 없음). */
export function agentHref(candidate) {
  let url;
  try {
    url = new URL(candidate);
  } catch {
    return null;
  }
  if (url.protocol !== 'https:' && url.protocol !== 'http:') return null;
  if (!url.hostname) return null;
  return url.href;
}

/**
 * 에이전트 글 → 조각 배열(`linkParts` 와 같은 모양). http·https 주소면 호스트와 상관없이 링크.
 * @param {string} text
 * @returns {Array<string | {text: string, href: string}>}
 */
export function agentLinkParts(text) {
  const source = String(text ?? '');
  const parts = [];
  let last = 0;
  for (const match of source.matchAll(AGENT_CANDIDATE)) {
    const candidate = match[0].slice(0, trimTrailing(match[0]));
    const href = candidate ? agentHref(candidate) : null;
    if (!href) continue;
    if (match.index > last) parts.push(source.slice(last, match.index));
    parts.push({ text: candidate, href });
    last = match.index + candidate.length;
  }
  if (last < source.length) parts.push(source.slice(last));
  return parts.length ? parts : [source];
}
