import test from 'node:test';
import assert from 'node:assert/strict';
import {
  BASE58_ALPHABET,
  RECOVERY_KEY_BYTES,
  base58Encode,
  createRecoveryFlow,
  formatRecoveryKey,
  generateRecoveryKey,
  normalizeRecoveryKeyInput,
} from '../src/recovery.js';

const ALPHABET = '123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz';

test('base58 알파벳은 매트릭스 보안 키 규약을 따른다', () => {
  assert.equal(BASE58_ALPHABET, ALPHABET);
});

test('base58 인코딩이 참조 구현과 일치한다', () => {
  const reference = (bytes) => {
    let zeros = 0;
    while (zeros < bytes.length && bytes[zeros] === 0) zeros += 1;
    let n = 0n;
    for (const b of bytes) n = (n << 8n) | BigInt(b);
    let out = '';
    while (n > 0n) {
      out = ALPHABET[Number(n % 58n)] + out;
      n /= 58n;
    }
    return ALPHABET[0].repeat(zeros) + out;
  };
  const vectors = [
    new Uint8Array([1]),
    new Uint8Array([255]),
    new Uint8Array([0]),
    new Uint8Array([0, 0, 255]),
    new Uint8Array([0x21, 0x43, 0x65, 0x87]),
    crypto.getRandomValues(new Uint8Array(32)),
    crypto.getRandomValues(new Uint8Array(64)),
  ];
  for (const bytes of vectors) {
    assert.equal(base58Encode(bytes), reference(bytes));
  }
  assert.equal(base58Encode(new Uint8Array([0, 1])), '12');
  assert.equal(base58Encode(new Uint8Array([0, 0, 255])), '115Q');
  assert.throws(() => base58Encode(new Uint8Array(0)));
});

test('복구 키는 32바이트에서 만들고 표시 규격을 갖는다', () => {
  const counter = makeCounterRng();
  const { bytes, key, formatted } = generateRecoveryKey(counter);
  assert.equal(bytes.length, RECOVERY_KEY_BYTES);
  assert.equal(key.length, 44); // 256 bit ≈ 44 base58 chars
  for (const ch of key.replace(/1/g, '')) {
    assert.ok(ALPHABET.includes(ch), `unexpected char ${ch}`);
  }
  assert.ok(!/[0OIl]/.test(key));
  assert.equal(formatted, formatRecoveryKey(key));
  assert.equal(formatted.split(' ').length, 11); // groups of 4
  assert.equal(counter.calls, 1);
});

test('입력 정규화는 공백·하이픈만 지운다 (대소문자 유지)', () => {
  assert.equal(normalizeRecoveryKeyInput(' 12ab CD-ef\n'), '12abCDef');
  assert.equal(normalizeRecoveryKeyInput('AbC'), 'AbC');
  assert.equal(normalizeRecoveryKeyInput(null), '');
});

test('복구 키 확인 흐름: 한 번 표시, 다시 입력으로 확인', () => {
  const flow = createRecoveryFlow(makeCounterRng());
  assert.ok(flow.key.length === 44);
  assert.equal(flow.confirm('틀린 입력'), false);
  assert.equal(flow.confirm(flow.key), true);
  assert.equal(flow.confirm(flow.formatted), true); // 공백 무시
});

test('동일 시드로는 같은 키가 나온다 (결정적 rng 주입)', () => {
  const a = generateRecoveryKey(makeCounterRng());
  const b = generateRecoveryKey(makeCounterRng());
  assert.equal(a.key, b.key);
});

function makeCounterRng() {
  let counter = 0;
  const rng = (length) => {
    rng.calls += 1;
    const bytes = new Uint8Array(length);
    for (let i = 0; i < length; i += 1) {
      counter = (counter * 1103515245 + 12345) >>> 0;
      bytes[i] = counter & 0xff;
    }
    return bytes;
  };
  rng.calls = 0;
  return rng;
}
