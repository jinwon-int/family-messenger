// 미리보기 사이트 목록 v2(#690 「계약 v2」 클라이언트 절). node --test archive/native-mls/web/hande/tests/preview-sites.test.mjs
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import {
  parseSites, parseSite, linkSet, createPreviewSites, FALLBACK_LINKS, FALLBACK_SITES, SITES_PATH, MAX_SITES,
} from '../preview-sites.js';
import { linkParts, xHosts, linkHosts } from '../service-links.js';
import { previewTarget, createLinkPreviews } from '../link-preview.js';
import { SHELL_ASSETS } from '../sw-policy.js';

/** 계약 v2 레지스트리(릴레이 `GET /v2/preview/sites` 가 줄 모양). */
const CONTRACT = {
  version: 2,
  sites: [
    { id: 'x', name: 'X', hosts: ['x.com', 'www.x.com', 'mobile.x.com', 'twitter.com', 'www.twitter.com', 'mobile.twitter.com'], preview: true },
    { id: 'youtube', name: 'YouTube', hosts: ['youtube.com', 'www.youtube.com', 'm.youtube.com', 'youtu.be'], preview: true },
    { id: 'naver-news', name: '네이버 뉴스', hosts: ['n.news.naver.com', 'news.naver.com', 'm.news.naver.com'], preview: true },
    { id: 'wikipedia', name: '위키백과', hosts: ['ko.wikipedia.org', 'en.wikipedia.org', 'ko.m.wikipedia.org', 'en.m.wikipedia.org'], preview: true },
    { id: 'github', name: 'GitHub', hosts: ['github.com', 'www.github.com'], preview: true },
    { id: 'bbc', name: 'BBC', hosts: ['bbc.com', 'www.bbc.com', 'bbc.co.uk', 'www.bbc.co.uk'], preview: true },
    { id: 'threads', name: 'Threads', hosts: ['threads.net', 'www.threads.net', 'threads.com', 'www.threads.com'], preview: false },
    { id: 'reuters', name: 'Reuters', hosts: ['reuters.com', 'www.reuters.com'], preview: false },
  ],
};

const v2 = () => linkSet(parseSites(CONTRACT), 'v2');
const links = (parts) => parts.filter((p) => typeof p !== 'string').map((p) => p.href);
const join = (parts) => parts.map((p) => (typeof p === 'string' ? p : p.text)).join('');

function jsonResponse(status, body) {
  return { status, ok: status >= 200 && status < 300, json: async () => body };
}
function fakeFetch(handler) {
  const calls = [];
  const fetch = async (path, init) => { calls.push({ path, init }); return handler(path, init, calls.length); };
  return { fetch, calls };
}

// ---- 본문 검사 ----

test('parseSites: 계약 모양은 그대로 받는다(순서·이름·preview 유지, 얼린 사본)', () => {
  const sites = parseSites(CONTRACT);
  assert.equal(sites.length, 8);
  assert.deepEqual(sites.map((s) => s.id), CONTRACT.sites.map((s) => s.id));
  assert.deepEqual(sites.map((s) => s.preview), [true, true, true, true, true, true, false, false]);
  assert.equal(sites[2].name, '네이버 뉴스');
  assert.deepEqual([...sites[1].hosts], CONTRACT.sites[1].hosts);
  assert.ok(Object.isFrozen(sites) && Object.isFrozen(sites[0]) && Object.isFrozen(sites[0].hosts));
  // 모르는 필드는 무시(앞으로 릴레이가 더해도 깨지지 않게).
  assert.equal(parseSites({ version: 2, extra: 1, sites: [{ ...CONTRACT.sites[0], ua: 'Twitterbot/1.0' }] }).length, 1);
});

test('parseSites: 본문 자체가 틀리면 null(→ 폴백)', () => {
  for (const bad of [
    null, undefined, 'x', 42, [], {},
    { version: 1, sites: CONTRACT.sites },
    { version: '2', sites: CONTRACT.sites },
    { version: 3, sites: CONTRACT.sites },
    { version: 2 },
    { version: 2, sites: {} },
    { version: 2, sites: 'x.com' },
    { version: 2, sites: [] },                                   // 쓸 항목 없음
    { version: 2, sites: [null, 1, 'x', { id: 'x' }] },          // 전부 틀린 항목
  ]) {
    assert.equal(parseSites(bad), null, JSON.stringify(bad));
  }
});

