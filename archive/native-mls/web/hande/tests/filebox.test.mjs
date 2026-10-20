// filebox.js: config.json filebox 파싱(https 만)·제목 기본값·새로고침 URL (pure node:test).
import {test} from 'node:test';
import assert from 'node:assert/strict';
import {httpsUrl, fileboxConfig, fileboxRefreshUrl} from '../filebox.js';

test('httpsUrl: https 만, 그 밖은 null', () => {
  assert.equal(httpsUrl('https://files.example/'), 'https://files.example/');
  assert.equal(httpsUrl('http://files.example/'), null);
  assert.equal(httpsUrl('javascript:alert(1)'), null);
  assert.equal(httpsUrl('not a url'), null);
  assert.equal(httpsUrl(null), null);
});

test('fileboxConfig: url 필수(https), title 없으면 기본값', () => {
  const d = {defaultTitle: '파일보관함'};
  assert.deepEqual(fileboxConfig({url: 'https://files.example/', title: '보관함'}, d), {url: 'https://files.example/', title: '보관함'});
  assert.deepEqual(fileboxConfig({url: 'https://files.example/'}, d), {url: 'https://files.example/', title: '파일보관함'});
  assert.deepEqual(fileboxConfig({url: 'https://files.example/', title: '  '}, d), {url: 'https://files.example/', title: '파일보관함'});
  assert.equal(fileboxConfig({url: 'http://files.example/'}, d), null);
  assert.equal(fileboxConfig({title: 'x'}, d), null);
  assert.equal(fileboxConfig(null, d), null);
  assert.equal(fileboxConfig('https://files.example/', d), null);
});

test('fileboxRefreshUrl: 0 이면 원래 주소, n 이면 _files_refresh=n', () => {
  assert.equal(fileboxRefreshUrl('https://files.example/', 0), 'https://files.example/');
  assert.equal(fileboxRefreshUrl('https://files.example/', 3), 'https://files.example/?_files_refresh=3');
  assert.equal(fileboxRefreshUrl('https://files.example/?a=1', 2), 'https://files.example/?a=1&_files_refresh=2');
});
