// The watchpoints the board holds, in the debug sidebar, whoever set them
// (VS Code's data breakpoints, this panel, or MCP), and Watch Address...
// Adapted from the zx extension's watchpoint_view.js: the debug unit has 2
// watchpoints, compares an address under a mask, and has no hit counts or
// on/off switch.

'use strict';

const vscode = require('vscode');
const { watchpointName, watchpointDetail, parseWatchRequest, lengthAllowed } = require('./watchpoint_model');

let provider;
let view;
let refreshTimer;

class WatchpointTreeProvider {
  constructor() {
    this.watchpoints = [];
    this.emitter = new vscode.EventEmitter();
    this.onDidChangeTreeData = this.emitter.event;
  }

  set(watchpoints) {
    this.watchpoints = watchpoints || [];
    this.emitter.fire();
  }

  getChildren() {
    return this.watchpoints;
  }

  getParent() {
    return undefined;
  }

  getTreeItem(w) {
    const item = new vscode.TreeItem(watchpointName(w), vscode.TreeItemCollapsibleState.None);
    item.description = watchpointDetail(w);
    item.id = String(w.id);
    item.contextValue = 'rz80Watchpoint';
    item.iconPath = new vscode.ThemeIcon('eye');
    item.tooltip = new vscode.MarkdownString(
      `**${watchpointName(w)}** — ${watchpointDetail(w)}\n\n` +
      'The board stops after the instruction that made the access, and says the address and the byte.');
    return item;
  }
}

function session() {
  const s = vscode.debug.activeDebugSession;
  return s && s.type === 'retro-z80' ? s : undefined;
}

async function send(request, args) {
  const s = session();
  if (!s) {
    vscode.window.showWarningMessage('No retro-z80 debug session is running.');
    return;
  }
  try {
    show(await s.customRequest(request, args));
  } catch (err) {
    vscode.window.showWarningMessage(`retro-z80: ${err.message || err}`);
  }
}

async function watchAddress() {
  let suggestion = '';
  const editor = vscode.window.activeTextEditor;
  if (editor) {
    const range = editor.selection.isEmpty
      ? editor.document.getWordRangeAtPosition(editor.selection.active, /[A-Za-z_.$][\w.$]*/)
      : editor.selection;
    if (range) {
      suggestion = editor.document.getText(range);
    }
  }
  const typed = await vscode.window.showInputBox({
    title: 'Watch Address',
    prompt: 'Address or symbol, and how many bytes (1, 2, 4, 8 ...): "player", "player 8", "$9000,16"',
    value: suggestion
  });
  const request = parseWatchRequest(typed);
  if (!request) {
    return;
  }
  if (!lengthAllowed(request.length)) {
    vscode.window.showWarningMessage('The board watches 1, 2, 4, 8 ... bytes, aligned: the hardware compares ' +
      'under a mask.');
    return;
  }
  const access = await vscode.window.showQuickPick([
    { label: 'Writes', description: 'stop when the program writes it', access: 'write' },
    { label: 'Reads', description: 'stop when the program reads it as data', access: 'read' },
    { label: 'Reads and writes', description: 'either', access: 'readWrite' },
    { label: 'Port writes (OUT)', description: 'an I/O port instead of memory', access: 'write', io: true },
    { label: 'Port reads (IN)', description: 'an I/O port instead of memory', access: 'read', io: true }
  ], { title: `Watch ${request.address}`, placeHolder: 'What to stop on' });
  if (!access) {
    return;
  }
  await send('setWatchpoint', { address: request.address, length: request.length, access: access.access,
    io: access.io === true });
}

function scheduleRefresh() {
  if (refreshTimer) {
    return;
  }
  refreshTimer = setTimeout(async () => {
    refreshTimer = undefined;
    const s = session();
    if (!s) {
      provider.set([]);
      return;
    }
    try {
      show(await s.customRequest('watchpoints', {}));
    } catch (err) {
      provider.set([]);
    }
  }, 100);
}

function show(body) {
  const watchpoints = (body && body.watchpoints) || [];
  provider.set(watchpoints);
  vscode.commands.executeCommand('setContext', 'retroz80.hasWatchpoints', watchpoints.length > 0);
}

function activateWatchpoints(context) {
  provider = new WatchpointTreeProvider();
  view = vscode.window.createTreeView('retroz80Watchpoints', { treeDataProvider: provider });
  context.subscriptions.push(view);
  context.subscriptions.push(
    vscode.commands.registerCommand('retroz80.watchAddress', watchAddress),
    vscode.commands.registerCommand('retroz80.clearWatchpoint', (item) => send('clearWatchpoint', { id: item.id })),
    vscode.commands.registerCommand('retroz80.clearWatchpoints', () => send('clearWatchpoint', {})),
    vscode.debug.registerDebugAdapterTrackerFactory('retro-z80', {
      createDebugAdapterTracker() {
        return {
          onDidSendMessage(message) {
            // a stop may come from MCP's watchpoints too; and data breakpoints change the list
            if (message && ((message.type === 'event' && message.event === 'stopped') ||
                (message.type === 'response' && message.command === 'setDataBreakpoints'))) {
              scheduleRefresh();
            }
          }
        };
      }
    }),
    vscode.debug.onDidChangeActiveDebugSession(() => scheduleRefresh()),
    vscode.debug.onDidTerminateDebugSession(() => show({ watchpoints: [] }))
  );
}

module.exports = { activateWatchpoints };
