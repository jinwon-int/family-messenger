// 초안 영속화 테스트(#480 B). node --test archive/native-mls/web/hande/tests/drafts.test.mjs
import test from 'node:test';
import assert from 'node:assert/strict';
import { readDraft, writeDraft, draftKeys, draftKeyFor, DRAFT_LIMIT } from '../drafts.js';

function fakeStorage() {
  const store = new Map();
  const storage = {
    getItem: (k) => (store.has(k) ? store.get(k) : null),
    setItem: (k, v) => store.set(k, String(v)),
    removeItem: (k) => store.delete(k),
  };
  // Object.keys(localStorage) 호환
  return new Proxy(storage, { ownKeys: () => [...store.keys()], getOwnPropertyDescriptor: (_, k) => (store.has(k) ? { enumerable: true, configurable: true, value: store.get(k) } : undefined) });
}

test('writeDraft/readDraft: 기기·방별 키에 저장하고 빈 초안은 키를 지운다', () => {
  const storage = fakeStorage();
  assert.equal(readDraft(storage, 'owner-web-1', 'family'), '');
  assert.equal(writeDraft(storage, 'owner-web-1', 'family', '쓰던 글'), true);
  assert.equal(storage.getItem(draftKeyFor('owner-web-1', 'family')), '쓰던 글');
  assert.equal(readDraft(storage, 'owner-web-1', 'family'), '쓰던 글');
  assert.equal(readDraft(storage, 'owner-web-1', 'fam2'), '', '다른 방은 비어 있다');
  writeDraft(storage, 'owner-web-1', 'family', '');
  assert.equal(storage.getItem(draftKeyFor('owner-web-1', 'family')), null);
});

test('writeDraft: 글자 상한을 넘기면 잘라 저장하고, 문자열이 아니면 지운다', () => {
  const storage = fakeStorage();
  writeDraft(storage, 'd', 'r', 'x'.repeat(DRAFT_LIMIT + 10));
  assert.equal(readDraft(storage, 'd', 'r').length, DRAFT_LIMIT);
  writeDraft(storage, 'd', 'r', null);
  assert.equal(readDraft(storage, 'd', 'r'), '');
});

test('저장 실패(용량·사생활 모드)는 조용히 false/빈 문자열', () => {
  const throwing = { getItem: () => { throw new Error('quota'); }, setItem: () => { throw new Error('quota'); }, removeItem: () => { throw new Error('quota'); } };
  assert.equal(readDraft(throwing, 'd', 'r'), '');
  assert.equal(writeDraft(throwing, 'd', 'r', 'x'), false);
  assert.deepEqual(draftKeys(throwing, 'd'), []);
});

test('draftKeys: 이 기기 초안 키만 고른다', () => {
  const storage = fakeStorage();
  writeDraft(storage, 'd1', 'a', '1');
  writeDraft(storage, 'd1', 'b', '2');
  writeDraft(storage, 'd2', 'a', '3');
  storage.setItem('hande:rooms:d1', '[]');
  assert.deepEqual(draftKeys(storage, 'd1').sort(), [draftKeyFor('d1', 'a'), draftKeyFor('d1', 'b')]);
});
