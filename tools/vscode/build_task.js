// The retro-z80-build task type: assemble with sjasmplus (with --sld for the
// debugger), then wrap the binary in an image header with rlink.py image
// (docs/spec/debug.md, section 3.8). No vscode API (node tests/build_task_test.js).

'use strict';

const path = require('path');

// A task definition -> the paths it builds, or an error message.
// { source: "game.asm", output: "build/game", load: "8000", entry: "8000",
//   includes: ["firmware/include"] }
function buildPlan(def, cwd) {
  if (!def || !def.source) {
    return { error: 'a retro-z80-build task needs "source": the .asm to assemble' };
  }
  const load = String(def.load || '').trim();
  if (!/^(\$|0x|&)?[0-9a-fA-F]{1,4}$/.test(load)) {
    return { error: 'a retro-z80-build task needs "load": where the program goes, in hex (8000)' };
  }
  const entry = String(def.entry || load).trim();
  if (!/^(\$|0x|&)?[0-9a-fA-F]{1,4}$/.test(entry)) {
    return { error: '"entry" must be an address in hex' };
  }
  const bare = (v) => v.replace(/^(\$|0x|&)/, '');
  const source = path.resolve(cwd, def.source);
  const stem = def.output ? path.resolve(cwd, def.output)
    : path.join(path.dirname(source), 'build', path.basename(source).replace(/\.[^.]*$/, ''));
  return {
    source,
    bin: stem + '.bin',
    sld: stem + '.sld',
    rimg: stem + '.rimg',
    lst: stem + '.lst',
    load: bare(load),
    entry: bare(entry),
    includes: (def.includes || []).map((dir) => path.resolve(cwd, dir))
  };
}

// The two command lines.
function sjasmplusArgs(plan) {
  const args = ['--nologo', '--fullpath', `--raw=${plan.bin}`, `--sld=${plan.sld}`, `--lst=${plan.lst}`];
  for (const dir of plan.includes) {
    args.push('-I', dir);
  }
  args.push(plan.source);
  return args;
}

function rlinkArgs(plan, rlink) {
  return [rlink, 'image', plan.bin, '-o', plan.rimg, '--machine', 'z80', '--load', plan.load,
    '--entry', plan.entry];
}

module.exports = { buildPlan, sjasmplusArgs, rlinkArgs };
