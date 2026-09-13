// Recovery key (복구 키) generation and confirm-once guidance.
//
// The key never leaves this module's callers: it is generated locally,
// displayed once, and confirmed by typing it back. Nothing here touches
// the network, and tests pin that contract.

export const RECOVERY_KEY_BYTES = 32;

// Base58 (Bitcoin alphabet) — the Matrix security-key convention. It is
// case-sensitive and excludes 0/O/I/l to survive handwriting.
export const BASE58_ALPHABET = '123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz';

/** @param {number} length @returns {Uint8Array} cryptographically random bytes */
export function randomBytes(length) {
  const bytes = new Uint8Array(length);
  globalThis.crypto.getRandomValues(bytes);
  return bytes;
}

/** @param {Uint8Array} bytes @returns {string} base58 encoding */
export function base58Encode(bytes) {
  if (!(bytes instanceof Uint8Array) || bytes.length === 0) {
    throw new TypeError('base58Encode: non-empty Uint8Array required');
  }
  let zeros = 0;
  while (zeros < bytes.length && bytes[zeros] === 0) zeros += 1;
  // Big-number style conversion: 256-based digits into base-58,
  // least significant digit first.
  const digits = [];
  for (let i = zeros; i < bytes.length; i += 1) {
    let carry = bytes[i];
    for (let j = 0; j < digits.length; j += 1) {
      carry += digits[j] << 8;
      digits[j] = carry % 58;
      carry = Math.floor(carry / 58);
    }
    while (carry > 0) {
      digits.push(carry % 58);
      carry = Math.floor(carry / 58);
    }
  }
  // Leading zero bytes become leading '1' digits.
  const body = digits.reverse().map((d) => BASE58_ALPHABET[d]).join('');
  return '1'.repeat(zeros) + body;
}

/** Group a base58 key into 4-character blocks joined by spaces. */
export function formatRecoveryKey(key, groupSize = 4) {
  const clean = String(key).replace(/\s+/g, '');
  const groups = [];
  for (let i = 0; i < clean.length; i += groupSize) groups.push(clean.slice(i, i + groupSize));
  return groups.join(' ');
}

/**
 * Generate a fresh recovery key.
 * @param {(len: number) => Uint8Array} [rng] injectable randomness (tests)
 * @returns {{bytes: Uint8Array, key: string, formatted: string}}
 */
export function generateRecoveryKey(rng = randomBytes) {
  const bytes = rng(RECOVERY_KEY_BYTES);
  if (!(bytes instanceof Uint8Array) || bytes.length !== RECOVERY_KEY_BYTES) {
    throw new TypeError('generateRecoveryKey: rng must return a Uint8Array of 32 bytes');
  }
  const key = base58Encode(bytes);
  return { bytes, key, formatted: formatRecoveryKey(key) };
}

/** Normalize pasted or hand-typed keys: drop whitespace and dashes only.
 * Case is significant (base58). */
export function normalizeRecoveryKeyInput(text) {
  return String(text ?? '').replace(/[\s-]+/g, '');
}

/**
 * Show-once flow: generate → display → type-back confirmation.
 * @param {(len: number) => Uint8Array} [rng]
 */
export function createRecoveryFlow(rng = randomBytes) {
  const { key, formatted } = generateRecoveryKey(rng);
  return {
    key,
    formatted,
    /** @param {string} input typed-back key @returns {boolean} */
    confirm(input) {
      return normalizeRecoveryKeyInput(input) === key;
    },
  };
}
