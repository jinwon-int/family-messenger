// #870(AGENT-CHOICES §7): 방 행 미리보기 자리의 우선순위 — 답변 필요 > status-v1 Working/대기 중 줄 > 원래 미리보기.
// 오너 2026-11-24: 목록에서 Waiting 줄이 [답변 필요] 질문을 가려 들어가 봐야 알았다.
import test from 'node:test';
import assert from 'node:assert/strict';
import { roomPreviewSlot } from '../ui.js';
import { strings } from '../strings.js';

const answer = { mode: 'one', count: 3, number: 1, label: '(권장) A안으로 진행' };

test('답할 카드가 있으면 Waiting 줄보다 질문 요약이 앞선다', () => {
  const slot = roomPreviewSlot({ state: 'joined', preview: '방통: 결과를 정리했습니다', working: '⏳ 대기 중 · PR #870 CI', answer });
  assert.equal(slot.kind, 'answer');
  assert.equal(slot.text, '하나만 선택 · 3개 · 1. (권장) A안으로 진행');
});

test('여러 개 선택 모드 문구', () => {
  assert.equal(strings.rooms.answerPreview({ mode: 'many', count: 2, number: 2, label: 'B' }), '여러 개 선택 · 2개 · 2. B');
});

test('카드가 없으면 status 줄(Working/대기 중)이 그대로 미리보기를 덮는다(#560)', () => {
  assert.deepEqual(roomPreviewSlot({ state: 'joined', preview: 'x', working: '⏳ Working — 10s', answer: null }), { kind: 'working', text: '⏳ Working — 10s' });
});

test('둘 다 없으면 원래 미리보기', () => {
  assert.deepEqual(roomPreviewSlot({ state: 'joined', preview: '안녕하세요', working: null, answer: null }), { kind: 'preview', text: '안녕하세요' });
  assert.deepEqual(roomPreviewSlot({ state: 'joined', preview: '', working: null }), { kind: 'preview', text: strings.rooms.noMessages });
});

test('꺼진 자리(정지·닫힘)는 답변 필요·status 를 보이지 않는다', () => {
  for (const state of ['halted', 'closed']) {
    const slot = roomPreviewSlot({ state, preview: '', working: '⏳ Working', answer });
    assert.equal(slot.kind, 'preview');
    assert.equal(slot.text, strings.rooms.closedPreview);
  }
});

test('roomListItem 은 roomPreviewSlot 으로 미리보기 자리를 정하고 「답변 필요」 알약을 붙인다', async () => {
  const { readFileSync } = await import('node:fs');
  const source = readFileSync(new URL('../ui.js', import.meta.url), 'utf8');
  const start = source.indexOf('function roomListItem(');
  const body = source.slice(start, source.indexOf('\n}\n', start));
  assert.match(body, /const slot = roomPreviewSlot\(room\);/);
  assert.match(body, /'data-testid': 'room-answer'/);
  assert.match(body, /slot\.kind, slot\.text/, '행 signature 에 미리보기 종류·글이 들어가 바뀌면 다시 그린다');
});
