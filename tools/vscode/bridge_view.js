// Starting the bridge from VS Code (docs/spec/debug.md, section 3.3).
//
// A retro-z80 debug session goes through the descriptor factory registered
// here: it makes sure rz80_bridge.py is listening on the DAP port -- joining
// one that is, starting one if nothing is -- and hands VS Code that port.
// Shaped like the zx extension's server_view.js.
//
// A bridge the extension starts outlives the debug session, so an MCP client
// keeps the board between sessions; it is stopped when VS Code closes
// (retroz80.bridge.stopOnExit). A bridge something else started (rz80_mcp.py,
// or one by hand) is only joined, and stopped only when asked.
//
// The pure half -- which Python, which script, what it is told -- is
// bridge_launch.js.

'use strict';

const vscode = require('vscode');
const cp = require('child_process');
const fs = require('fs');
const net = require('net');
const os = require('os');
const path = require('path');
const launch = require('./bridge_launch');
const registry = require('./server_registry');
const sjasmplus = require('./sjasmplus_fetch');

const HOST = '127.0.0.1';
const START_TIMEOUT_MS = 15000;

let output;
let statusItem;
let extensionPath;
let storagePath;
let child = null;          // the bridge this extension started, while it runs
let childSerial = null;    // the serial port it was started on
let state = 'stopped';     // stopped | starting | running | external
let starting = null;       // the start in progress, so two sessions share it

function settings() {
  return vscode.workspace.getConfiguration('retroz80.bridge');
}

function folders() {
  return (vscode.workspace.workspaceFolders || []).map((f) => f.uri.fsPath);
}

function ports() {
  const config = settings();
  return launch.bridgePorts((key) => config.get(key));
}

// Whether anything answers on a port.
function probe(port, timeoutMs = 400) {
  return new Promise((resolve) => {
    const socket = net.connect(port, HOST);
    const done = (ok) => {
      socket.destroy();
      resolve(ok);
    };
    socket.setTimeout(timeoutMs, () => done(false));
    socket.once('connect', () => done(true));
    socket.once('error', () => done(false));
  });
}

function advertDir() {
  return registry.advertDirectory({ env: process.env, platform: process.platform, home: os.homedir(),
    tmp: os.tmpdir() });
}

// The live bridges on this machine, from their adverts.
function bridges() {
  return registry.liveServers(advertDir(), {
    readdir: (d) => fs.readdirSync(d),
    readFile: (f) => fs.readFileSync(f, 'utf8'),
    unlink: (f) => fs.unlinkSync(f),
    alive: registry.processAlive
  });
}

// The bridge on a DAP port, from its advert, or null.
function bridgeOn(dapPort) {
  return bridges().find((b) => b.ports.dap === dapPort) || null;
}

function setState(next) {
  state = next;
  vscode.commands.executeCommand('setContext', 'retroz80.bridgeRunning', next === 'running' || next === 'external');
  if (!statusItem) {
    return;
  }
  if (next === 'stopped') {
    statusItem.hide();
    return;
  }
  const p = ports();
  const advert = bridgeOn(p.dap);
  const where = advert && advert.serialPort ? advert.serialPort : (childSerial || 'the board');
  statusItem.text = next === 'starting' ? '$(loading~spin) retro-z80' : `$(plug) retro-z80 ${where}`;
  statusItem.tooltip = next === 'starting' ? `Starting the retro-z80 bridge on ${where}...`
    : `retro-z80 bridge on ${where}: DAP ${p.dap}, MCP ${p.mcp}, console ${p.console}` +
      (next === 'running' ? ', started by VS Code' : ', started outside this window');
  statusItem.show();
}

async function refreshState() {
  if (state === 'starting') {
    return;
  }
  const up = await probe(ports().dap);
  setState(!up ? 'stopped' : child ? 'running' : 'external');
}

function locateBridge() {
  const found = launch.bridgeCandidates({ setting: settings().get('path'), folders: folders(), home: os.homedir(),
    extensionPath });
  const exists = (file) => {
    try {
      return fs.statSync(file).isFile();
    } catch (err) {
      return false;
    }
  };
  return { script: launch.findFirst(found.candidates, exists), configured: found.configured };
}

class StartError extends Error {}

