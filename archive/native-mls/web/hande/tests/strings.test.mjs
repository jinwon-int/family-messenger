// 순수 도우미 테스트(node:test, DOM 없음): node --test archive/native-mls/web/hande/tests/strings.test.mjs
import { test } from 'node:test';
import assert from 'node:assert/strict';
import {
  ACTOR, ROOM, DEVICE, AGENT_ACTORS, strings, allStringsFilled,
  formatTime, formatClock, dayLabel, dayKey, groupFingerprint, displayName, isAgentDevice, actorOf, isMine,
  humanSize, previewLine, haltGuidance, roomLabel, agentNames,
} from '../strings.js';

test('ACTOR: 소문자 시작, 영문 소문자·숫자 2~16자', () => {
  for (const ok of ['mom', 'dad', 'jiyu', 'a1', 'abcdefghijklmnop']) assert.ok(ACTOR.test(ok), ok);
  for (const bad of ['', 'a', 'Mom', '1mom', 'mom-web', 'mom dad', 'abcdefghijklmnopq', 'bot_1']) assert.ok(!ACTOR.test(bad), bad);
});

test('ROOM: 소문자·숫자 시작, 하이픈 허용, 최대 48자', () => {
  for (const ok of ['family', 'f', '1room', 'a-b-c', 'a'.repeat(48)]) assert.ok(ROOM.test(ok), ok);
  for (const bad of ['', '-x', 'Family', 'a_b', 'a b', 'a'.repeat(49)]) assert.ok(!ROOM.test(bad), bad);
});

test('DEVICE: 영문·숫자·하이픈·밑줄 1~64자', () => {
  for (const ok of ['mom-web-1a2b3c', 'owner-iphone-27a879', 'bot-gongmyoung', 'A_b-1', 'x'.repeat(64)]) assert.ok(DEVICE.test(ok), ok);
  for (const bad of ['', 'mom web', 'mom.web', '한데', 'x'.repeat(65)]) assert.ok(!DEVICE.test(bad), bad);
});

test('formatTime / formatClock: 현지 시간 두 자리', () => {
  const ms = new Date(2026, 9, 19, 9, 5, 7).getTime();
  assert.equal(formatTime(ms), '09:05');
  assert.equal(formatClock(ms), '09:05:07');
  assert.equal(formatTime(new Date(2026, 9, 19, 23, 59).getTime()), '23:59');
  assert.equal(formatTime(null), '');
  assert.equal(formatTime(0), '');
  assert.equal(formatTime(NaN), '');
});

test('dayLabel / dayKey: 2026년 10월 18일 (일)', () => {
  const sunday = new Date(2026, 9, 18, 14, 0).getTime();
  assert.equal(dayLabel(sunday), '2026년 10월 18일 (일)');
  assert.equal(dayLabel(new Date(2026, 9, 19).getTime()), '2026년 10월 19일 (월)');
  assert.equal(dayLabel(new Date(2026, 0, 3).getTime()), '2026년 1월 3일 (토)');
  assert.equal(dayKey(sunday), '2026-10-18');
  assert.equal(dayKey(new Date(2026, 9, 18, 23, 59).getTime()), dayKey(sunday));
  assert.notEqual(dayKey(new Date(2026, 9, 19, 0, 0).getTime()), dayKey(sunday));
  assert.equal(dayLabel(undefined), '');
});

test('groupFingerprint: 4자리씩 띄움', () => {
  assert.equal(groupFingerprint('abcdefgh'), 'abcd efgh');
  assert.equal(groupFingerprint('abcdefghij'), 'abcd efgh ij');
  const hex = 'a'.repeat(64);
  const grouped = groupFingerprint(hex);
  assert.equal(grouped.split(' ').length, 16);
  assert.equal(grouped.replaceAll(' ', ''), hex);
  assert.equal(groupFingerprint('ab cd ef'), 'abcd ef');
  assert.equal(groupFingerprint(''), '');
  assert.equal(groupFingerprint(null), '');
});

test('actorOf / isAgentDevice', () => {
  assert.equal(actorOf('mom-web-1a2b3c'), 'mom');
  assert.equal(actorOf('dad'), 'dad');
  assert.ok(AGENT_ACTORS.has('bot'));
  assert.ok(isAgentDevice('bot-gongmyoung'));
  assert.ok(isAgentDevice('bot'));
  assert.ok(!isAgentDevice('botty-pc'));
  assert.ok(!isAgentDevice('mom-web-1a2b3c'));
});

