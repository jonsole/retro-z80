// The extension activated against a stand-in for the vscode API, as far as
// plain Node can take it:
//
//   node tools/vscode/tests/extension_smoke_test.js
//
// - every command package.json names is registered, and nothing throws;
// - a debug session's descriptor factory starts the real bridge (on the stub
//   model, on free ports) and hands back its DAP port;
// - a DAP client on that port launches a program and stops at its entry;
// - the console terminal joins the bridge's console port;
// - the build task's plan and the program panel's page come out whole.
//
// It needs python3 and the repo's tools/ beside it; it skips if python3 is missing.

'use strict';

const assert = require('assert');
const cp = require('child_process');
const fs = require('fs');
const Module = require('module');
const net = require('net');
const os = require('os');
const path = require('path');

const EXT = path.resolve(__dirname, '..');
const TOOLS = path.resolve(EXT, '..');

// ---- a stand-in for the vscode module ------------------------------------
const registered = { commands: {}, factories: {}, providers: {}, trackers: {}, editors: {}, tasks: {}, terminals: [] };
const config = {};
class EventEmitter {
  constructor() {
    this.listeners = [];
    this.event = (fn) => {
      this.listeners.push(fn);
      return { dispose() {} };
    };
  }

  fire(value) {
    for (const fn of this.listeners) {
      fn(value);
    }
  }
}
const disposable = { dispose() {} };
const vscode = {
  EventEmitter,
  StatusBarAlignment: { Left: 1 },
  ProgressLocation: { Notification: 15 },
  TreeItemCollapsibleState: { None: 0 },
  TaskScope: { Workspace: 2 },
  ThemeIcon: class { constructor(id) { this.id = id; } },
  TreeItem: class { constructor(label) { this.label = label; } },
  MarkdownString: class { constructor(v) { this.value = v; } },
  DebugAdapterServer: class { constructor(port, host) { this.port = port; this.host = host; } },
  CustomExecution: class { constructor(cb) { this.callback = cb; } },
  Task: class { constructor(def, scope, name, source, execution) { Object.assign(this, { def, scope, name, source, execution }); } },
  Uri: { file: (p) => ({ fsPath: p }) },
  ViewColumn: { Beside: -2 },
  ConfigurationTarget: { Global: 1 },
  workspace: {
    workspaceFolders: [{ uri: { fsPath: path.resolve(TOOLS, '..') } }],
    getConfiguration: (section) => ({ get: (key, fallback) => {
      const v = config[section + '.' + key];
      return v === undefined ? fallback : v;
    } }),
    onDidChangeTextDocument: () => disposable,
    onDidOpenTextDocument: () => disposable,
    onDidCloseTextDocument: () => disposable,
    onDidSaveTextDocument: () => disposable,
    createFileSystemWatcher: () => ({ onDidCreate: () => disposable, onDidChange: () => disposable,
      onDidDelete: () => disposable, dispose() {} }),
    findFiles: async () => [],
    textDocuments: [],
    getWorkspaceFolder: () => undefined,
    onDidChangeConfiguration: () => disposable
  },
  window: {
    createOutputChannel: () => ({ append() {}, appendLine() {}, show() {}, dispose() {} }),
    createStatusBarItem: () => ({ show() {}, hide() {}, dispose() {} }),
    createTreeView: () => ({ reveal() {}, dispose() {} }),
    createTerminal: (opts) => {
      registered.terminals.push(opts);
      return { show() {} };
    },
    showSaveDialog: async () => undefined,
    registerCustomEditorProvider: (id, provider) => {
      registered.editors[id] = provider;
      return disposable;
    },
    showErrorMessage: (m) => console.log('     (error shown: ' + m + ')'),
    showWarningMessage: async () => undefined,
    showInformationMessage: async () => undefined,
    showInputBox: async () => undefined,
    showQuickPick: async () => undefined,
    withProgress: async (o, fn) => fn(),
    activeTextEditor: undefined
  },
  commands: {
    registerCommand: (id, fn) => {
      registered.commands[id] = fn;
      return disposable;
    },
    executeCommand: async () => undefined
  },
  debug: {
    registerDebugAdapterDescriptorFactory: (type, f) => {
      registered.factories[type] = f;
      return disposable;
    },
    registerDebugConfigurationProvider: (type, p) => {
      registered.providers[type] = p;
      return disposable;
    },
    registerDebugAdapterTrackerFactory: (type, f) => {
      registered.trackers[type] = f;
      return disposable;
    },
    onDidChangeActiveDebugSession: () => disposable,
    onDidTerminateDebugSession: () => disposable,
    onDidStartDebugSession: () => disposable,
    startDebugging: async () => true,
    activeDebugSession: undefined
  },
  languages: new Proxy({}, { get: () => () => disposable }),
  extensions: { getExtension: () => undefined },
  tasks: {
    registerTaskProvider: (type, p) => {
      registered.tasks[type] = p;
      return disposable;
    }
  }
};
const realLoad = Module._load;
Module._load = function (request, parent, isMain) {
  return request === 'vscode' ? vscode : realLoad.call(this, request, parent, isMain);
};

