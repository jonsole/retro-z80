// The smallest test harness: test(name, body), then done().

'use strict';

let failures = 0;
function test(name, body) {
  try {
    body();
    console.log('ok   ' + name);
  } catch (err) {
    failures++;
    console.log('FAIL ' + name);
    console.log(err.stack);
  }
}

function done() {
  if (failures > 0) {
    console.log(`\n${failures} failed`);
    process.exit(1);
  }
  console.log('\nall passed');
}

module.exports = { test, done };
