// 순수 도우미 테스트(node:test, DOM 없음): node --test archive/native-mls/web/hande/tests/strings.test.mjs
import { test } from 'node:test';
import assert from 'node:assert/strict';
import {
  ACTOR, ROOM, DEVICE, AGENT_ACTORS, strings, allStringsFilled, peopleNames,
  formatTime, formatClock, dayLabel, dayKey, groupFingerprint, displayName, isAgentDevice, isServiceDevice, actorOf, isMine, relativeTime,
  participantOf, isOneToOne, participantCount, groupParticipants, typingNames, typingLabel, subjectParticle,
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

test('displayName: 사람은 Matrix 닉네임 · 기기 종류, 봇은 Matrix 닉네임(🤖 접두 없음)', () => {
  assert.equal(displayName('owner-iphone-27a879'), '진원 · 아이폰');
  assert.equal(displayName('owner-pc'), '진원 · PC');
  assert.equal(displayName('mom-web-1a2b3c'), 'mom · PC');
  assert.equal(displayName('jungin-ipad-0f'), '쩡이🍎 · 아이패드');
  assert.equal(displayName('dad'), 'dad');
  assert.equal(displayName('mom-tablet-1'), 'mom');
  // 옛 봇 기기 bot-<node>
  assert.equal(displayName('bot-gongmyoung'), '공명✴️');
  assert.equal(displayName('bot-gongmyoung-2'), '공명✴️');
  assert.equal(displayName('bot-luna'), 'luna');
  assert.equal(displayName('bot'), '봇');
  // 새 봇 기기 <node>-<suffix>(#422) — actor 가 노드 이름
  assert.equal(displayName('dungae-bot'), '등애✳️');
  assert.equal(displayName('soonwook-bot'), '순욱✴️');
  assert.equal(displayName('gongmyoung-bot-1a2b'), '공명✴️');
  assert.equal(displayName(''), '');
  assert.equal(displayName(null), '');
});

test('participantOf / isOneToOne: 사람은 actor, 봇은 노드 단위로 세어 둘 이하면 1:1', () => {
  assert.equal(participantOf('owner-web-aaaaaa'), 'owner');
  assert.equal(participantOf('owner-iphone-27a879'), 'owner');
  assert.equal(participantOf('bot-gongmyoung'), 'agent:gongmyoung');
  assert.equal(participantOf('gongmyoung-bot-1a2b'), 'agent:gongmyoung');
  assert.equal(participantOf('bot-luna'), 'agent:luna');
  // 오너(PC·아이폰) ↔ 공명(옛·새 기기) = 1:1
  assert.equal(isOneToOne(['owner-web-aaaaaa', 'owner-iphone-27a879', 'bot-gongmyoung', 'gongmyoung-bot-1a2b']), true);
  assert.equal(isOneToOne(['owner-web-aaaaaa', 'jungin-iphone-0f']), true);
  assert.equal(isOneToOne(['owner-web-aaaaaa']), true);
  // 사람 셋 / 사람 둘 + 봇 / 서로 다른 옛 봇 둘 = 단체
  assert.equal(isOneToOne(['owner-web-aaaaaa', 'jungin-iphone-0f', 'mom-web-1']), false);
  assert.equal(isOneToOne(['owner-web-aaaaaa', 'jungin-iphone-0f', 'bot-gongmyoung']), false);
  assert.equal(isOneToOne(['owner-web-aaaaaa', 'bot-gongmyoung', 'bot-luna']), false);
  // roster 를 모르면 판정하지 않음(이름 유지)
  assert.equal(isOneToOne([]), false);
  assert.equal(isOneToOne(undefined), false);
});

test('participantCount / groupParticipants: 멤버는 사람 단위 — 같은 사람의 PC·폰은 한 명, 기기는 그 아래(2026-10-28)', () => {
  const roster = ['owner-web-aaaaaa', 'jungin-iphone-0f', 'owner-iphone-27a879', 'bot-gongmyoung', 'gongmyoung-bot-1a2b'];
  assert.equal(participantCount(roster), 3);
  assert.equal(participantCount([]), 0);
  assert.equal(participantCount(undefined), 0);
  assert.equal(participantCount(['owner-web-aaaaaa', null, 'owner-pc']), 1);
  assert.deepEqual(groupParticipants(roster), [
    {key: 'owner', name: peopleNames.owner, devices: ['owner-web-aaaaaa', 'owner-iphone-27a879']},
    {key: 'jungin', name: '쩡이🍎', devices: ['jungin-iphone-0f']},
    {key: 'agent:gongmyoung', name: agentNames.gongmyoung, devices: ['bot-gongmyoung', 'gongmyoung-bot-1a2b']},
  ]);
  assert.deepEqual(groupParticipants([]), []);
  // 모르는 actor 는 이름이 actor 그대로
  assert.deepEqual(groupParticipants(['mom-web-1']), [{key: 'mom', name: 'mom', devices: ['mom-web-1']}]);
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

test('chat.file: 이름이 있으면 「📎 이름 · 크기」, 없으면(file-v1) 「📎 파일 · 크기」 (#544 C)', () => {
  assert.equal(strings.chat.file('1.2 MB'), '📎 파일 · 1.2 MB');
  assert.equal(strings.chat.file('1.2 MB', null), '📎 파일 · 1.2 MB');
  assert.equal(strings.chat.file('1.2 MB', ''), '📎 파일 · 1.2 MB');
  assert.equal(strings.chat.file('12.3 KB', '가족사진.heic'), '📎 가족사진.heic · 12.3 KB');
  for (const key of ['previewFailed', 'previewRetry', 'previewRetrying']) assert.ok(strings.chat[key].length > 0, key);
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
  assert.notEqual(strings.enroll.waitingSibling, strings.enroll.waiting, '#574: 형제 승인 대기는 운영자 대기와 다른 문구');
  for (const key of ['siblingTitle', 'siblingBody', 'idTaken']) assert.ok(strings.enroll[key].length > 0, key);
  assert.equal(typeof strings.candidates.cardBody('x'), 'string');
  assert.equal(typeof strings.devices.done('x', true), 'string');
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

test('relativeTime: 방금 / N분 전 / N시간 전 / 어제 / M.D. — 패밀리챗 목록과 같은 라벨(#480 A)', () => {
  const now = new Date(2026, 9, 21, 15, 0, 0).getTime();
  assert.equal(relativeTime(now - 30_000, now), '방금');
  assert.equal(relativeTime(now - 5 * 60_000, now), '5분 전');
  assert.equal(relativeTime(now - 3 * 3_600_000, now), '3시간 전');
  assert.equal(relativeTime(new Date(2026, 9, 20, 23, 0).getTime(), now), '16시간 전', '24시간 안은 시간 단위');
  assert.equal(relativeTime(new Date(2026, 9, 20, 10, 0).getTime(), now), '어제');
  assert.equal(relativeTime(new Date(2026, 9, 18, 9, 0).getTime(), now), '10.18.');
  assert.equal(relativeTime(null, now), '');
  assert.equal(relativeTime(0, now), '');
  assert.equal(relativeTime(now + 60_000, now), '방금', '미래 시각은 방금으로');
});

test('서비스 봇(카드 알림): 이름표·방 이름, 에이전트가 아님', () => {
  assert.equal(displayName('card-bot'), '💳 카드 알림');
  assert.equal(isAgentDevice('card-bot'), false);
  assert.equal(roomLabel('family-card'), '💳 가족 카드 알림');
});

test('서비스 봇(플릿 알림): 이름표·방 이름, 에이전트가 아님 (#460)', () => {
  assert.equal(displayName('fleet-bot'), '🔔 플릿 알림');
  assert.equal(isAgentDevice('fleet-bot'), false);
  assert.equal(roomLabel('fleet-alerts'), '🔔 플릿 알림');
});

test('서비스 봇(번개장터 알림): 이름표·방 이름, 에이전트가 아님 (bunjang#11)', () => {
  assert.equal(displayName('bunjang-bot'), '⚡ 번개장터 알림');
  assert.equal(isAgentDevice('bunjang-bot'), false);
  assert.equal(roomLabel('bunjang-alerts'), '⚡ 번개장터 알림');
});

test('서비스 봇(인스타 알림): 이름표·방 이름, 에이전트가 아님, 서비스 봇 판정', () => {
  assert.equal(displayName('insta-bot'), '📷 인스타 알림');
  assert.equal(isAgentDevice('insta-bot'), false);
  assert.equal(isServiceDevice('insta-bot'), true);
  assert.equal(isServiceDevice('card-bot'), true);
  assert.equal(isServiceDevice('jungin-iphone-1a2b3c'), false);
  assert.equal(roomLabel('insta-news'), '📷 인스타 새 글');
});

test('typingNames / typingLabel: 내 기기 제외, 한 사람의 여러 기기는 하나, 1:1 은 이름 없이 (#562)', () => {
  const me = {device: 'owner-web-aaaaaa', actor: 'owner', roster: ['owner-web-aaaaaa', 'owner-iphone-27a879', 'jungin-iphone-0f', 'gongmyoung-bot-1a2b']};
  assert.deepEqual(typingNames(['owner-iphone-27a879'], me), [], '내 다른 기기는 입력중이 아님');
  assert.deepEqual(typingNames(['jungin-iphone-0f', 'jungin-web-aa', 'owner-iphone-27a879'], me), ['쩡이🍎'], '두 기기 = 한 사람, 기기 종류 없음');
  assert.deepEqual(typingNames(['bot-gongmyoung', 'gongmyoung-bot-1a2b', 'jungin-web-aa'], me), ['공명✴️', '쩡이🍎'], '옛·새 봇 기기 = 한 노드');
  assert.deepEqual(typingNames(['jungin-web-aa'], {...me, roster: ['owner-web-aaaaaa', 'jungin-web-aa']}), [], '1:1 방은 이름 생략');
  assert.deepEqual(typingNames([], me), []);
  assert.deepEqual(typingNames(undefined, me), []);
  // 디자인 1차 용어: 「입력중…」 → 「타닥타닥…」, 이름 뒤 조사는 받침으로(이모지·마커는 건너뛴다).
  assert.equal(strings.chat.typing([]), '타닥타닥…');
  assert.equal(strings.chat.typing(['쩡이🍎']), '쩡이🍎가 타닥타닥…');
  assert.equal(strings.chat.typing(['정인']), '정인이 타닥타닥…');
  assert.equal(strings.chat.typing(['공명✴️', '정인']), '공명✴️, 정인이 타닥타닥…', '조사는 마지막 이름 기준');
  assert.equal(typingLabel([], me), '', '아무도 없으면 표시 없음');
  assert.equal(typingLabel(['owner-iphone-27a879'], me), '', '내 기기만이면 표시 없음');
  assert.equal(typingLabel(['jungin-iphone-0f'], me), '쩡이🍎가 타닥타닥…');
  assert.equal(typingLabel(['jungin-iphone-0f'], {...me, roster: ['owner-web-aaaaaa', 'jungin-iphone-0f']}), '타닥타닥…', '1:1 은 문구만');
});

test('subjectParticle: 받침 있으면 이, 없으면 가, 끝의 이모지·마커는 건너뛰고, 한글이 없으면 이', () => {
  assert.equal(subjectParticle('정인'), '이');
  assert.equal(subjectParticle('쩡이🍎'), '가');
  assert.equal(subjectParticle('공명✴️'), '이');
  assert.equal(subjectParticle('서서✴️'), '가');
  assert.equal(subjectParticle('mom'), '이');
  assert.equal(subjectParticle(''), '이');
});
