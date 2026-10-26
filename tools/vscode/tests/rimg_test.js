// node tools/vscode/tests/rimg_test.js
'use strict';
const assert = require('assert');
const { crc32, parseImage, describeImage } = require('../rimg');
const { test, done } = require('./harness');

function image(data, { load = 0x8000, entry = load, target = 0, flags = 0 } = {}) {
  const h = Buffer.alloc(32);
  h.write('RIMG', 0, 'ascii');
  h.write('Z80 ', 4, 'ascii');
  h[8] = 1;
  h[9] = target;
  h.writeUInt16BE(flags, 10);
  h.writeUInt32BE(load, 12);
  h.writeUInt32BE(entry, 16);
  h.writeUInt32BE(data.length, 20);
  h.writeUInt32BE(crc32(data), 24);
  h.writeUInt32BE(crc32(h.subarray(0, 28)), 28);
  return Buffer.concat([h, Buffer.from(data)]);
}

test('CRC-32 is zlib\'s: the check value', () => {
  assert.strictEqual(crc32(Buffer.from('123456789')), 0xCBF43926);
});

test('a header reads as rlink.py show writes it', () => {
  const h = parseImage(image([0x3E, 0x41, 0xCF, 0xC9]));
  assert.deepStrictEqual(h.problems, []);
  assert.strictEqual(describeImage(h), 'Z80, program, load 8000, entry 8000, 4 bytes');
  assert.strictEqual(describeImage(parseImage(image([1], { load: 0x12000, flags: 1, entry: 0x2000 }))),
    'Z80, program, load P12000, entry 2000, 1 bytes');
  assert.strictEqual(describeImage(parseImage(image([1, 2], { load: 0, target: 1 }))),
    'Z80, boot ROM image, offset 0, 2 bytes');
});

test('damage is reported, and a file that is not an image is null', () => {
  const bad = image([1, 2, 3]);
  bad[33] ^= 1;
  assert.deepStrictEqual(parseImage(bad).problems.map((p) => p.split(' ')[0]), ['ICRC']);
  const hdr = image([1, 2, 3]);
  hdr[13] ^= 1;
  assert.ok(parseImage(hdr).problems[0].startsWith('HCRC'));
  assert.ok(parseImage(image([1, 2, 3]).subarray(0, 34)).problems[0].includes('2 bytes of image'));
  assert.strictEqual(parseImage(Buffer.from('not an image at all, not at all')), null);
});

test('the same bytes rlink.py makes (its image of 3E 41 CF C9 at 8000)', () => {
  // HCRC and ICRC as `rlink.py show` printed them for this file.
  const h = parseImage(image([0x3E, 0x41, 0xCF, 0xC9]));
  assert.strictEqual(h.hcrc.toString(16).toUpperCase(), '2EA654CE');
  assert.strictEqual(h.icrc.toString(16).toUpperCase(), 'EE3206EC');
});

done();
