// AI 참여 동의 판정·저장(#544 E 선택지 3). node --test archive/native-mls/web/hande/tests/agent-consent.test.mjs
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { consentKeyFor, readConsent, writeConsent, agentsIn, needsConsent } from '../agent-consent.js';

function fakeStorage({ broken = false } = {}) {
  const store = new Map();
  return {
    getItem: (k) => { if (broken) throw new Error('quota'); return store.has(k) ? store.get(k) : null; },
    setItem: (k, v) => { if (broken) throw new Error('quota'); store.set(k, String(v)); },
    removeItem: (k) => store.delete(k),
    keys: () => [...store.keys()],
  };
}

test('agentsIn: 새 `<node>-<suffix>`·옛 `bot-<node>` 봇 기기만, 사람·서비스 봇은 제외, 중복 없이', () => {
  assert.deepEqual(agentsIn(['owner-web-1a2b3c', 'gongmyoung-vps2', 'jungin-iphone-1', 'bot-dungae', 'card-bot', 'gongmyoung-vps2']), ['gongmyoung-vps2', 'bot-dungae']);
  assert.deepEqual(agentsIn([]), []);
  assert.deepEqual(agentsIn(null), []);
  assert.deepEqual(agentsIn(['x'], () => true), ['x'], '판정 함수 주입');
});

test('needsConsent: 에이전트가 있고 미동의일 때만 — 명단을 모르면(빈 목록) 아직 아님', () => {
  assert.equal(needsConsent({ roster: ['owner-web-1', 'gongmyoung-vps2'], consented: false }), true);
  assert.equal(needsConsent({ roster: ['owner-web-1', 'gongmyoung-vps2'], consented: true }), false);
  assert.equal(needsConsent({ roster: ['owner-web-1', 'jungin-iphone-1'], consented: false }), false, '사람만 있는 방');
  assert.equal(needsConsent({ roster: ['owner-web-1', 'card-bot'], consented: false }), false, '서비스 봇은 에이전트가 아니다');
  assert.equal(needsConsent({ roster: [], consented: false }), false, '참여 전·명단 미수신');
});

test('readConsent/writeConsent: 기기·방별 키 `hande:agent-consent:<device>:<room>` 에 "1" — 「이 기기 지우기」의 hande:* 삭제 범위', () => {
  const storage = fakeStorage();
  assert.equal(readConsent(storage, 'mom-web-1', 'family'), false);
  assert.equal(writeConsent(storage, 'mom-web-1', 'family'), true);
  assert.equal(storage.getItem(consentKeyFor('mom-web-1', 'family')), '1');
  assert.ok(consentKeyFor('mom-web-1', 'family').startsWith('hande:'));
  assert.equal(readConsent(storage, 'mom-web-1', 'family'), true);
  assert.equal(readConsent(storage, 'mom-web-1', 'family-acc'), false, '다른 방은 따로');
  assert.equal(readConsent(storage, 'mom-web-2', 'family'), false, '다른 기기는 따로');
  for (const k of storage.keys()) if (k.startsWith('hande:')) storage.removeItem(k);
  assert.equal(readConsent(storage, 'mom-web-1', 'family'), false, '지우기 뒤 다시 동의 필요');
});

test('저장소가 막혀 있으면 read 는 미동의, write 는 false(이번 화면에서만 동의) — 던지지 않는다', () => {
  const storage = fakeStorage({ broken: true });
  assert.equal(readConsent(storage, 'd', 'r'), false);
  assert.equal(writeConsent(storage, 'd', 'r'), false);
});
