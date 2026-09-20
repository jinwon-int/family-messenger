import test from 'node:test';
import assert from 'node:assert/strict';
import { DEFAULT_CONFIG, loadConfig, sanitizeConfig } from '../src/config.js';

test('sanitizeConfig: https 파일보관함 URL만 받고 제목은 선택', () => {
  assert.deepEqual(sanitizeConfig({ filebox: { url: 'https://files.example.com', title: '파일보관함' } }), { filebox: { url: 'https://files.example.com/', title: '파일보관함' }, homeserverUrl: null, push: null });
  assert.deepEqual(sanitizeConfig({ filebox: { url: 'https://files.example.com/' } }), { filebox: { url: 'https://files.example.com/', title: null }, homeserverUrl: null, push: null });
  assert.deepEqual(sanitizeConfig({ filebox: { url: 'http://files.example.com/' } }), { filebox: null, homeserverUrl: null, push: null });
  assert.deepEqual(sanitizeConfig({ filebox: { url: 'javascript:alert(1)' } }), { filebox: null, homeserverUrl: null, push: null });
  assert.deepEqual(sanitizeConfig({ filebox: { url: 'not a url' } }), { filebox: null, homeserverUrl: null, push: null });
  assert.deepEqual(sanitizeConfig({}), { filebox: null, homeserverUrl: null, push: null });
  assert.deepEqual(sanitizeConfig(null), { filebox: null, homeserverUrl: null, push: null });
});

test('loadConfig: config.json이 없거나 깨지면 기본값, 있으면 정제해서 돌려준다', async () => {
  assert.deepEqual(await loadConfig(async () => ({ ok: false })), DEFAULT_CONFIG);
  assert.deepEqual(await loadConfig(async () => { throw new Error('offline'); }), DEFAULT_CONFIG);
  assert.deepEqual(await loadConfig(async () => ({ ok: true, json: async () => { throw new Error('bad json'); } })), DEFAULT_CONFIG);
  const calls = [];
  const loaded = await loadConfig(async (url, opts) => { calls.push([url, opts]); return { ok: true, json: async () => ({ filebox: { url: 'https://f.example.com/' } }) }; });
  assert.deepEqual(loaded, { filebox: { url: 'https://f.example.com/', title: null }, homeserverUrl: null, push: null });
  assert.deepEqual(calls, [['./config.json', { cache: 'no-store' }]]);
});

// 형식만 유효한 표본 키다(비압축 P-256 점 65바이트 → 패딩 없는 base64url 87자).
// 어떤 배포의 실제 키도 아니며, 개인키는 저장소에 두지 않는다.
const SAMPLE_KEY = 'BIY-ucjgRHPAYhdIh6AU91y-yCYABUaROXg3L-_ghS-tRwZAxJsu8KxM_p7pWyUcLxM_LDbGZJlzf54BkzeAuSI';
const PUSH = { gatewayUrl: 'https://push.example.com/_matrix/push/v1/notify', appId: 'com.example.familychat.web', applicationServerKey: SAMPLE_KEY };

test('sanitizeConfig: 푸시 설정은 세 값이 모두 유효할 때만 통과한다', () => {
  assert.deepEqual(sanitizeConfig({ push: PUSH }).push, PUSH);

  // 반쪽 설정은 전부 null — 구독만 생기고 게이트웨이가 서명하지 못하는 상태를 만들지 않는다.
  for (const missing of ['gatewayUrl', 'appId', 'applicationServerKey']) {
    const partial = { ...PUSH };
    delete partial[missing];
    assert.equal(sanitizeConfig({ push: partial }).push, null, `${missing} 누락`);
  }

  assert.equal(sanitizeConfig({ push: null }).push, null);
  assert.equal(sanitizeConfig({ push: 'https://push.example.com' }).push, null);
  assert.equal(sanitizeConfig({}).push, null);
});

test('sanitizeConfig: 푸시 gatewayUrl은 https만 받는다', () => {
  assert.equal(sanitizeConfig({ push: { ...PUSH, gatewayUrl: 'http://push.example.com/_matrix/push/v1/notify' } }).push, null);
  assert.equal(sanitizeConfig({ push: { ...PUSH, gatewayUrl: 'javascript:alert(1)' } }).push, null);
  assert.equal(sanitizeConfig({ push: { ...PUSH, gatewayUrl: 'push.example.com' } }).push, null);
  assert.equal(sanitizeConfig({ push: { ...PUSH, gatewayUrl: 42 } }).push, null);
});

test('sanitizeConfig: app_id는 글로브를 허용하지 않는다 (sygnal이 pushkey를 reject한다)', () => {
  // sygnal의 find_pushkins가 2개 이상 매칭하면 pushkey를 rejected로 돌려주고
  // 홈서버가 pusher를 지운다 — 알림이 통째로 멈춘다.
  for (const bad of ['com.example.*', 'com.example.familychat.?eb', 'com.example.[a-z]', '', 'a'.repeat(65), 'com example', 42, null]) {
    assert.equal(sanitizeConfig({ push: { ...PUSH, appId: bad } }).push, null, `appId=${String(bad)}`);
  }
  assert.equal(sanitizeConfig({ push: { ...PUSH, appId: 'a'.repeat(64) } }).push?.appId, 'a'.repeat(64));
});

test('sanitizeConfig: applicationServerKey는 디코딩해서 65바이트·0x04까지 확인한다', () => {
  assert.equal(sanitizeConfig({ push: { ...PUSH, applicationServerKey: SAMPLE_KEY.slice(0, 86) } }).push, null, '잘린 키');
  assert.equal(sanitizeConfig({ push: { ...PUSH, applicationServerKey: SAMPLE_KEY + 'A' } }).push, null, '긴 키');
  assert.equal(sanitizeConfig({ push: { ...PUSH, applicationServerKey: '+/' + SAMPLE_KEY.slice(2) } }).push, null, 'base64url이 아닌 문자');
  assert.equal(sanitizeConfig({ push: { ...PUSH, applicationServerKey: 42 } }).push, null);

  // 접두 바이트는 바이트를 직접 고쳐서 만든다. 앞 글자만 바꾸면 base64 정렬 때문에
  // 값이 그대로일 수 있어(예: 'B'는 이미 0x04를 인코딩한다) 시험이 동어반복이 된다.
  const compressed = Buffer.from(SAMPLE_KEY, 'base64url');
  compressed[0] = 0x02; // 압축 P-256 점 — 길이는 그럴듯하지만 Push API가 받지 않는다
  const compressedKey = compressed.toString('base64url');
  assert.notEqual(compressedKey, SAMPLE_KEY, '표본과 실제로 달라야 의미가 있다');
  assert.equal(compressedKey.length, 87);
  assert.equal(sanitizeConfig({ push: { ...PUSH, applicationServerKey: compressedKey } }).push, null, '0x04로 시작하지 않는 점');
});

test('sanitizeConfig: homeserverUrl은 https만, 끝 슬래시는 뗀다', () => {
  assert.equal(sanitizeConfig({ homeserverUrl: 'https://matrix.example.com/' }).homeserverUrl, 'https://matrix.example.com');
  assert.equal(sanitizeConfig({ homeserverUrl: 'https://matrix.example.com' }).homeserverUrl, 'https://matrix.example.com');
  assert.equal(sanitizeConfig({ homeserverUrl: 'http://matrix.example.com' }).homeserverUrl, null);
  assert.equal(sanitizeConfig({ homeserverUrl: 'matrix.example.com' }).homeserverUrl, null);
  assert.equal(sanitizeConfig({ homeserverUrl: 42 }).homeserverUrl, null);
});
