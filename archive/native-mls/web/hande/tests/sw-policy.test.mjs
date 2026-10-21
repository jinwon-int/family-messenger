// 서비스 워커 정책 테스트(#480 D). node --test archive/native-mls/web/hande/tests/sw-policy.test.mjs
import test from 'node:test';
import assert from 'node:assert/strict';
import { shouldHandle, isApiPath, fallbackKey, SHELL_ASSETS, CACHE_NAME } from '../sw-policy.js';

const origin = 'https://hande.example';

test('shouldHandle: GET · 같은 origin · API 아님일 때만', () => {
  assert.equal(shouldHandle({ method: 'GET', url: `${origin}/app.js` }, origin), true);
  assert.equal(shouldHandle({ method: 'GET', url: `${origin}/` }, origin), true);
  assert.equal(shouldHandle({ method: 'POST', url: `${origin}/app.js` }, origin), false);
  assert.equal(shouldHandle({ method: 'GET', url: 'https://other.example/app.js' }, origin), false);
  assert.equal(shouldHandle({ method: 'GET', url: `${origin}/v2/events?after=1` }, origin), false);
  assert.equal(shouldHandle({ method: 'GET', url: `${origin}/v2` }, origin), false);
  assert.equal(shouldHandle({ method: 'GET', url: 'not a url' }, origin), false);
  assert.equal(shouldHandle(null, origin), false);
});

test('isApiPath: /v2 와 그 아래만', () => {
  assert.equal(isApiPath('/v2/me'), true);
  assert.equal(isApiPath('/v2'), true);
  assert.equal(isApiPath('/v20/x'), false);
  assert.equal(isApiPath('/app.js'), false);
  assert.equal(isApiPath(undefined), false);
});

test('fallbackKey: 탐색 요청은 index.html, 나머지는 null', () => {
  assert.equal(fallbackKey({ mode: 'navigate' }), './index.html');
  assert.equal(fallbackKey({ mode: 'cors' }), null);
  assert.equal(fallbackKey(null), null);
});

test('SHELL_ASSETS: 상대 경로만, 중복 없음, 핵심 파일 포함', () => {
  assert.ok(SHELL_ASSETS.every((a) => a.startsWith('./')));
  assert.equal(new Set(SHELL_ASSETS).size, SHELL_ASSETS.length);
  for (const must of ['./index.html', './main.js', './ui.js', './durable-worker.js', './pkg/family_mls_browser_experiment_bg.wasm']) assert.ok(SHELL_ASSETS.includes(must), must);
  assert.match(CACHE_NAME, /^hande-shell-v\d+$/);
});