test('parseSite: 틀린 항목은 버린다(id·name·hosts·preview)', () => {
  const good = { id: 'youtube', name: 'YouTube', hosts: ['youtube.com', 'youtu.be'], preview: true };
  assert.ok(parseSite(good));
  for (const [why, patch] of [
    ['id 없음', { id: undefined }],
    ['id 대문자', { id: 'YouTube' }],
    ['id 공백', { id: 'you tube' }],
    ['id 너무 김', { id: 'a'.repeat(33) }],
    ['id 숫자', { id: 7 }],
    ['name 없음', { name: undefined }],
    ['name 빈칸', { name: '   ' }],
    ['name 제어 문자', { name: 'You\nTube' }],
    ['name 너무 김', { name: 'Y'.repeat(41) }],
    ['name 문자열 아님', { name: ['YouTube'] }],
    ['preview 문자열', { preview: 'true' }],
    ['preview 숫자', { preview: 1 }],
    ['preview 없음', { preview: undefined }],
    ['hosts 없음', { hosts: undefined }],
    ['hosts 빈 배열', { hosts: [] }],
    ['hosts 문자열', { hosts: 'youtube.com' }],
    ['hosts 너무 많음', { hosts: Array.from({ length: 33 }, (_, i) => `h${i}.example.com`) }],
  ]) {
    assert.equal(parseSite({ ...good, ...patch }), null, why);
  }
  assert.equal(parseSite(null), null);
  assert.equal(parseSite([good]), null);
  assert.equal(parseSite('youtube'), null);
});

test('parseSite: hosts 는 소문자 평문 호스트 이름만 — 하나라도 틀리면 항목 전체를 버린다', () => {
  const site = (hosts) => parseSite({ id: 's', name: 'S', hosts, preview: true });
  for (const host of ['youtube.com', 'youtu.be', 'n.news.naver.com', 'ko.m.wikipedia.org', 'bbc.co.uk', 'a-b.example', 'xn--3e0b707e.xn--3e0b707e']) {
    assert.ok(site([host]), host);
  }
  for (const host of [
    'YouTube.com', 'WWW.X.COM',                  // 대문자(계약: 소문자 정확히)
    'https://youtube.com', 'youtube.com/', 'youtube.com/watch', '//youtube.com',
    'youtube.com:443', 'user@youtube.com', '*.youtube.com', '.youtube.com', 'youtube.com.', 'youtube..com',
    'localhost', 'youtube',                       // 점 없는 이름
    '127.0.0.1', '10.0.0.1', '[::1]', '::1',      // IP 주소
    '-youtube.com', 'youtube-.com', 'you tube.com', 'you_tube.com', '유튜브.com', ' youtube.com', 'youtube.com ',
    '', 42, null,
    `${'a'.repeat(64)}.com`,                      // 라벨 64자
  ]) {
    assert.equal(site([host]), null, String(host));
    assert.equal(site(['youtube.com', host]), null, `섞임: ${String(host)}`);
  }
  // 같은 호스트가 두 번이면 한 번으로.
  assert.deepEqual([...site(['youtu.be', 'youtu.be']).hosts], ['youtu.be']);
});

test('parseSites: 틀린 항목·겹치는 id·이미 쓴 호스트는 그 항목만 버리고 나머지는 쓴다', () => {
  const sites = parseSites({
    version: 2,
    sites: [
      CONTRACT.sites[1],                                                         // youtube
      { id: 'evil', name: 'Evil', hosts: ['EVIL.example'], preview: true },      // 대문자 호스트 — 버림
      { id: 'youtube', name: 'Dup', hosts: ['dup.example'], preview: true },     // 겹치는 id — 버림
      { id: 'steal', name: 'Steal', hosts: ['youtu.be'], preview: false },       // 이미 youtube 의 호스트 — 버림
      'garbage',
      CONTRACT.sites[7],                                                         // reuters
    ],
  });
  assert.deepEqual(sites.map((s) => s.id), ['youtube', 'reuters']);
  const set = linkSet(sites, 'v2');
  assert.equal(set.previewSiteFor('youtu.be').id, 'youtube');
  assert.ok(!set.hosts.has('evil.example') && !set.hosts.has('dup.example'));
});

test('parseSites: 사이트 수 상한(MAX_SITES) 밖은 보지 않는다', () => {
  const many = Array.from({ length: MAX_SITES + 5 }, (_, i) => ({ id: `s${i}`, name: `S${i}`, hosts: [`s${i}.example`], preview: false }));
  assert.equal(parseSites({ version: 2, sites: many }).length, MAX_SITES);
});

