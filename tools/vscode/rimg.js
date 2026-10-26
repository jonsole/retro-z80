// Image files: the 32-byte RIMG header of the shared spec "Monitor and
// upload protocol" (docs/spec/monitor.md, section 5), read for the program
// panel. No vscode API (node tests/rimg_test.js). The same checks as
// rlink.py's `show`.

'use strict';

const TARGETS = { 0: 'program', 1: 'boot ROM image', 2: 'resident image' };

let table = null;
function crc32(bytes) {
  if (!table) {
    table = new Uint32Array(256);
    for (let n = 0; n < 256; n++) {
      let c = n;
      for (let k = 0; k < 8; k++) {
        c = c & 1 ? 0xEDB88320 ^ (c >>> 1) : c >>> 1;
      }
      table[n] = c >>> 0;
    }
  }
  let crc = 0xFFFFFFFF;
  for (let i = 0; i < bytes.length; i++) {
    crc = table[(crc ^ bytes[i]) & 0xFF] ^ (crc >>> 8);
  }
  return (crc ^ 0xFFFFFFFF) >>> 0;
}

function hex(v, digits) {
  return v.toString(16).toUpperCase().padStart(digits, '0');
}

// A file's bytes (a Buffer or Uint8Array) -> its header and what is wrong
// with it; null when it has no RIMG header at all.
function parseImage(bytes) {
  if (bytes.length < 32 || String.fromCharCode(bytes[0], bytes[1], bytes[2], bytes[3]) !== 'RIMG') {
    return null;
  }
  const u32 = (o) => ((bytes[o] << 24) | (bytes[o + 1] << 16) | (bytes[o + 2] << 8) | bytes[o + 3]) >>> 0;
  const h = {
    machine: String.fromCharCode(bytes[4], bytes[5], bytes[6], bytes[7]).trim(),
    version: bytes[8],
    target: bytes[9],
    flags: (bytes[10] << 8) | bytes[11],
    load: u32(12),
    entry: u32(16),
    size: u32(20),
    icrc: u32(24),
    hcrc: u32(28)
  };
  h.phys = (h.flags & 1) !== 0;
  h.targetName = TARGETS[h.target] || `target ${h.target}`;
  const problems = [];
  if (h.version !== 1) {
    problems.push(`version ${h.version}`);
  }
  h.hcrcOk = crc32(bytes.subarray(0, 28)) === h.hcrc;
  if (!h.hcrcOk) {
    problems.push(`HCRC ${hex(h.hcrc, 8)} bad`);
  }
  const data = bytes.subarray(32, 32 + h.size);
  h.icrcOk = data.length === h.size && crc32(data) === h.icrc;
  if (data.length !== h.size) {
    problems.push(`the file has ${data.length} bytes of image, the header says ${h.size}`);
  } else if (!h.icrcOk) {
    problems.push(`ICRC ${hex(h.icrc, 8)} bad`);
  }
  h.problems = problems;
  return h;
}

// rlink.py show's line: "Z80, program, load 8000, entry 8000, 14 bytes".
function describeImage(h) {
  const where = h.target === 1 ? `offset ${hex(h.load, 1)}`
    : `load ${h.phys ? 'P' : ''}${hex(h.load, 1)}, entry ${hex(h.entry, 1)}`;
  return `${h.machine}, ${h.targetName}, ${where}, ${h.size} bytes`;
}

module.exports = { crc32, parseImage, describeImage, hex };
