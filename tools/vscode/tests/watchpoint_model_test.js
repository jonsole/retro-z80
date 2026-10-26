// node tools/vscode/tests/watchpoint_model_test.js
'use strict';
const assert = require('assert');
const w = require('../watchpoint_model');
const { test, done } = require('./harness');

test('a watchpoint is named by its symbol, a range by its length, a port as a port', () => {
  assert.strictEqual(w.watchpointName({ address: 0x9000, length: 1, symbol: 'result' }), 'result ($9000)');
  assert.strictEqual(w.watchpointName({ address: 0x9000, length: 16 }), '$9000, 16 bytes');
  assert.strictEqual(w.watchpointName({ address: 0xFE, length: 1, io: true }), 'port $00FE');
});

test('the detail says what it stops on, and who else set it', () => {
  assert.strictEqual(w.watchpointDetail({ access: 'write', owners: ['vscode'] }), 'writes');
  assert.strictEqual(w.watchpointDetail({ access: 'readwrite', owners: ['mcp'] }), 'reads and writes · set by mcp');
});

test('what is typed reads as an address and a length', () => {
  assert.deepStrictEqual(w.parseWatchRequest('player 8'), { address: 'player', length: 8 });
  assert.deepStrictEqual(w.parseWatchRequest('$5C3A,2'), { address: '$5C3A', length: 2 });
  assert.deepStrictEqual(w.parseWatchRequest('room + 4'), { address: 'room + 4', length: 1 });
  assert.strictEqual(w.parseWatchRequest('  '), undefined);
});

test('a length must be a power of two', () => {
  assert.ok(w.lengthAllowed(1) && w.lengthAllowed(16));
  assert.ok(!w.lengthAllowed(3) && !w.lengthAllowed(0));
});

done();
