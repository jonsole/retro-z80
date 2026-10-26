// retro-z80: Console -- a terminal panel on the bridge's console port
// (docs/spec/debug.md, section 3.6): the monitor's output, and what is typed
// sent to the board while no debug session is attached.

'use strict';

const vscode = require('vscode');
const net = require('net');
const bridge = require('./bridge_view');

function openConsole() {
  const write = new vscode.EventEmitter();
  const close = new vscode.EventEmitter();
  let socket = null;

  const pty = {
    onDidWrite: write.event,
    onDidClose: close.event,
    open() {
      const port = bridge.ports().console;
      socket = net.connect(port, bridge.HOST);
      socket.on('connect', () => write.fire(`[retro-z80 console on port ${port}]\r\n`));
      socket.on('data', (chunk) => write.fire(chunk.toString('latin1')));
      socket.on('error', (err) => write.fire(`\r\n[console: ${err.message}]\r\n`));
      socket.on('close', () => {
        write.fire('\r\n[the bridge closed the console]\r\n');
        socket = null;
      });
    },
    close() {
      if (socket) {
        socket.destroy();
      }
    },
    handleInput(data) {
      if (socket) {
        socket.write(Buffer.from(data, 'latin1'));
      }
    }
  };
  const terminal = vscode.window.createTerminal({ name: 'retro-z80 console', pty });
  terminal.show();
  return terminal;
}

function activateConsole(context) {
  context.subscriptions.push(vscode.commands.registerCommand('retroz80.console', async () => {
    const serial = vscode.workspace.getConfiguration('retroz80.bridge').get('serialPort') ||
      await vscode.window.showInputBox({ title: 'retro-z80 console',
        prompt: 'Serial port of the FT232H (COM5, /dev/ttyUSB1), tcp:HOST:PORT, or model', value: 'model' });
    if (!serial) {
      return;
    }
    try {
      await bridge.ensureBridge(serial);
    } catch (err) {
      vscode.window.showErrorMessage(err.message);
      return;
    }
    openConsole();
  }));
}

module.exports = { activateConsole };
