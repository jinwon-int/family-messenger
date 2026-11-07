// alert-refs-v1 테스트: node --test archive/native-mls/web/hande/tests/alert-refs.test.mjs — 세 앱 공유 벡터.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { parseAlertRefs, isFleetDevice } from '../alert-refs.js';

const vectors = JSON.parse(readFileSync(new URL('../../../tests/fixtures/alert-refs-vectors.json', import.meta.url), 'utf8'));

test('공유 벡터가 실렸다', () => assert.ok(vectors.parse.length >= 10));

for (const v of vectors.parse) {
  test(`parse: ${v.name}`, () => {
    const got = parseAlertRefs(v.text);
    assert.equal(got.self, v.self);
    assert.deepEqual(got.refs.map((r) => r.id), v.refs);
    for (const r of got.refs) assert.equal(v.text.slice(r.start, r.end), `#${r.id}`);
  });
}

test('isFleetDevice: actor fleet 만', () => {
  assert.equal(isFleetDevice('fleet-bot'), true);
  assert.equal(isFleetDevice('card-bot'), false);
  assert.equal(isFleetDevice('fleetx-bot'), false);
  assert.equal(isFleetDevice(null), false);
});
