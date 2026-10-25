// The retro-z80-build task type (docs/spec/debug.md, section 3.8): sjasmplus
// with --sld, then rlink.py image, so a launch.json's preLaunchTask leaves a
// .rimg and its .sld beside each other. The command lines are build_task.js.

'use strict';

const vscode = require('vscode');
const cp = require('child_process');
const fs = require('fs');
const os = require('os');
const path = require('path');
const plan = require('./build_task');
const launch = require('./bridge_launch');
const bridge = require('./bridge_view');

function findRlink(extensionPath) {
  const folders = (vscode.workspace.workspaceFolders || []).map((f) => f.uri.fsPath);
  const candidates = folders.map((f) => path.join(f, 'tools', 'rlink.py'));
  candidates.push(path.join(extensionPath, '..', 'rlink.py'));
  return launch.findFirst(candidates, (f) => fs.existsSync(f));
}

function run(write, command, args, cwd) {
  write(`> ${command} ${args.join(' ')}\r\n`);
  return new Promise((resolve) => {
    let proc;
    try {
      proc = cp.spawn(command, args, { cwd, windowsHide: true });
    } catch (err) {
      write(`${err.message}\r\n`);
      resolve(1);
      return;
    }
    const out = (chunk) => write(chunk.toString().replace(/\r?\n/g, '\r\n'));
    proc.stdout.on('data', out);
    proc.stderr.on('data', out);
    proc.on('error', (err) => {
      write(`${err.message}\r\n`);
      resolve(1);
    });
    proc.on('close', (code) => resolve(code === null ? 1 : code));
  });
}

function buildTask(definition, scope, extensionPath) {
  const execution = new vscode.CustomExecution(async () => {
    const write = new vscode.EventEmitter();
    const close = new vscode.EventEmitter();
    return {
      onDidWrite: write.event,
      onDidClose: close.event,
      async open() {
        const folder = scope && scope.uri ? scope.uri.fsPath
          : ((vscode.workspace.workspaceFolders || [])[0] || { uri: { fsPath: process.cwd() } }).uri.fsPath;
        const p = plan.buildPlan(definition, folder);
        const say = (t) => write.fire(t);
        if (p.error) {
          say(p.error + '\r\n');
          close.fire(1);
          return;
        }
        fs.mkdirSync(path.dirname(p.bin), { recursive: true });
        const sj = await bridge.ensureSjasmplus();
        let code = await run(say, sj, plan.sjasmplusArgs(p), folder);
        if (code === 0) {
          const rlink = findRlink(extensionPath);
          if (!rlink) {
            say('Could not find tools/rlink.py.\r\n');
            code = 1;
          } else {
            const python = launch.pythonCommand(vscode.workspace.getConfiguration('retroz80.bridge').get('python'),
              folder, os.homedir(), process.platform);
            code = await run(say, python, plan.rlinkArgs(p, rlink), folder);
          }
        }
        say(code === 0 ? `\r\nBuilt ${path.relative(folder, p.rimg)} and ${path.basename(p.sld)}.\r\n`
          : `\r\nThe build failed (exit ${code}).\r\n`);
        close.fire(code);
      },
      close() {}
    };
  });
  const name = definition.label || `build ${path.basename(definition.source || 'program')}`;
  return new vscode.Task(definition, scope || vscode.TaskScope.Workspace, name, 'retro-z80', execution, ['$sjasmplus']);
}

function activateTasks(context) {
  context.subscriptions.push(vscode.tasks.registerTaskProvider('retro-z80-build', {
    provideTasks() {
      return [];
    },
    resolveTask(task) {
      return buildTask(task.definition, task.scope, context.extensionPath);
    }
  }));
}

module.exports = { activateTasks };
