import test from 'node:test';
import assert from 'node:assert/strict';
import { hashedName, isHashedAsset, rewriteIndex, rewriteServiceWorker, shortHash } from '../build-lib.mjs';

test('shortHash/hashedName: 내용이 바뀌면 이름이 바뀐다', () => {
  assert.equal(shortHash('a').length, 8);
  assert.notEqual(shortHash('a'), shortHash('b'));
  assert.match(hashedName('styles.css', 'x'), /^styles-[a-f0-9]{8}\.css$/);
  assert.match(hashedName('boot.js', 'x'), /^boot-[a-f0-9]{8}\.js$/);
  assert.notEqual(hashedName('styles.css', 'x'), hashedName('styles.css', 'y'));
});

test('rewriteIndex: 참조를 해시 이름으로 바꾸고 ?v= 꼬리는 버린다', () => {
  const html = '<link href="./styles.css" /><script src="./boot.js"></script><script type="module" src="./main.js?v=5"></script><img src="./icons/icon.svg">';
  const out = rewriteIndex(html, { './styles.css': './styles-abc.css', './boot.js': './boot-def.js', './main.js': './main-XYZ.js' });
  assert.equal(out, '<link href="./styles-abc.css" /><script src="./boot-def.js"></script><script type="module" src="./main-XYZ.js"></script><img src="./icons/icon.svg">');
});

test('rewriteServiceWorker: 자리표시자를 채우고, 없으면 실패한다', () => {
  const out = rewriteServiceWorker("// __CACHE_NAME__ __SHELL_ASSETS__\nconst CACHE = '__CACHE_NAME__';\nconst SHELL = __SHELL_ASSETS__;", { cacheName: 'familychat-1234abcd', shell: ['./', './main-X.js'] });
  assert.equal(out, "// familychat-1234abcd [\"./\",\"./main-X.js\"]\nconst CACHE = 'familychat-1234abcd';\nconst SHELL = [\"./\",\"./main-X.js\"];", '주석에 있는 토큰까지 전부 바꾼다');
  assert.throws(() => rewriteServiceWorker('const CACHE = 1;', { cacheName: 'x', shell: [] }), /placeholders/);
});

test('isHashedAsset: 해시 파일명만 영구 캐시 대상', () => {
  assert.equal(isHashedAsset('/main-AB12CD34.js'), true);
  assert.equal(isHashedAsset('/styles-1a2b3c4d.css'), true);
  assert.equal(isHashedAsset('/main.js'), false);
  assert.equal(isHashedAsset('/index.html'), false);
  assert.equal(isHashedAsset('/pkg/matrix_sdk_crypto_wasm_bg.wasm'), false);
});
