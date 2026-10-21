// 붙여넣기·끌어다 놓기 첨부 파일 고르기 테스트(#480 B). node --test archive/native-mls/web/hande/tests/composer-files.test.mjs
import test from 'node:test';
import assert from 'node:assert/strict';
import { pickTransferFile, transferHasFiles } from '../composer-files.js';

const file = (name, type) => ({ name, type });
const item = (f) => ({ kind: 'file', type: f.type, getAsFile: () => f });

test('pickTransferFile: items 의 첫 파일, 이미지가 있으면 이미지 우선', () => {
  const pdf = file('a.pdf', 'application/pdf');
  const png = file('shot.png', 'image/png');
  assert.equal(pickTransferFile({ items: [item(pdf), item(png)] }), png);
  assert.equal(pickTransferFile({ items: [item(pdf)] }), pdf);
});

test('pickTransferFile: items 에 파일이 없으면 files 를 보고, 둘 다 없으면 null(글자 붙여넣기는 브라우저 기본)', () => {
  const doc = file('n.txt', 'text/plain');
  assert.equal(pickTransferFile({ items: [{ kind: 'string', type: 'text/plain' }], files: [doc] }), doc);
  assert.equal(pickTransferFile({ items: [{ kind: 'string', type: 'text/plain' }], files: [] }), null);
  assert.equal(pickTransferFile({ items: [{ kind: 'file', getAsFile: () => null }] }), null);
  assert.equal(pickTransferFile(null), null);
  assert.equal(pickTransferFile({}), null);
});

test('transferHasFiles: types 에 Files 가 있을 때만', () => {
  assert.equal(transferHasFiles({ types: ['Files'] }), true);
  assert.equal(transferHasFiles({ types: ['text/plain'] }), false);
  assert.equal(transferHasFiles({}), false);
  assert.equal(transferHasFiles(null), false);
});
