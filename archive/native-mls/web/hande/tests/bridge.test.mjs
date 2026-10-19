import {test} from 'node:test';
import assert from 'node:assert/strict';
import {KDF_METHODS} from '../worker-bridge.js';

test('every message that runs the custody KDF gets the long deadline', () => {
  for (const m of ['init', 'init_multi', 'open_room', 'reset_room']) assert.ok(KDF_METHODS.has(m), m);
  for (const m of ['operation', 'ack', 'status', 'close_room', 'history_put']) assert.ok(!KDF_METHODS.has(m), m);
});