// ---- 링크 집합 ----

test('FALLBACK_LINKS: v1 과 같다 — 사람 = xHosts, 서비스 봇 = linkHosts(인스타그램 + x), 미리보기 = x', () => {
  assert.equal(FALLBACK_LINKS.mode, 'fallback');
  assert.equal(FALLBACK_LINKS.key, 'fallback');
  assert.deepEqual([...FALLBACK_LINKS.hosts].sort(), [...xHosts].sort());
  assert.deepEqual([...FALLBACK_LINKS.serviceHosts].sort(), [...linkHosts].sort());
  assert.equal(FALLBACK_LINKS.previewSiteFor('twitter.com').id, 'x');
  assert.equal(FALLBACK_LINKS.previewSiteFor('youtube.com'), null);
  assert.equal(FALLBACK_SITES.length, 1);
});

test('링크: v2 는 모든 사이트 hosts 의 합집합(Threads·Reuters 링크만 포함), 서비스 봇은 인스타그램도', () => {
  const set = v2();
  const text = [
    'https://www.youtube.com/watch?v=dQw4w9WgXcQ', 'https://youtu.be/dQw4w9WgXcQ', 'https://n.news.naver.com/article/001/0012345678',
    'https://ko.wikipedia.org/wiki/%EB%8C%80%ED%95%9C%EB%AF%BC%EA%B5%AD', 'https://github.com/jinwon-int/family-messenger',
    'https://www.bbc.com/news/articles/c0abcdef12', 'https://x.com/jack/status/20',
    'https://www.threads.net/@zuck/post/C1', 'https://www.reuters.com/world/some-story-2026-11-05/',
  ].join(' 그리고 ');
  const person = linkParts(text, set.hosts);
  assert.equal(join(person), text);
  assert.equal(links(person).length, 9);
  assert.ok(links(person).includes('https://www.threads.net/@zuck/post/C1'));
  assert.ok(links(person).includes('https://www.reuters.com/world/some-story-2026-11-05/'));
  // 사람 말풍선은 인스타그램·목록 밖 호스트를 링크로 만들지 않는다.
  for (const bad of ['https://www.instagram.com/p/A/', 'https://example.com/a', 'https://youtube.com.evil.example/watch?v=dQw4w9WgXcQ',
    'http://www.youtube.com/watch?v=dQw4w9WgXcQ', 'https://user@github.com/a/b', 'https://github.com:444/a/b', 'https://fr.wikipedia.org/wiki/Paris']) {
    assert.deepEqual(links(linkParts(`보기 ${bad} 끝`, set.hosts)), [], bad);
  }
  // 서비스 봇: 합집합 + 인스타그램.
  assert.deepEqual(links(linkParts('https://www.instagram.com/p/A/ https://www.reuters.com/a', set.serviceHosts)),
    ['https://www.instagram.com/p/A/', 'https://www.reuters.com/a']);
  // 링크만 사이트는 미리보기 사이트가 아니다.
  assert.equal(set.previewSiteFor('www.threads.net'), null);
  assert.equal(set.previewSiteFor('reuters.com'), null);
  assert.equal(set.previewSiteFor('M.YOUTUBE.COM').id, 'youtube');
  assert.match(set.key, /^v2:/);
  assert.notEqual(set.key, FALLBACK_LINKS.key);
});

// ---- 카드 대상 ----

