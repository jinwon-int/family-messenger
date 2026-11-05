// x.com 링크 미리보기(#683 2단계, 「2단계 API 계약 v1」 클라이언트 절). node --test archive/native-mls/web/hande/tests/link-preview.test.mjs
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { previewTarget, statusUrl, cardFrom, createLinkPreviews, IMAGE_PREFIX } from '../link-preview.js';
import { SHELL_ASSETS } from '../sw-policy.js';

test('previewTarget: x.com 계열 글 주소 → 정규 URL(뒤 경로·쿼리·조각은 버림)', () => {
  const cases = [
    ['https://x.com/jack/status/20', 'https://x.com/jack/status/20'],
    ['https://www.x.com/jack/status/20', 'https://x.com/jack/status/20'],
    ['https://mobile.x.com/jack/status/20', 'https://x.com/jack/status/20'],
    ['https://twitter.com/jack/status/20', 'https://x.com/jack/status/20'],
    ['https://www.twitter.com/jack/status/20', 'https://x.com/jack/status/20'],
    ['https://mobile.twitter.com/jack/status/20', 'https://x.com/jack/status/20'],
    ['https://X.COM/Jack_1/status/1234567890123456789', 'https://x.com/Jack_1/status/1234567890123456789'],
    ['https://x.com/jack/status/20/photo/1', 'https://x.com/jack/status/20'],
    ['https://x.com/jack/status/20?s=20&t=abc', 'https://x.com/jack/status/20'],
    ['https://x.com/jack/status/20#frag', 'https://x.com/jack/status/20'],
    ['https://x.com/jack/status/20/', 'https://x.com/jack/status/20'],
    ['https://x.com/i/web/status/1849', 'https://x.com/i/web/status/1849'],
    ['https://twitter.com/i/web/status/1849?ref=x', 'https://x.com/i/web/status/1849'],
    ['https://x.com/abcdefghijklmno/status/1', 'https://x.com/abcdefghijklmno/status/1'],            // handle 15자
    [`https://x.com/a/status/${'9'.repeat(25)}`, `https://x.com/a/status/${'9'.repeat(25)}`],       // id 25자리
  ];
  for (const [input, expected] of cases) {
    assert.equal(previewTarget(`보세요 ${input} 재밌어요`), expected, input);
    assert.equal(statusUrl(input), expected, input);
  }
});

test('previewTarget: 글 주소가 아니거나 허용 밖이면 null', () => {
  for (const bad of [
    'http://x.com/jack/status/20',                       // https 아님
    'https://user@x.com/jack/status/20',                 // 사용자 정보
    'https://user:pw@x.com/jack/status/20',
    'https://x.com:8443/jack/status/20',                 // 포트
    'https://x.com.evil.example/jack/status/20',         // 비슷한 호스트
    'https://evilx.com/jack/status/20',
    'https://t.co/abcdef',                               // 단축 주소(호스트 밖)
    'https://www.instagram.com/p/AbC/',                  // 서비스 봇 호스트지만 x.com 아님
    'https://x.com/jack',                                // 프로필
    'https://x.com/home',
    'https://x.com/jack/status/',                        // id 없음
    'https://x.com/jack/status/abc',                     // id 숫자 아님
    `https://x.com/jack/status/${'1'.repeat(26)}`,       // id 26자리
    'https://x.com/abcdefghijklmnop/status/1',           // handle 16자
    'https://x.com/ja-ck/status/1',                      // handle 허용 문자 밖
    'https://x.com/jack/statuses/1',
    'https://x.com/jack/Status/1',
    'https://x.com/i/web/status/abc',
    'https://x.com/i/web/1',
    'https://x.com//status/1',
    'x.com/jack/status/20',                              // 스킴 없음
    'javascript:alert(1)',
  ]) {
    assert.equal(previewTarget(`x ${bad} y`), null, bad);
  }
  assert.equal(previewTarget(''), null);
  assert.equal(previewTarget(null), null);
  assert.equal(previewTarget(undefined), null);
  assert.equal(statusUrl('not a url'), null);
});

test('previewTarget: 첫 번째 글 주소만 — 글 주소가 아닌 x.com 링크는 건너뛴다', () => {
  const text = '프로필 https://x.com/jack 그리고 https://twitter.com/a/status/1 또 https://x.com/b/status/2';
  assert.equal(previewTarget(text), 'https://x.com/a/status/1');
  assert.equal(previewTarget('https://x.com/a/status/1 https://x.com/b/status/2'), 'https://x.com/a/status/1');
  // 문장부호 꼬리는 1단계 linkParts 처럼 떼어 낸다.
  assert.equal(previewTarget('(https://x.com/a/status/7).'), 'https://x.com/a/status/7');
  assert.equal(previewTarget('끝에 https://x.com/a/status/7…'), 'https://x.com/a/status/7');
});

test('cardFrom: 제목·본문 중 하나는 있어야 하고, image 는 릴레이 상대 경로만', () => {
  const t = 'https://x.com/a/status/1';
  const image = `${IMAGE_PREFIX}${encodeURIComponent('https://pbs.twimg.com/media/x.jpg')}`;
  assert.deepEqual(cardFrom(t, { url: t, site: 'X', title: ' 제목 ', description: '본문', image }), { url: t, title: '제목', description: '본문', image });
  assert.deepEqual(cardFrom(t, { title: '제목', description: null, image: null }), { url: t, title: '제목', description: '', image: null });
  assert.equal(cardFrom(t, { title: '', description: '  ', image }), null);
  assert.equal(cardFrom(t, null), null);
  assert.equal(cardFrom(t, 'nope'), null);
  for (const badImage of ['https://pbs.twimg.com/media/x.jpg', '//evil.example/x.jpg', '/v2/other', 'javascript:alert(1)', `${IMAGE_PREFIX}a b`, 42]) {
    assert.equal(cardFrom(t, { title: '제목', image: badImage }).image, null, String(badImage));
  }
  // 카드 url 은 응답이 아니라 우리가 만든 정규 주소다.
  assert.equal(cardFrom(t, { url: 'https://evil.example/', title: '제목' }).url, t);
});

