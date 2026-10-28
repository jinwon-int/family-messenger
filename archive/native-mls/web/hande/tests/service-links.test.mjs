import test from 'node:test';
import assert from 'node:assert/strict';
import {linkParts, allowedHref} from '../service-links.js';

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