test('previewTarget(v2): 첫 미리보기 사이트 링크를 그대로 — YouTube·네이버·위키백과·GitHub·BBC·x', () => {
  const set = v2();
  for (const href of [
    'https://www.youtube.com/watch?v=dQw4w9WgXcQ',
    'https://youtu.be/dQw4w9WgXcQ',
    'https://m.youtube.com/shorts/dQw4w9WgXcQ',
    'https://n.news.naver.com/article/001/0012345678',
    'https://m.news.naver.com/mnews/article/001/0012345678?sid=100',
    'https://ko.wikipedia.org/wiki/%EB%8C%80%ED%95%9C%EB%AF%BC%EA%B5%AD',
    'https://en.m.wikipedia.org/wiki/Seoul',
    'https://github.com/jinwon-int/family-messenger/issues/690',
    'https://www.bbc.com/news/articles/c0abcdef12',
    'https://www.bbc.co.uk/news/articles/c0abcdef12',
    'https://x.com/jack/status/20?s=20',          // v2 에서는 정규화하지 않는다(릴레이 몫).
    'https://x.com/jack',                         // 경로 판정도 릴레이 몫 — 400 이면 카드 없음.
  ]) {
    assert.equal(previewTarget(`보세요 ${href} 재밌어요`, set), href, href);
  }
  // 대문자 호스트는 URL 이 소문자로 맞춘 href 로(말풍선 링크 href 와 같다).
  assert.equal(previewTarget('https://WWW.YouTube.com/watch?v=dQw4w9WgXcQ', set), 'https://www.youtube.com/watch?v=dQw4w9WgXcQ');
  // 위키백과 한글 제목은 링크 href(퍼센트 인코딩)로 — 카드 href 와 같은 값.
  assert.equal(previewTarget('https://ko.wikipedia.org/wiki/서울 보기', set), 'https://ko.wikipedia.org/wiki/%EC%84%9C%EC%9A%B8');
});

test('previewTarget(v2): 링크만 사이트(Threads·Reuters)·목록 밖은 건너뛰고 다음 미리보기 사이트 링크를 본다', () => {
  const set = v2();
  assert.equal(previewTarget('https://www.threads.net/@a/post/1 https://www.reuters.com/a https://github.com/a/b', set), 'https://github.com/a/b');
  assert.equal(previewTarget('https://example.com/a https://www.instagram.com/p/A/ (https://www.bbc.com/news/articles/c0abcdef12).', set),
    'https://www.bbc.com/news/articles/c0abcdef12');
  assert.equal(previewTarget('https://youtu.be/AAAAAAAAAAA 그리고 https://x.com/a/status/1', set), 'https://youtu.be/AAAAAAAAAAA', '첫 링크만');
  assert.equal(previewTarget('https://www.threads.net/@a/post/1 https://www.reuters.com/a', set), null);
  assert.equal(previewTarget('http://www.youtube.com/watch?v=dQw4w9WgXcQ', set), null);
  assert.equal(previewTarget('', set), null);
  assert.equal(previewTarget(null, set), null);
});

test('previewTarget(폴백): v1 그대로 — x status 만, 정규형, 다른 사이트는 대상 아님', () => {
  for (const set of [FALLBACK_LINKS, undefined]) {
    assert.equal(previewTarget('https://x.com/jack/status/20/photo/1?s=1', set), 'https://x.com/jack/status/20');
    assert.equal(previewTarget('https://x.com/jack https://twitter.com/a/status/1', set), 'https://x.com/a/status/1');
    assert.equal(previewTarget('https://www.youtube.com/watch?v=dQw4w9WgXcQ', set), null);
    assert.equal(previewTarget('https://github.com/a/b https://x.com/jack', set), null);
  }
});

// ---- 불러오기 ----

test('load: 같은 origin GET /v2/preview/sites 를 same-origin 자격으로 세션당 한 번 — 오면 v2 링크 집합', async () => {
  const { fetch, calls } = fakeFetch(() => jsonResponse(200, CONTRACT));
  const sites = createPreviewSites({ fetch });
  assert.equal(sites.current, FALLBACK_LINKS, '오기 전에는 폴백');
  const [a, b] = await Promise.all([sites.load(), sites.load()]);
  assert.equal(a, true);
  assert.equal(b, true);
  assert.equal(calls.length, 1, '겹쳐 불러도 요청은 하나');
  assert.equal(calls[0].path, SITES_PATH);
  assert.equal(calls[0].path, '/v2/preview/sites');
  assert.equal(calls[0].init.method, 'GET');
  assert.equal(calls[0].init.credentials, 'same-origin');
  assert.equal(sites.current.mode, 'v2');
  assert.equal(sites.current.sites.length, 8);
  assert.equal(await sites.load(), true);
  assert.equal(calls.length, 1, '다시 묻지 않는다');
});