// ---- helpers --------------------------------------------------------------
function freePort() {
  return new Promise((resolve) => {
    const s = net.createServer();
    s.listen(0, '127.0.0.1', () => {
      const port = s.address().port;
      s.close(() => resolve(port));
    });
  });
}

function dapClient(port) {
  const socket = net.connect(port, '127.0.0.1');
  let buf = Buffer.alloc(0);
  let seq = 0;
  const waiting = [];
  const messages = [];
  socket.on('data', (chunk) => {
    buf = Buffer.concat([buf, chunk]);
    for (;;) {
      const end = buf.indexOf('\r\n\r\n');
      if (end < 0) {
        return;
      }
      const n = Number(/Content-Length: (\d+)/i.exec(buf.subarray(0, end).toString())[1]);
      if (buf.length < end + 4 + n) {
        return;
      }
      messages.push(JSON.parse(buf.subarray(end + 4, end + 4 + n).toString()));
      buf = buf.subarray(end + 4 + n);
      for (const w of waiting.splice(0)) {
        w();
      }
    }
  });
  const until = (pred, ms = 8000) => new Promise((resolve, reject) => {
    const deadline = Date.now() + ms;
    const check = () => {
      const i = messages.findIndex(pred);
      if (i >= 0) {
        resolve(messages.splice(i, 1)[0]);
      } else if (Date.now() > deadline) {
        reject(new Error('timed out'));
      } else {
        waiting.push(check);
        setTimeout(check, 50);
      }
    };
    check();
  });
  return {
    socket,
    async request(command, args) {
      const msg = JSON.stringify({ seq: ++seq, type: 'request', command, arguments: args || {} });
      socket.write(`Content-Length: ${Buffer.byteLength(msg)}\r\n\r\n${msg}`);
      const s = seq;
      const r = await until((m) => m.type === 'response' && m.request_seq === s);
      assert.ok(r.success, `${command}: ${r.message}`);
      return r;
    },
    event: (name) => until((m) => m.type === 'event' && m.event === name)
  };
}

