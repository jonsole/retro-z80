// Watchpoints as the editor lists them. No vscode import, so it is tested
// from plain Node (tests/watchpoint_model_test.js). Adapted from the zx
// extension's: the debug unit's watchpoints have no hit counts, no on/off and
// no value test, but a port watch, a range under a mask, and who set them.

'use strict';

function hex4(value) {
  return '$' + value.toString(16).toUpperCase().padStart(4, '0');
}

/// "result ($9000)", "port $00FE", or just the address when nothing names it.
function watchpointName(w) {
  const address = hex4(w.address);
  let name = w.io ? `port ${address}` : (w.symbol ? `${w.symbol} (${address})` : address);
  if (w.length > 1) {
    name += `, ${w.length} ${w.io ? 'ports' : 'bytes'}`;
  }
  return name;
}

/// "writes", "reads", "reads and writes", and who set it.
function watchpointDetail(w) {
  const what = { read: 'reads', write: 'writes', readwrite: 'reads and writes' }[w.access] || w.access;
  const owners = (w.owners || []).filter((o) => o !== 'vscode');
  return owners.length ? `${what} · set by ${owners.join(', ')}` : what;
}

/// Reads "player", "player 8", "$5C3A,2" or "room +1 4" into the address
/// text and a length. The address is left as typed: the bridge resolves
/// symbols and expressions.
function parseWatchRequest(text) {
  const trimmed = (text || '').trim();
  if (trimmed === '') {
    return undefined;
  }
  const comma = trimmed.match(/^(.*?)\s*,\s*(\d+)$/);
  if (comma) {
    return { address: comma[1].trim(), length: Number(comma[2]) };
  }
  const spaced = trimmed.match(/^(.*[^\s+\-*/])\s+(\d+)$/);
  if (spaced) {
    return { address: spaced[1].trim(), length: Number(spaced[2]) };
  }
  return { address: trimmed, length: 1 };
}

/// The hardware compares under a mask: a length must be a power of two.
function lengthAllowed(length) {
  return Number.isInteger(length) && length >= 1 && length <= 0x10000 && (length & (length - 1)) === 0;
}

module.exports = { watchpointName, watchpointDetail, parseWatchRequest, lengthAllowed, hex4 };
