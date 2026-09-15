import test from 'node:test';
import assert from 'node:assert/strict';
import { extractMentions } from '../src/mentions.js';

const handles = [
  { userId: '@fambot:matrix.seoyoon-family.com', localpart: 'fambot' },
  { userId: '@jungin:matrix.seoyoon-family.com', localpart: 'jungin' },
  { userId: '@seoseo:matrix.seoyoon-family.com', localpart: 'seoseo' },
];

test('알려진 핸들을 m.mentions user_ids로 바꾼다', () => {
  assert.deepEqual(
    extractMentions('@fambot 안녕', handles),
    ['@fambot:matrix.seoyoon-family.com'],
  );
  assert.deepEqual(
    extractMentions('@jungin @SEOSEO 둘 다 보고', handles),
    ['@jungin:matrix.seoyoon-family.com', '@seoseo:matrix.seoyoon-family.com'],
  );
});

test('모르는 핸들·@ 없는 텍스트는 멘션을 만들지 않는다', () => {
  assert.deepEqual(extractMentions('@whoisthis 안녕', handles), []);
  assert.deepEqual(extractMentions('fambot에게 부탁 (골뱅이 없음)', handles), []);
  assert.deepEqual(extractMentions('', handles), []);
});

test('중복 멘션은 한 번만 담는다', () => {
  assert.deepEqual(
    extractMentions('@fambot 안녕 @Fambot 잘 부탁', handles),
    ['@fambot:matrix.seoyoon-family.com'],
  );
});