// ---- the test -------------------------------------------------------------
async function main() {
  try {
    cp.execFileSync('python3', ['--version']);
  } catch (err) {
    console.log('skipped: no python3');
    return;
  }
  const ports = { dap: await freePort(), mcp: await freePort(), console: await freePort() };
  const adverts = fs.mkdtempSync(path.join(os.tmpdir(), 'rz80-adverts-'));
  process.env.RZ80_BRIDGE_ADVERT_DIR = adverts;
  Object.assign(config, {
    'retroz80.bridge.dapPort': ports.dap, 'retroz80.bridge.mcpPort': ports.mcp,
    'retroz80.bridge.consolePort': ports.console, 'retroz80.bridge.python': 'python3',
    'retroz80.bridge.args': ['--quiet'], 'retroz80.bridge.serialPort': 'model'
  });

  const ext = require('../extension');
  const context = { subscriptions: [], extensionPath: EXT, globalStorageUri: { fsPath: adverts } };
  ext.activate(context);

  const pkg = JSON.parse(fs.readFileSync(path.join(EXT, 'package.json'), 'utf8'));
  for (const c of pkg.contributes.commands) {
    assert.ok(registered.commands[c.command], `${c.command} is not registered`);
  }
  assert.ok(registered.factories['retro-z80'] && registered.providers['retro-z80'] && registered.trackers['retro-z80']);
  assert.ok(registered.editors['retroz80.program'] && registered.tasks['retro-z80-build']);
  console.log('ok   activation: every command, the debug type, the program panel and the task type');

  // the descriptor factory starts the bridge on the model
  let bridgeUp = false;
  try {
    const descriptor = await registered.factories['retro-z80'].createDebugAdapterDescriptor(
      { configuration: { type: 'retro-z80', request: 'launch', port: 'model' } });
    assert.strictEqual(descriptor.port, ports.dap);
    bridgeUp = true;
    console.log('ok   a debug session starts the bridge and gets its DAP port');

    // a second session joins it; one for another serial port is refused
    await registered.factories['retro-z80'].createDebugAdapterDescriptor({ configuration: { port: 'model' } });
    await assert.rejects(registered.factories['retro-z80'].createDebugAdapterDescriptor(
      { configuration: { port: 'COM9' } }), /has model open, not COM9/);
    console.log('ok   a second session joins it; another serial port is refused');

    // a whole launch over that port, with a program built by rlink.py
    const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'rz80-prog-'));
    const bin = path.join(tmp, 'p.bin');
    fs.writeFileSync(bin, Buffer.from([0x3E, 0x41, 0xCF, 0xC9]));
    cp.execFileSync('python3', [path.join(TOOLS, 'rlink.py'), 'image', bin, '-o', path.join(tmp, 'p.rimg'),
      '--machine', 'z80', '--load', '8000']);
    const resolved = registered.providers['retro-z80'].resolveDebugConfiguration(
      { uri: { fsPath: tmp } }, { type: 'retro-z80', request: 'launch', name: 'x', program: 'p.rimg' });
    assert.strictEqual(resolved.cwd, tmp);
    const dap = dapClient(ports.dap);
    await dap.request('initialize', { adapterID: 'retro-z80' });
    await dap.request('launch', resolved);
    await dap.event('initialized');
    await dap.request('configurationDone');
    const stopped = await dap.event('stopped');
    assert.strictEqual(stopped.body.reason, 'entry');
    const wp = await dap.request('setWatchpoint', { address: '9000', access: 'write' });
    assert.strictEqual(wp.body.watchpoints.length, 1);
    await dap.request('disconnect', { terminateDebuggee: true });
    dap.socket.destroy();
    console.log('ok   launch through the factory\'s port, the watchpoint panel\'s request, disconnect');

    // the console terminal joins the console port
    await registered.commands['retroz80.console']();
    const pty = registered.terminals[0].pty;
    let text = '';
    pty.onDidWrite((t) => {
      text += t;
    });
    pty.open();
    await new Promise((resolve) => setTimeout(resolve, 500));
    pty.handleInput('H\r');
    await new Promise((resolve) => setTimeout(resolve, 500));
    pty.close();
    assert.ok(text.includes('retro-z80 console on port') && text.includes('help'), text);
    console.log('ok   the console terminal shows the monitor and types into it');

    // the program panel's page
    const program = require('../program_view');
    const { parseImage } = require('../rimg');
    const page = program.page(path.join(tmp, 'p.rimg'), parseImage(fs.readFileSync(path.join(tmp, 'p.rimg'))), 'n');
    assert.ok(page.includes('Z80, program, load 8000, entry 8000, 4 bytes') && page.includes('id="debug"'));
    console.log('ok   the program panel shows rlink.py show\'s line and its buttons');
  } finally {
    ext.deactivate();
    if (bridgeUp) {
      await new Promise((resolve) => setTimeout(resolve, 300));
    }
    fs.rmSync(adverts, { recursive: true, force: true });
  }
  console.log('\nall passed');
}

main().catch((err) => {
  console.log('FAIL ' + (err.stack || err));
  try {
    require('../extension').deactivate();
  } catch (e) {
    // nothing to stop
  }
  process.exit(1);
});
