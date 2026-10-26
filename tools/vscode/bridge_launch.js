// The pure half of starting the bridge from the extension: which Python,
// which rz80_bridge.py, and what it is told. No vscode API, so it is tested
// from plain Node (node tests/bridge_launch_test.js); bridge_view.js does
// the starting, stopping and showing. Shaped like the zx extension's
// server_launch.js.

'use strict';

const path = require('path');

const DEFAULT_PORTS = { dap: 4780, mcp: 8780, console: 4781 };
const SCRIPT = 'rz80_bridge.py';

// ${workspaceFolder}, ${userHome} and a leading ~ in a path setting, as VS
// Code's own settings read them. A variable that cannot be filled (no folder
// open) gives null rather than half a path.
function expandVariables(text, workspaceFolder, home) {
  let out = String(text || '').trim();
  if (!out) {
    return null;
  }
  if (out.includes('${workspaceFolder}')) {
    if (!workspaceFolder) {
      return null;
    }
    out = out.split('${workspaceFolder}').join(workspaceFolder);
  }
  out = out.split('${userHome}').join(home);
  if (out === '~' || out.startsWith('~/') || out.startsWith('~\\')) {
    out = home + out.slice(1);
  }
  return out;
}

// Where to look for rz80_bridge.py, in order: the setting, each workspace
// folder's tools/ (so this repository needs no setup), then the tools/ this
// extension sits in (it is installed as a link to tools/vscode).
function bridgeCandidates({ setting, folders, home, extensionPath }) {
  const candidates = [];
  const configured = expandVariables(setting, folders[0], home);
  if (configured) {
    candidates.push(configured);
  }
  for (const folder of folders) {
    candidates.push(path.join(folder, 'tools', SCRIPT));
  }
  if (extensionPath) {
    candidates.push(path.join(extensionPath, '..', SCRIPT));
  }
  return { candidates, configured };
}

function findFirst(candidates, exists) {
  for (const candidate of candidates) {
    if (exists(candidate)) {
      return path.normalize(candidate);
    }
  }
  return null;
}

// The Python to run it with: the setting, else `python` on Windows (the
// py launcher's and MSYS2's name) and `python3` elsewhere.
function pythonCommand(setting, folder, home, platform) {
  return expandVariables(setting, folder, home) || (platform === 'win32' ? 'python' : 'python3');
}

function clampPort(value, fallback) {
  const n = Math.floor(Number(value));
  return Number.isFinite(n) && n >= 0 && n <= 65535 ? n : fallback;
}

// The three ports from the settings, each falling back to its default.
function bridgePorts(get) {
  return {
    dap: clampPort(get('dapPort'), DEFAULT_PORTS.dap),
    mcp: clampPort(get('mcpPort'), DEFAULT_PORTS.mcp),
    console: clampPort(get('consolePort'), DEFAULT_PORTS.console)
  };
}

// The command line after the Python: the script, the board, the ports.
// `serial` is a port name (COM5, /dev/ttyUSB1), tcp:HOST:PORT for a
// simulation, or "model" for the stub model.
function bridgeArgs({ script, serial, ports, extra }) {
  const args = [script];
  if (serial === 'model') {
    args.push('--model');
  } else {
    args.push('--port', serial);
  }
  args.push('--dap-port', String(ports.dap), '--mcp-port', String(ports.mcp),
    '--console-port', String(ports.console));
  for (const arg of Array.isArray(extra) ? extra : []) {
    args.push(String(arg));
  }
  return args;
}

// The serial port a session wants: launch.json's "port", else the setting.
// Empty is an error the caller reports.
function serialFor(config, setting) {
  const port = String((config && config.port) || setting || '').trim();
  return port || null;
}

// `netstat -ano` output -> the PID listening on a TCP port, or null. For
// stopping a bridge the extension did not start itself.
function pidListeningOn(netstatText, port) {
  for (const line of String(netstatText).split(/\r?\n/)) {
    const cols = line.trim().split(/\s+/);
    if (cols.length < 5 || cols[0] !== 'TCP' || cols[3] !== 'LISTENING') {
      continue;
    }
    const local = cols[1];
    if (local.slice(local.lastIndexOf(':') + 1) === String(port)) {
      const pid = Number(cols[4]);
      if (Number.isInteger(pid) && pid > 0) {
        return pid;
      }
    }
  }
  return null;
}

module.exports = {
  DEFAULT_PORTS, SCRIPT, expandVariables, bridgeCandidates, findFirst, pythonCommand,
  bridgePorts, bridgeArgs, serialFor, pidListeningOn
};
