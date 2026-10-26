// The retro-z80 extension: debug programs on the real board through the
// bridge (tools/rz80_bridge.py), with the z80-asm language, the program and
// watchpoint panels, the console and a build task. docs/spec/debug.md,
// section 3; design plan, branch 20. Shaped like the zx emulator's
// extension, much of whose code it carries (PROVENANCE.md).

'use strict';

const { activateAsmLanguage } = require('./asm_language');
const { activateBridge, deactivateBridge } = require('./bridge_view');
const { activateConsole } = require('./console_terminal');
const { activateWatchpoints } = require('./watchpoint_view');
const { activateProgramView } = require('./program_view');
const { activateTasks } = require('./task_provider');

const vscode = require('vscode');

// The zx emulator's extension contributes the same z80-asm language: with it
// installed, its index answers Go to Definition and hovers, and this one would
// only answer them twice (docs/spec/debug.md, open point DB14).
const ZX_EXTENSION = 'jonsole.zxspectrum-debug';

function activate(context) {
  activateBridge(context);
  activateConsole(context);
  activateWatchpoints(context);
  activateProgramView(context);
  activateTasks(context);
  if (!vscode.extensions.getExtension(ZX_EXTENSION)) {
    activateAsmLanguage(context);
  }
}

function deactivate() {
  deactivateBridge();
}

module.exports = { activate, deactivate };