test('load: 404(옛 릴레이·플래그 꺼짐)·401·500·네트워크·깨진 본문·틀린 version → 폴백(v1) 그대로, 다시 묻지 않는다', async () => {
  for (const [why, handler] of [
    ['404 라우트 없음', () => jsonResponse(404, null)],
    ['404 본문', () => jsonResponse(404, { error: 'not_found' })],
    ['401', () => jsonResponse(401, null)],
    ['500', () => jsonResponse(500, { error: 'x' })],
    ['네트워크', () => { throw new TypeError('Failed to fetch'); }],
    ['깨진 JSON', () => ({ status: 200, json: async () => { throw new SyntaxError('bad'); } })],
    ['version 1', () => jsonResponse(200, { version: 1, sites: CONTRACT.sites })],
    ['빈 목록', () => jsonResponse(200, { version: 2, sites: [] })],
    ['응답 없음', () => undefined],
  ]) {
    const { fetch, calls } = fakeFetch(handler);
    const sites = createPreviewSites({ fetch });
    assert.equal(await sites.load(), false, why);
    assert.equal(sites.current, FALLBACK_LINKS, why);
    assert.equal(await sites.load(), false);
    assert.equal(calls.length, 1, `${why}: 세션당 한 번`);
  }
});

test('v2 에서 카드 요청: /v2/preview?url=<링크 그대로>, 400·404·502·네트워크는 카드 없음 + URL별 음성 캐시', async () => {
  const set = v2();
  const yt = previewTarget('https://youtu.be/dQw4w9WgXcQ', set);
  const gh = previewTarget('https://github.com/a', set);           // 릴레이 경로 규칙 밖 → 400 bad_url
  const wiki = previewTarget('https://en.wikipedia.org/wiki/Seoul', set);
  const bbc = previewTarget('https://www.bbc.com/news/articles/c0abcdef12', set);
  const naver = previewTarget('https://n.news.naver.com/article/001/0012345678', set);
  const outcomes = {
    [yt]: () => jsonResponse(200, { url: 'https://www.youtube.com/watch?v=dQw4w9WgXcQ', site: 'YouTube', title: '영상', description: '', image: '/v2/preview/image?u=https%3A%2F%2Fi.ytimg.com%2Fvi%2Fa%2Fhq.jpg' }),
    [gh]: () => jsonResponse(400, { error: 'bad_url' }),
    [wiki]: () => jsonResponse(404, { error: 'no_preview' }),
    [bbc]: () => jsonResponse(502, { error: 'upstream_failed' }),
    [naver]: () => { throw new TypeError('Failed to fetch'); },
  };
  const { fetch, calls } = fakeFetch((path) => outcomes[decodeURIComponent(path.split('url=')[1])]());
  const previews = createLinkPreviews({ fetch });
  const card = await previews.get(yt);
  assert.equal(calls[0].path, `/v2/preview?url=${encodeURIComponent('https://youtu.be/dQw4w9WgXcQ')}`);
  assert.equal(card.url, 'https://youtu.be/dQw4w9WgXcQ', '카드 href = 원 링크(응답 url 아님)');
  assert.equal(card.site, 'YouTube');
  assert.equal(card.image, '/v2/preview/image?u=https%3A%2F%2Fi.ytimg.com%2Fvi%2Fa%2Fhq.jpg');
  for (const t of [gh, wiki, bbc, naver]) {
    assert.equal(await previews.get(t), null, t);
    assert.equal(previews.peek(t), null, `${t} 음성 캐시`);
  }
  const asked = calls.length;
  for (const t of [yt, gh, wiki, bbc, naver]) await previews.get(t);
  assert.equal(calls.length, asked, '다시 묻지 않는다');
});

test('preview-sites.js 가 build.sh 배포 목록과 SHELL_ASSETS 에 있고, app.js 가 불러 ui 에 links 로 넘긴다', () => {
  assert.ok(SHELL_ASSETS.includes('./preview-sites.js'));
  const build = readFileSync(new URL('../build.sh', import.meta.url), 'utf8');
  assert.match(build, /\spreview-sites\.js\s/);
  const app = readFileSync(new URL('../app.js', import.meta.url), 'utf8');
  assert.match(app, /from '\.\/preview-sites\.js'/);
  assert.match(app, /links: previewSites\.current/);
  const ui = readFileSync(new URL('../ui.js', import.meta.url), 'utf8');
  assert.match(ui, /from '\.\/preview-sites\.js'/);
  assert.match(ui, /link-card-site/);
  assert.doesNotMatch(ui.slice(ui.indexOf('function linkCard'), ui.indexOf('function agentMarkdownBody')), /innerHTML/, '카드는 텍스트 노드로만');
  const css = readFileSync(new URL('../styles.css', import.meta.url), 'utf8');
  assert.match(css, /\.link-card \.link-card-site \{/);
});
