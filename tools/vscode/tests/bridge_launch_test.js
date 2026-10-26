// node tools/vscode/tests/bridge_launch_test.js
'use strict';
const assert = require('assert');
const path = require('path');
const b = require('../bridge_launch');
const { test, done } = require('./harness');

test('the bridge is found from the setting, a workspace folder, or beside the extension', () => {
  const found = b.bridgeCandidates({ setting: '${workspaceFolder}/x/rz80_bridge.py', folders: ['/w'], home: '/h',
    extensionPath: '/repo/tools/vscode' });
  assert.deepStrictEqual(found.candidates, ['/w/x/rz80_bridge.py', path.join('/w', 'tools', 'rz80_bridge.py'),
    path.join('/repo/tools/vscode', '..', 'rz80_bridge.py')]);
  const exists = (f) => f === path.join('/repo/tools/vscode', '..', 'rz80_bridge.py');
  assert.strictEqual(b.findFirst(found.candidates, exists), path.normalize('/repo/tools/rz80_bridge.py'));
  assert.strictEqual(b.findFirst(found.candidates, () => false), null);
});

test('python is the setting, else python on Windows and python3 elsewhere', () => {
  assert.strictEqual(b.pythonCommand('', '/w', '/h', 'win32'), 'python');
  assert.strictEqual(b.pythonCommand('', '/w', '/h', 'linux'), 'python3');
  assert.strictEqual(b.pythonCommand('~/venv/bin/python', '/w', '/h', 'linux'), '/h/venv/bin/python');
});

test('ports default to 4780, 8780 and 4781', () => {
  assert.deepStrictEqual(b.bridgePorts(() => undefined), { dap: 4780, mcp: 8780, console: 4781 });
  assert.deepStrictEqual(b.bridgePorts((k) => ({ dapPort: 5000, mcpPort: 'x', consolePort: 70000 })[k]),
    { dap: 5000, mcp: 8780, console: 4781 });
});

test('the command line: a serial port, a simulation, or the model', () => {
  const ports = { dap: 4780, mcp: 8780, console: 4781 };
  assert.deepStrictEqual(b.bridgeArgs({ script: 's.py', serial: 'COM5', ports }),
    ['s.py', '--port', 'COM5', '--dap-port', '4780', '--mcp-port', '8780', '--console-port', '4781']);
  assert.deepStrictEqual(b.bridgeArgs({ script: 's.py', serial: 'model', ports, extra: ['-q'] }).slice(1, 2), ['--model']);
  assert.deepStrictEqual(b.bridgeArgs({ script: 's.py', serial: 'tcp:127.0.0.1:9000', ports }).slice(1, 3),
    ['--port', 'tcp:127.0.0.1:9000']);
});

test('the serial port is launch.json\'s, else the setting\'s', () => {
  assert.strictEqual(b.serialFor({ port: 'COM7' }, 'COM5'), 'COM7');
  assert.strictEqual(b.serialFor({}, 'COM5'), 'COM5');
  assert.strictEqual(b.serialFor({}, ''), null);
});

test('netstat finds the pid on a port', () => {
  const text = '  TCP    127.0.0.1:4780   0.0.0.0:0   LISTENING   1234\n  TCP    127.0.0.1:47800  0.0.0.0:0   LISTENING   99';
  assert.strictEqual(b.pidListeningOn(text, 4780), 1234);
  assert.strictEqual(b.pidListeningOn(text, 4781), null);
});

done();