test('displayName: 사람은 Matrix 닉네임 · 기기 종류, 봇은 🤖 Matrix 닉네임', () => {
  assert.equal(displayName('owner-iphone-27a879'), '진원 · 아이폰');
  assert.equal(displayName('owner-pc'), '진원 · PC');
  assert.equal(displayName('mom-web-1a2b3c'), 'mom · PC');
  assert.equal(displayName('jungin-ipad-0f'), '쩡이🍎 · 아이패드');
  assert.equal(displayName('dad'), 'dad');
  assert.equal(displayName('mom-tablet-1'), 'mom');
  // 옛 봇 기기 bot-<node>
  assert.equal(displayName('bot-gongmyoung'), '🤖 공명✴️');
  assert.equal(displayName('bot-gongmyoung-2'), '🤖 공명✴️');
  assert.equal(displayName('bot-luna'), '🤖 luna');
  assert.equal(displayName('bot'), '🤖 봇');
  // 새 봇 기기 <node>-<suffix>(#422) — actor 가 노드 이름
  assert.equal(displayName('dungae-bot'), '🤖 등애✳️');
  assert.equal(displayName('soonwook-bot'), '🤖 순욱✴️');
  assert.equal(displayName('gongmyoung-bot-1a2b'), '🤖 공명✴️');
  assert.equal(displayName(''), '');
  assert.equal(displayName(null), '');
});

test('AGENT_ACTORS: 옛 bot + 12노드(iOS FC_AGENT_ACTORS 와 같은 목록)', () => {
  const nodes = 'bangtong,daegyo,dungae,gongmyoung,gongyung,gwakga,jingun,nosuk,seoseo,sogyo,soonwook,yukson'.split(',');
  assert.deepEqual([...AGENT_ACTORS].sort(), ['bot', ...nodes].sort());
  for (const node of nodes) {
    assert.ok(isAgentDevice(`${node}-bot`), node);
    assert.match(agentNames[node], /^[가-힣]+(✳️|✴️)$/, node);
  }
  assert.ok(!isAgentDevice('owner-web-87576b'));
});

test('roomLabel: Matrix 방 이름과 동일, 모르는 방은 ID', () => {
  assert.equal(roomLabel('family'), '가족');
  assert.equal(roomLabel('family-acc'), '공명✴️');
  assert.equal(roomLabel('dungae'), '등애✳️');
  assert.equal(roomLabel('nosuk'), '노숙✳️');
  assert.equal(roomLabel('test-rs2'), 'test-rs2');
  assert.equal(roomLabel(''), '');
  assert.equal(roomLabel(undefined), '');
});

test('humanSize / previewLine', () => {
  assert.equal(humanSize(512), '512 B');
  assert.equal(humanSize(12_345), '12.1 KB');
  assert.equal(humanSize(5 * 1024 * 1024), '5.0 MB');
  assert.equal(humanSize(-1), '');
  assert.equal(previewLine('오너', '# 제목\n> 인용 **굵게** `코드`\n\n| 표'), '오너: 제목 인용 굵게 코드 표');
  assert.equal(previewLine('', 'hi'), 'hi');
});

test('haltGuidance: 토큰별 안내, removed 우선', () => {
  assert.match(haltGuidance('history_gap').what, /지웠습니다/);
  assert.match(haltGuidance('room_closed').what, /닫았습니다/);
  assert.match(haltGuidance('whatever', { removed: true }).what, /내보냈습니다/);
  assert.match(haltGuidance('policy_violation').what, /규칙에 어긋나/);
  assert.match(strings.halt.bannerBody('room_closed'), /멈춰 있습니다/);
});

test('strings: 모든 문구가 채워져 있고 코디네이터 키가 있다', () => {
  assert.ok(allStringsFilled());
  assert.equal(strings.appName, '한데');
  assert.equal(strings.wordmark, 'hande');
  assert.equal(strings.room.waitingOperator, strings.enroll.waiting);
  assert.equal(strings.room.notJoined, strings.chat.notJoined);
  assert.equal(typeof strings.room.haltRefused(1, 'x', 'y'), 'string');
  assert.equal(strings.app.starting, '준비 중…');
  assert.equal(typeof strings.relay.unauthorized, 'string');
});

test('isMine: 같은 사람이면 다른 기기도 내 글, actor 를 모르면 기기 일치로', () => {
  const me = {device: 'owner-web-87576b', actor: 'owner'};
  assert.equal(isMine('owner-web-87576b', me), true);
  assert.equal(isMine('owner-iphone-27a879', me), true);
  assert.equal(isMine('owner-pc', me), true);
  assert.equal(isMine('jungin-iphone-1b89e3', me), false);
  assert.equal(isMine('soonwook-bot', me), false);
  assert.equal(isMine('', me), false);
  assert.equal(isMine('owner-iphone-27a879', {device: 'owner-web-87576b', actor: null}), false);
  assert.equal(isMine('owner-web-87576b', {device: 'owner-web-87576b', actor: null}), true);
  assert.equal(isMine('owner-web-87576b', {device: '', actor: null}), false);
});
