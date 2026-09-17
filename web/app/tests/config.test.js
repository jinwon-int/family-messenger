import test from 'node:test';
import assert from 'node:assert/strict';
import { DEFAULT_CONFIG, loadConfig, sanitizeConfig } from '../src/config.js';

test('sanitizeConfig: https 파일보관함 URL만 받고 제목은 선택', () => {
  assert.deepEqual(sanitizeConfig({ filebox: { url: 'https://files.example.com', title: '파일보관함' } }), { filebox: { url: 'https://files.example.com/', title: '파일보관함' } });
  assert.deepEqual(sanitizeConfig({ filebox: { url: 'https://files.example.com/' } }), { filebox: { url: 'https://files.example.com/', title: null } });
  assert.deepEqual(sanitizeConfig({ filebox: { url: 'http://files.example.com/' } }), { filebox: null });
  assert.deepEqual(sanitizeConfig({ filebox: { url: 'javascript:alert(1)' } }), { filebox: null });
  assert.deepEqual(sanitizeConfig({ filebox: { url: 'not a url' } }), { filebox: null });
  assert.deepEqual(sanitizeConfig({}), { filebox: null });
  assert.deepEqual(sanitizeConfig(null), { filebox: null });
});

test('loadConfig: config.json이 없거나 깨지면 기본값, 있으면 정제해서 돌려준다', async () => {
  assert.deepEqual(await loadConfig(async () => ({ ok: false })), DEFAULT_CONFIG);
  assert.deepEqual(await loadConfig(async () => { throw new Error('offline'); }), DEFAULT_CONFIG);
  assert.deepEqual(await loadConfig(async () => ({ ok: true, json: async () => { throw new Error('bad json'); } })), DEFAULT_CONFIG);
  const calls = [];
  const loaded = await loadConfig(async (url, opts) => { calls.push([url, opts]); return { ok: true, json: async () => ({ filebox: { url: 'https://f.example.com/' } }) }; });
  assert.deepEqual(loaded, { filebox: { url: 'https://f.example.com/', title: null } });
  assert.deepEqual(calls, [['./config.json', { cache: 'no-store' }]]);
});