// Makes sure a bridge is listening on the DAP port, starting one on `serial`
// if nothing is. Resolves once it answers.
async function ensureBridge(serial) {
  if (starting) {
    return starting;
  }
  if (await probe(ports().dap)) {
    const advert = bridgeOn(ports().dap);
    if (serial && advert && advert.serialPort && advert.serialPort !== serial) {
      throw new StartError(`The bridge on port ${ports().dap} has ${advert.serialPort} open, not ${serial}. ` +
        'Stop it (retro-z80: Stop Bridge), or give the launch other "bridgePorts".');
    }
    await refreshState();
    return;
  }
  if (!serial) {
    throw new StartError('No serial port to start the bridge on: give "port" in launch.json (COM5, ' +
      '/dev/ttyUSB1, tcp:HOST:PORT, or "model"), or set retroz80.bridge.serialPort.');
  }
  starting = startBridge(serial, ports()).finally(() => {
    starting = null;
  });
  return starting;
}

async function startBridge(serial, p) {
  const { script, configured } = locateBridge();
  if (!script) {
    throw new StartError('Could not find rz80_bridge.py. ' + (configured
      ? `retroz80.bridge.path names ${configured}, which does not exist.`
      : 'Open the retro-z80 repository, or set retroz80.bridge.path.'));
  }
  const python = launch.pythonCommand(settings().get('python'), folders()[0], os.homedir(), process.platform);
  const args = launch.bridgeArgs({ script, serial, ports: p, extra: settings().get('args', []) });
  output.appendLine(`> ${python} ${args.join(' ')}`);
  setState('starting');
  let proc;
  try {
    proc = cp.spawn(python, args, { cwd: path.dirname(path.dirname(script)), windowsHide: true,
      stdio: ['ignore', 'pipe', 'pipe'] });
  } catch (err) {
    setState('stopped');
    throw new StartError(`Could not start ${python}: ${err.message}`);
  }
  let exited = null;
  proc.stdout.on('data', (chunk) => output.append(chunk.toString()));
  proc.stderr.on('data', (chunk) => output.append(chunk.toString()));
  proc.on('error', (err) => {
    exited = exited || { message: err.message };
  });
  proc.on('exit', (code) => {
    exited = exited || { code };
    output.appendLine(`[the bridge exited${code !== null ? ' with code ' + code : ''}]`);
    if (child === proc) {
      child = null;
      childSerial = null;
      refreshState();
    }
  });
  child = proc;
  childSerial = serial;
  const deadline = Date.now() + START_TIMEOUT_MS;
  while (Date.now() < deadline) {
    if (exited) {
      setState('stopped');
      output.show(true);
      throw new StartError('The bridge stopped at once' + (exited.message ? `: ${exited.message}` :
        ` (exit ${exited.code}). Is ${serial} right, and free? Is pyserial installed (pip install pyserial)?`));
    }
    if (await probe(p.dap, 200)) {
      setState('running');
      return;
    }
    await new Promise((resolve) => setTimeout(resolve, 150));
  }
  setState('stopped');
  throw new StartError(`The bridge did not answer on port ${p.dap} within ${START_TIMEOUT_MS / 1000} s.`);
}

async function stopBridge() {
  if (child) {
    child.kill();
    child = null;
    childSerial = null;
    await new Promise((resolve) => setTimeout(resolve, 300));
    await refreshState();
    return;
  }
  const advert = bridgeOn(ports().dap);
  if (!advert) {
    vscode.window.showInformationMessage('No retro-z80 bridge is running on port ' + ports().dap + '.');
    return;
  }
  const answer = await vscode.window.showWarningMessage(
    `The bridge on ${advert.serialPort || 'port ' + ports().dap} (pid ${advert.pid}) was started outside this ` +
    'window. Stop it? Its debug and MCP clients lose the board.', { modal: true }, 'Stop it');
  if (answer === 'Stop it') {
    try {
      process.kill(advert.pid);
    } catch (err) {
      vscode.window.showErrorMessage(`Could not stop pid ${advert.pid}: ${err.message}`);
    }
    await new Promise((resolve) => setTimeout(resolve, 300));
    await refreshState();
  }
}

// ---- sjasmplus ---------------------------------------------------------------
// As the zx extension: one on the PATH is used as it is; otherwise, on
// Windows, the pinned release is fetched once into the extension's storage.

let fetching = null;

function onPath(name) {
  const exts = process.platform === 'win32' ? ['.exe', '.cmd', '.bat', ''] : [''];
  for (const dir of String(process.env.PATH || '').split(path.delimiter)) {
    for (const ext of exts) {
      const candidate = path.join(dir.trim(), name + ext);
      if (dir.trim() && fs.existsSync(candidate)) {
        return candidate;
      }
    }
  }
  return null;
}

