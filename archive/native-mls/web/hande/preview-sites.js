/**
 * 미리보기 사이트 목록(#690 「계약 v2」 클라이언트 절) — 순수 모듈(DOM 없음, node:test 로 검증).
 *
 * - 로그인 뒤 **세션당 한 번** 같은 origin `GET /v2/preview/sites`(relay.js 처럼 `credentials: 'same-origin'` — Access 쿠키가
 *   실리고 엣지가 JWT 를 붙인다)를 묻고 앱 메모리에 둔다. 본문은 엄격히 검사한다: `version === 2`, `sites[]` 각 항목
 *   `{id, name, hosts[], preview}` — 모양이 틀린 항목은 버리고, 쓸 항목이 하나도 없으면 목록 전체를 버린다.
 * - 실패(404 = 옛 릴레이·`-link-preview` 꺼짐, 그 밖의 상태, 네트워크, 깨진 본문)면 **내장 폴백** = v1 동작
 *   (x.com 계열 호스트 링크 + x status 미리보기, link-preview.js `statusUrl`). 목록이 오기 전에도 폴백으로 그린다.
 * - 결과는 「링크 집합」 하나로 묶는다: `hosts`(사람 말풍선 링크 = 모든 사이트 hosts 의 합집합), `serviceHosts`(서비스 봇 =
 *   합집합 + 인스타그램), `previewSiteFor(host)`(preview:true 사이트), `key`(렌더 서명 — 바뀌면 말풍선을 다시 그린다).
 * iOS·Android 클라이언트도 같은 규칙(계약 v2).
 */
import {xHosts, instagramHosts} from './service-links.js';

/** 사이트 목록 경로(계약 v2). */
export const SITES_PATH = '/v2/preview/sites';
/** 받아들일 사이트·사이트당 호스트 상한(릴레이 레지스트리는 8개 — 넉넉히, 이상한 본문이 메모리를 키우지 못하게). */
export const MAX_SITES = 64;
export const MAX_HOSTS = 32;
const MAX_NAME = 40;

const ID = /^[a-z0-9][a-z0-9-]{0,31}$/;
/** 소문자 평문 호스트 이름만: 라벨 1–63자(영숫자·하이픈, 하이픈으로 시작·끝 없음), 점 하나 이상, 마지막 라벨은 글자로 시작(IP 숫자 주소 거절). */
const HOST = /^(?=.{1,253}$)(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z](?:[a-z0-9-]{0,61}[a-z0-9])?$/;
// eslint-disable-next-line no-control-regex
const CONTROL = /[\u0000-\u001f\u007f-\u009f\u2028\u2029]/;

/** 사이트 항목 하나 → `{id, name, hosts, preview}`(얼린 사본), 모양이 틀리면 null. */
export function parseSite(entry) {
  if (!entry || typeof entry !== 'object' || Array.isArray(entry)) return null;
  const {id, name, hosts, preview} = entry;
  if (typeof id !== 'string' || !ID.test(id)) return null;
  if (typeof name !== 'string') return null;
  const label = name.trim();
  if (!label || label.length > MAX_NAME || CONTROL.test(label)) return null;
  if (typeof preview !== 'boolean') return null;
  if (!Array.isArray(hosts) || hosts.length === 0 || hosts.length > MAX_HOSTS) return null;
  if (!hosts.every((host) => typeof host === 'string' && HOST.test(host))) return null;
  return Object.freeze({id, name: label, hosts: Object.freeze([...new Set(hosts)]), preview});
}

/**
 * `GET /v2/preview/sites` 본문 → 사이트 배열(얼림), 쓸 수 없으면 null(→ 폴백).
 * 모양이 틀린 항목, 앞 항목과 id 가 겹치는 항목, 앞 항목의 호스트를 다시 쓰는 항목은 버린다(호스트 → 사이트가 하나로 정해지게).
 */
export function parseSites(body) {
  if (!body || typeof body !== 'object' || Array.isArray(body)) return null;
  if (body.version !== 2 || !Array.isArray(body.sites)) return null;
  const sites = [];
  const ids = new Set();
  const claimed = new Set();
  for (const entry of body.sites.slice(0, MAX_SITES)) {
    const site = parseSite(entry);
    if (!site || ids.has(site.id) || site.hosts.some((host) => claimed.has(host))) continue;
    ids.add(site.id);
    for (const host of site.hosts) claimed.add(host);
    sites.push(site);
  }
  return sites.length ? Object.freeze(sites) : null;
}

/** 내장 폴백 사이트(v1 = x.com 계열, 미리보기 있음). */
export const FALLBACK_SITES = Object.freeze([Object.freeze({id: 'x', name: 'X', hosts: Object.freeze([...xHosts]), preview: true})]);

/**
 * 사이트 배열 → 링크 집합.
 * @param {ReadonlyArray<{id:string,name:string,hosts:ReadonlyArray<string>,preview:boolean}>} sites
 * @param {'v2'|'fallback'} mode
 */
export function linkSet(sites, mode) {
  const hosts = new Set();
  const previewSites = new Map();
  for (const site of sites) {
    for (const host of site.hosts) {
      hosts.add(host);
      if (site.preview) previewSites.set(host, site);
    }
  }
  // 렌더 서명용 짧은 키 — 목록은 세션당 한 번 오므로 바뀌는 때는 폴백 → v2 한 번뿐이다.
  const key = mode === 'v2' ? `v2:${sites.map((s) => `${s.id}${s.preview ? '+' : '-'}`).join(',')}` : 'fallback';
  return Object.freeze({
    mode,
    key,
    sites,
    /** 사람 말풍선에서 누를 수 있는 호스트(모든 사이트의 합집합). */
    hosts,
    /** 서비스 봇 말풍선: 합집합 + 인스타그램(기존 `linkHosts` 유지). */
    serviceHosts: new Set([...instagramHosts, ...hosts]),
    /** 소문자 호스트 → preview:true 사이트, 아니면 null(링크만 사이트·모르는 호스트). */
    previewSiteFor(host) {
      return previewSites.get(String(host ?? '').toLowerCase()) ?? null;
    },
  });
}

/** 목록이 오기 전·실패 때 쓰는 링크 집합(v1 동작). */
export const FALLBACK_LINKS = linkSet(FALLBACK_SITES, 'fallback');

/**
 * @param {object} [deps]
 * @param {typeof fetch} [deps.fetch] 주입용(테스트). 기본은 전역 fetch.
 */
export function createPreviewSites({fetch = (...args) => globalThis.fetch(...args)} = {}) {
  let current = FALLBACK_LINKS;
  let loading = null;

  async function request() {
    try {
      const response = await fetch(SITES_PATH, {method: 'GET', credentials: 'same-origin'});
      if (!response || response.status !== 200) return null;
      let body = null;
      try { body = await response.json(); } catch (_) { body = null; }
      return parseSites(body);
    } catch (_) {
      return null;   // 네트워크 실패 — 이 세션은 폴백(v1)으로 둔다.
    }
  }

  return {
    /** 지금 쓸 링크 집합 — 목록이 오기 전·실패면 `FALLBACK_LINKS`. */
    get current() { return current; },
    /**
     * 세션당 한 번만 묻는다(겹쳐 불러도 요청은 하나). v2 목록으로 바뀌었으면 true(→ 부르는 쪽이 다시 그린다), 폴백 그대로면 false.
     * @returns {Promise<boolean>}
     */
    load() {
      loading ??= request().then((sites) => {
        if (!sites) return false;
        current = linkSet(sites, 'v2');
        return true;
      });
      return loading;
    },
  };
}