function jsonResponse(status, body) {
  return { status, ok: status >= 200 && status < 300, json: async () => body };
}

function fakeFetch(handler) {
  const calls = [];
  const fetch = async (path, init) => { calls.push({ path, init }); return handler(path, init, calls.length); };
  return { fetch, calls };
}

test('get: 같은 origin /v2/preview?url=… 를 same-origin 자격으로 한 번만 묻고, 결과를 기억한다', async () => {
  const t = 'https://x.com/a/status/1';
  const { fetch, calls } = fakeFetch(() => jsonResponse(200, { url: t, site: 'X', title: '제목', description: '본문', image: null }));
  const previews = createLinkPreviews({ fetch });
  assert.equal(previews.peek(t), undefined, '아직 모름');
  const card = await previews.get(t);
  assert.deepEqual(card, { url: t, title: '제목', description: '본문', image: null });
  assert.equal(calls.length, 1);
  assert.equal(calls[0].path, `/v2/preview?url=${encodeURIComponent(t)}`);
  assert.equal(calls[0].init.method, 'GET');
  assert.equal(calls[0].init.credentials, 'same-origin');
  assert.deepEqual(await previews.get(t), card);
  assert.deepEqual(previews.peek(t), card);
  assert.equal(calls.length, 1, '두 번째는 캐시');
});

test('get: 404(라우트 꺼짐·no_preview)·502·400·401·네트워크 실패·깨진 본문 → null, 그리고 다시 묻지 않는다(음성 캐시)', async () => {
  const outcomes = {
    'https://x.com/a/status/1': () => jsonResponse(404, { error: 'no_preview' }),
    'https://x.com/a/status/2': () => jsonResponse(404, null),           // -link-preview off: 라우트 없음
    'https://x.com/a/status/3': () => jsonResponse(502, { error: 'upstream_failed' }),
    'https://x.com/a/status/4': () => jsonResponse(400, { error: 'bad_url' }),
    'https://x.com/a/status/5': () => jsonResponse(401, null),
    'https://x.com/a/status/6': () => { throw new TypeError('Failed to fetch'); },
    'https://x.com/a/status/7': () => ({ status: 200, json: async () => { throw new SyntaxError('bad json'); } }),
    'https://x.com/a/status/8': () => jsonResponse(200, { title: '', description: '' }),
  };
  const { fetch, calls } = fakeFetch((path) => outcomes[decodeURIComponent(path.split('url=')[1])]());
  const previews = createLinkPreviews({ fetch });
  for (const t of Object.keys(outcomes)) {
    assert.equal(await previews.get(t), null, t);
    assert.equal(previews.peek(t), null, `${t} 는 「카드 없음」으로 기억`);
  }
  const first = calls.length;
  assert.equal(first, Object.keys(outcomes).length);
  for (const t of Object.keys(outcomes)) assert.equal(await previews.get(t), null);
  assert.equal(calls.length, first, '음성 결과도 다시 묻지 않는다');
});

test('get: 겹쳐 물으면 요청은 하나 — 끝나기 전 peek 은 undefined', async () => {
  const t = 'https://x.com/a/status/1';
  let release;
  const { fetch, calls } = fakeFetch(() => new Promise((resolve) => { release = () => resolve(jsonResponse(200, { title: '제목' })); }));
  const previews = createLinkPreviews({ fetch });
  const a = previews.get(t);
  const b = previews.get(t);
  assert.equal(previews.peek(t), undefined);
  assert.equal(calls.length, 1);
  release();
  const [ca, cb] = await Promise.all([a, b]);
  assert.equal(ca.title, '제목');
  assert.equal(ca, cb);
});

test('get: 잘못된 대상은 묻지 않고 null, 캐시는 상한을 넘으면 오래된 것부터 버린다', async () => {
  const { fetch, calls } = fakeFetch(() => jsonResponse(200, { title: '제목' }));
  const previews = createLinkPreviews({ fetch, maxEntries: 2 });
  assert.equal(await previews.get(''), null);
  assert.equal(await previews.get(null), null);
  assert.equal(calls.length, 0);
  await previews.get('https://x.com/a/status/1');
  await previews.get('https://x.com/a/status/2');
  await previews.get('https://x.com/a/status/3');
  assert.equal(previews.size, 2);
  assert.equal(previews.peek('https://x.com/a/status/1'), undefined, '가장 오래된 것이 빠짐');
  assert.ok(previews.peek('https://x.com/a/status/3'));
  await previews.get('https://x.com/a/status/1');
  assert.equal(calls.length, 4, '버린 것은 다시 묻는다');
});

test('link-preview.js 가 build.sh 배포 목록과 SHELL_ASSETS 에 있다(ui.js 가 import — 빠지면 앱이 안 뜬다)', () => {
  assert.ok(SHELL_ASSETS.includes('./link-preview.js'));
  const build = readFileSync(new URL('../build.sh', import.meta.url), 'utf8');
  assert.match(build, /\slink-preview\.js\s/);
  const ui = readFileSync(new URL('../ui.js', import.meta.url), 'utf8');
  assert.match(ui, /from '\.\/link-preview\.js'/);
  assert.doesNotMatch(ui.slice(ui.indexOf('function linkCard'), ui.indexOf('function agentMarkdownBody')), /innerHTML/, '카드는 텍스트 노드로만');
});
