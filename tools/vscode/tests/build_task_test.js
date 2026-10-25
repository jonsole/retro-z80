// node tools/vscode/tests/build_task_test.js
'use strict';
const assert = require('assert');
const path = require('path');
const t = require('../build_task');
const { test, done } = require('./harness');

test('a task builds .bin, .sld and .rimg beside a build/ folder', () => {
  const plan = t.buildPlan({ source: 'src/game.asm', load: '$8000' }, '/w');
  assert.strictEqual(plan.bin, path.resolve('/w/src/build/game.bin'));
  assert.strictEqual(plan.rimg, path.resolve('/w/src/build/game.rimg'));
  assert.strictEqual((plan.load + plan.entry), '80008000');
  const named = t.buildPlan({ source: 'game.asm', output: 'out/g', load: '9000', entry: '0x9003', includes: ['inc'] }, '/w');
  assert.strictEqual(named.sld, path.resolve('/w/out/g.sld'));
  assert.strictEqual(named.entry, '9003');
});

test('the two command lines', () => {
  const plan = t.buildPlan({ source: 'game.asm', output: 'b/g', load: '8000', includes: ['inc'] }, '/w');
  const sj = t.sjasmplusArgs(plan);
  assert.ok(sj.includes(`--raw=${path.resolve('/w/b/g.bin')}`) && sj.includes(`--sld=${path.resolve('/w/b/g.sld')}`));
  assert.deepStrictEqual(sj.slice(-3), ['-I', path.resolve('/w/inc'), path.resolve('/w/game.asm')]);
  assert.deepStrictEqual(t.rlinkArgs(plan, 'rlink.py').slice(0, 2), ['rlink.py', 'image']);
  assert.deepStrictEqual(t.rlinkArgs(plan, 'r').slice(-6), ['--machine', 'z80', '--load', '8000', '--entry', '8000']);
});

test('what a task lacks is said', () => {
  assert.ok(t.buildPlan({}, '/w').error.includes('source'));
  assert.ok(t.buildPlan({ source: 'a.asm' }, '/w').error.includes('load'));
  assert.ok(t.buildPlan({ source: 'a.asm', load: '8000', entry: 'zz' }, '/w').error.includes('entry'));
});

done();