async function ensureSjasmplus() {
  const configured = vscode.workspace.getConfiguration('retroz80').get('sjasmplus');
  if (configured) {
    return configured;
  }
  const found = onPath('sjasmplus');
  if (found) {
    return found;
  }
  if (process.platform !== 'win32' || !storagePath) {
    return 'sjasmplus';
  }
  const target = path.join(storagePath, `sjasmplus-${sjasmplus.SJASMPLUS.version}`, 'sjasmplus.exe');
  if (fs.existsSync(target)) {
    return target;
  }
  if (!fetching) {
    fetching = vscode.window.withProgress(
      { location: vscode.ProgressLocation.Notification,
        title: `Fetching sjasmplus ${sjasmplus.SJASMPLUS.version}, the Z80 assembler` },
      async () => {
        const zip = await sjasmplus.download(sjasmplus.SJASMPLUS.url);
        const exe = sjasmplus.unpackSjasmplus(zip);
        fs.mkdirSync(path.dirname(target), { recursive: true });
        fs.writeFileSync(target + '.part', exe);
        fs.renameSync(target + '.part', target);
        output.appendLine(`[fetched sjasmplus ${sjasmplus.SJASMPLUS.version} into ${target}]`);
        return target;
      }).finally(() => {
      fetching = null;
    });
  }
  try {
    return await fetching;
  } catch (err) {
    vscode.window.showErrorMessage(`Could not fetch sjasmplus: ${err.message}. Put sjasmplus on the PATH ` +
      '(https://github.com/z00m128/sjasmplus/releases) and try again.');
    return 'sjasmplus';
  }
}

// ---- activation --------------------------------------------------------------

function activateBridge(context) {
  extensionPath = context.extensionPath;
  storagePath = context.globalStorageUri ? context.globalStorageUri.fsPath : null;
  output = vscode.window.createOutputChannel('retro-z80 bridge');
  statusItem = vscode.window.createStatusBarItem(vscode.StatusBarAlignment.Left, 50);
  statusItem.command = 'retroz80.bridgeLog';
  context.subscriptions.push(output, statusItem);

  context.subscriptions.push(
    vscode.debug.registerDebugAdapterDescriptorFactory('retro-z80', {
      async createDebugAdapterDescriptor(session) {
        const config = session.configuration;
        const asked = registry.launchPorts(config.bridgePorts, ports());
        if (asked.error) {
          throw new Error(asked.error);
        }
        const serial = launch.serialFor(config, settings().get('serialPort'));
        try {
          if (asked.request && asked.request.ports) {
            const p = asked.request.ports;
            if (!(await probe(p.dap))) {
              await startBridge(serial || '', p);
            }
            return new vscode.DebugAdapterServer(p.dap, HOST);
          }
          await ensureBridge(serial);
        } catch (err) {
          vscode.window.showErrorMessage(err.message);
          throw err;
        }
        return new vscode.DebugAdapterServer(ports().dap, HOST);
      }
    })
  );

  context.subscriptions.push(
    vscode.debug.registerDebugConfigurationProvider('retro-z80', {
      resolveDebugConfiguration(folder, config) {
        // F5 with no launch.json: debug the open .rimg, or the build of the open .asm.
        if (!config.type && !config.request && !config.name) {
          const editor = vscode.window.activeTextEditor;
          const file = editor ? editor.document.uri.fsPath : '';
          if (!file) {
            return undefined;
          }
          const stem = file.replace(/\.[^.\\/]*$/, '');
          config = { type: 'retro-z80', request: 'launch', name: 'Debug on the board',
            program: file.endsWith('.rimg') ? file : path.join(path.dirname(file), 'build', path.basename(stem) + '.rimg') };
          if (!file.endsWith('.rimg')) {
            config.sld = config.program.replace(/\.rimg$/, '.sld');
          }
        }
        if (!config.cwd && folder) {
          config.cwd = folder.uri.fsPath;
        }
        return config;
      }
    })
  );

  context.subscriptions.push(
    vscode.commands.registerCommand('retroz80.bridgeStart', async () => {
      const serial = settings().get('serialPort') || await vscode.window.showInputBox({
        title: 'Start the retro-z80 bridge', prompt: 'Serial port of the FT232H (COM5, /dev/ttyUSB1), ' +
          'tcp:HOST:PORT for a simulation, or model', value: 'model' });
      if (!serial) {
        return;
      }
      try {
        await ensureBridge(serial);
      } catch (err) {
        vscode.window.showErrorMessage(err.message);
      }
    }),
    vscode.commands.registerCommand('retroz80.bridgeStop', stopBridge),
    vscode.commands.registerCommand('retroz80.bridgeLog', () => output.show()),
    vscode.commands.registerCommand('retroz80.sjasmplusPath', () => ensureSjasmplus())
  );
  refreshState();
}

function deactivateBridge() {
  if (child && settings().get('stopOnExit', true)) {
    child.kill();
    child = null;
  }
}

module.exports = { activateBridge, deactivateBridge, ports, ensureBridge, ensureSjasmplus, probe, HOST };
