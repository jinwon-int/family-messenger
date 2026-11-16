import test from 'node:test';
import assert from 'node:assert/strict';
import {linkParts, allowedHref, xHosts, linkHosts, agentLinkParts, agentHref} from '../service-links.js';

const join = (parts) => parts.map((p) => (typeof p === 'string' ? p : p.text)).join('');
const links = (parts) => parts.filter((p) => typeof p !== 'string').map((p) => p.href);

test('허용 호스트의 https 주소만 링크 — 나머지 글은 그대로, 조각을 이으면 원문', () => {
  const text = '• 계정 — 2건\n  - [릴스] "첫 줄" https://www.instagram.com/reel/AbC_1-x/\n  - [게시물] "둘째" https://instagram.com/p/XyZ/';
  const parts = linkParts(text);
  assert.equal(join(parts), text);
  assert.deepEqual(links(parts), ['https://www.instagram.com/reel/AbC_1-x/', 'https://instagram.com/p/XyZ/']);
});

test('문장부호 꼬리는 링크에서 뺀다', () => {
  const parts = linkParts('보기: https://www.instagram.com/p/AAA/). 끝');
  assert.deepEqual(links(parts), ['https://www.instagram.com/p/AAA/']);
  assert.equal(join(parts), '보기: https://www.instagram.com/p/AAA/). 끝');
});

test('http·다른 호스트·비슷한 호스트·사용자 정보·포트는 링크가 아님', () => {
  for (const bad of [
    'http://www.instagram.com/p/A/',
    'https://example.com/p/A/',
    'https://instagram.com.example.com/p/A/',
    'https://evil-instagram.com/p/A/',
    'https://user:pw@www.instagram.com/p/A/',
    'https://www.instagram.com:8443/p/A/',
    'instagram.com/p/A/',
  ]) {
    assert.equal(links(linkParts(`x ${bad} y`)).length, 0, bad);
    assert.equal(join(linkParts(`x ${bad} y`)), `x ${bad} y`);
  }
});

test('allowedHref: 대소문자 호스트는 허용, javascript: 는 거절', () => {
  assert.equal(allowedHref('https://WWW.Instagram.com/p/A/'), 'https://www.instagram.com/p/A/');
  assert.equal(allowedHref('javascript:alert(1)'), null);
  assert.equal(allowedHref('https://'), null);
});

test('링크 없는 글·빈 글', () => {
  assert.deepEqual(linkParts('그냥 글'), ['그냥 글']);
  assert.deepEqual(linkParts(''), ['']);
  assert.deepEqual(linkParts(undefined), ['']);
});

test('x.com 계열(#683): 서비스 봇 집합과 x 집합 모두에서 링크', () => {
  const text = '이거 봐 https://x.com/jack/status/20 그리고 https://twitter.com/i/web/status/1?s=20.';
  for (const hosts of [linkHosts, xHosts]) {
    const parts = linkParts(text, hosts);
    assert.equal(join(parts), text);
    assert.deepEqual(links(parts), ['https://x.com/jack/status/20', 'https://twitter.com/i/web/status/1?s=20']);
  }
  for (const host of ['www.x.com', 'mobile.x.com', 'www.twitter.com', 'mobile.twitter.com']) {
    assert.equal(allowedHref(`https://${host}/a/status/1`, xHosts), `https://${host}/a/status/1`);
  }
});

test('x 집합(사람·에이전트 말풍선)은 인스타그램·비슷한 호스트·http 를 링크로 만들지 않는다', () => {
  for (const bad of [
    'https://www.instagram.com/p/A/',
    'http://x.com/a/status/1',
    'https://x.com.evil.example/a',
    'https://evilx.com/a',
    'https://t.co/abc',
    'https://user@x.com/a',
    'https://x.com:444/a',
  ]) {
    assert.equal(links(linkParts(`보기 ${bad} 끝`, xHosts)).length, 0, bad);
    assert.equal(join(linkParts(`보기 ${bad} 끝`, xHosts)), `보기 ${bad} 끝`);
  }
});

test('기본 호스트 집합은 서비스 봇 집합(기존 호출 그대로)', () => {
  assert.equal(allowedHref('https://www.instagram.com/p/A/'), 'https://www.instagram.com/p/A/');
  assert.equal(allowedHref('https://x.com/a/status/1'), 'https://x.com/a/status/1');
  assert.ok(!xHosts.has('instagram.com'));
});

// ---- 에이전트 말풍선(오너 2026-11-16): 호스트 제한 없이 http·https 주소면 링크. iOS ServiceLinksTests·Android TextLinksTest 와 같은 벡터. ----

test('에이전트: 어떤 호스트든 http·https 주소는 링크 — 포트 허용, 조각을 이으면 원문', () => {
  const text = 'PR https://github.com/jinwon-int/family-messenger/pull/825 · 대시보드 http://100.64.0.1:8080/status 그리고 https://example.org';
  const parts = agentLinkParts(text);
  assert.equal(join(parts), text);
  assert.deepEqual(links(parts), [
    'https://github.com/jinwon-int/family-messenger/pull/825',
    'http://100.64.0.1:8080/status',
    'https://example.org/',
  ]);
});

test('에이전트: 끝 문장부호·한국어 낫표·괄호는 주소에서 뺀다, 짝 있는 괄호는 남긴다', () => {
  const cases = [
    ['확인: https://a.example/x.', 'https://a.example/x'],
    ['(https://a.example/x)', 'https://a.example/x'],
    ['「https://a.example/x」 참고', 'https://a.example/x'],
    ['주소（https://a.example/x）', 'https://a.example/x'],
    ['https://a.example/x。', 'https://a.example/x'],
    ['https://ko.wikipedia.org/wiki/Foo_(bar) 보기', 'https://ko.wikipedia.org/wiki/Foo_(bar)'],
    ['(위키 https://ko.wikipedia.org/wiki/Foo_(bar))', 'https://ko.wikipedia.org/wiki/Foo_(bar)'],
  ];
  for (const [text, href] of cases) {
    const parts = agentLinkParts(text);
    assert.deepEqual(links(parts), [href], text);
    assert.equal(join(parts), text, text);
  }
});

test('에이전트: 다른 스킴·사용자 정보가 붙은 주소는 글 그대로', () => {
  for (const bad of ['javascript:alert(1)', 'data:text/html,x', 'ftp://a.example/x', 'https://bank.example@evil.example/a', 'https://u:p@a.example/', 'https://', 'hande-alert://3']) {
    assert.equal(links(agentLinkParts(`보기 ${bad} 끝`)).length, 0, bad);
    assert.equal(join(agentLinkParts(`보기 ${bad} 끝`)), `보기 ${bad} 끝`);
  }
  assert.equal(agentHref('javascript:alert(1)'), null);
  assert.equal(agentHref('HTTPS://A.Example/X'), 'https://a.example/X');
  assert.deepEqual(agentLinkParts(''), ['']);
  assert.deepEqual(agentLinkParts('주소 없음'), ['주소 없음']);
});
