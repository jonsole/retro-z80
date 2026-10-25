// The program panel: open a .rimg to see its header (rlink.py show's line,
// both CRCs) with Debug and Run buttons, as the zx extension's program view
// does for snapshots.

'use strict';

const vscode = require('vscode');
const fs = require('fs');
const path = require('path');
const { parseImage, describeImage, hex } = require('./rimg');

function escapeHtml(text) {
  return String(text).replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' })[c]);
}

function page(file, h, nonce) {
  const rows = h ? [
    ['Machine', h.machine], ['Target', h.targetName],
    [h.target === 1 ? 'Offset' : 'Load', (h.phys ? 'P' : '') + hex(h.load, 4)],
    ['Entry', hex(h.entry, 4)], ['Size', `${h.size} bytes`],
    ['Header CRC', `${hex(h.hcrc, 8)} ${h.hcrcOk ? 'ok' : 'bad'}`],
    ['Image CRC', `${hex(h.icrc, 8)} ${h.icrcOk ? 'ok' : 'bad'}`]
  ] : [];
  const sld = file.replace(/\.rimg$/i, '.sld');
  const body = h ? `
    <p class="line">${escapeHtml(describeImage(h))}</p>
    ${h.problems.length ? `<p class="bad">${h.problems.map(escapeHtml).join('<br>')}</p>` : ''}
    <table>${rows.map(([k, v]) => `<tr><th>${k}</th><td>${escapeHtml(v)}</td></tr>`).join('')}</table>
    <p class="sld">${fs.existsSync(sld) ? 'Symbols: ' + escapeHtml(path.basename(sld)) : 'No SLD file beside it: debugging by address only.'}</p>
    <p><button id="debug">Debug on the board</button> <button id="run">Run</button></p>`
    : '<p class="bad">Not an image file: no RIMG header (docs/spec/monitor.md, section 5).</p>';
  return `<!DOCTYPE html><html><head><meta charset="utf-8">
<meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; script-src 'nonce-${nonce}';">
<style>
body { font-family: var(--vscode-font-family); color: var(--vscode-foreground); padding: 16px; }
h1 { font-size: 1.3em; } .line { font-family: var(--vscode-editor-font-family); }
th { text-align: left; padding-right: 2em; font-weight: normal; color: var(--vscode-descriptionForeground); }
td { font-family: var(--vscode-editor-font-family); } .bad { color: var(--vscode-errorForeground); }
button { color: var(--vscode-button-foreground); background: var(--vscode-button-background); border: none; padding: 6px 14px; cursor: pointer; }
</style></head><body><h1>${escapeHtml(path.basename(file))}</h1>${body}
<script nonce="${nonce}">
const vscode = acquireVsCodeApi();
for (const id of ['debug', 'run']) {
  const b = document.getElementById(id);
  if (b) { b.addEventListener('click', () => vscode.postMessage({ command: id })); }
}
</script></body></html>`;
}

class ProgramEditor {
  openCustomDocument(uri) {
    return { uri, dispose() {} };
  }

  resolveCustomEditor(document, panel) {
    const file = document.uri.fsPath;
    const nonce = Math.random().toString(36).slice(2);
    let h = null;
    try {
      h = parseImage(fs.readFileSync(file));
    } catch (err) {
      h = null;
    }
    panel.webview.options = { enableScripts: true };
    panel.webview.html = page(file, h, nonce);
    panel.webview.onDidReceiveMessage((msg) => {
      const folder = vscode.workspace.getWorkspaceFolder(document.uri);
      const sld = file.replace(/\.rimg$/i, '.sld');
      const config = { type: 'retro-z80', request: 'launch', name: path.basename(file), program: file,
        stopOnEntry: msg.command === 'debug' };
      if (fs.existsSync(sld)) {
        config.sld = sld;
      }
      vscode.debug.startDebugging(folder, config, { noDebug: false });
    });
  }
}

function activateProgramView(context) {
  context.subscriptions.push(vscode.window.registerCustomEditorProvider('retroz80.program', new ProgramEditor(),
    { webviewOptions: { retainContextWhenHidden: false }, supportsMultipleEditorsPerDocument: true }));
}

module.exports = { activateProgramView, page };
