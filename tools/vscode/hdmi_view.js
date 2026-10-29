// Show Screen: the board's HDMI output, through a USB capture device, live in
// an editor tab, as the zx emulator's extension shows its screen. ffmpeg reads
// the device (hdmi_stream.js); the frames go to the tab one at a time, the
// newest first, so a slow tab drops frames rather than lag.
//
// A capture device opens for one program at a time, so while it streams this
// serves its frames on 127.0.0.1 (retroz80.screen.port) for the bridge's MCP
// tools screen_capture and screen_record (tools/rz80bridge/screen.py):
//   /frame.jpg   the latest frame
//   /record?ms=N the frames of the next N ms: per frame its time in ms (a
//                big-endian double), its length (4 bytes) and the JPEG
//   /device      the capture device it uses
// It streams only while the tab is visible and not paused; otherwise the
// device is free and the MCP tools open it themselves.

'use strict';

const vscode = require('vscode');
const cp = require('child_process');
const fs = require('fs');
const http = require('http');
const path = require('path');
const { JpegSplitter, jpegSize, findFfmpeg, ffmpegArgs, listDevices, pickDevice } = require('./hdmi_stream');
const { FILTERS, SCALES, layoutFor, prescaleFactor, normaliseView } = require('./screen_scaling');

const PANEL_TYPE = 'retroz80Screen';

// Keys typed in the tab go to the bridge's MCP tools key_down and key_up
// (ticket #44), which send them to the board as PS/2 bytes. One connection,
// so a key's release never overtakes its press.
class BridgeKeys {
  constructor(onProblem) {
    this.agent = new http.Agent({ keepAlive: true, maxSockets: 1 });
    this.onProblem = onProblem;
    this.id = 0;
    this.warned = false;
  }

  call(name, args) {
    const port = vscode.workspace.getConfiguration('retroz80.bridge').get('mcpPort', 8780);
    const body = JSON.stringify({ jsonrpc: '2.0', id: ++this.id, method: 'tools/call', params: { name, arguments: args } });
    const req = http.request({ host: '127.0.0.1', port, path: '/mcp', method: 'POST', agent: this.agent,
      headers: { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(body) } }, (res) => {
      let text = '';
      res.on('data', (d) => { text += d; });
      res.on('end', () => {
        try {
          const r = JSON.parse(text).result;
          if (r && r.isError) {
            this.onProblem(`Keys: ${r.content[0].text}`);
          } else {
            this.warned = false;
          }
        } catch (err) {
          // an answer that is not JSON: not the bridge
        }
      });
    });
    req.on('error', () => {
      if (!this.warned) {
        this.warned = true;
        this.onProblem(`Keys need the bridge, and nothing answers on port ${port}: start it (retro-z80: Start Bridge) or a debug session`);
      }
    });
    req.end(body);
  }
}
const RETRY_MS = 3000;

function settings() {
  const c = vscode.workspace.getConfiguration('retroz80.screen');
  return {
    device: c.get('device', ''), ffmpeg: c.get('ffmpeg', ''), reencode: c.get('reencode', false),
    port: c.get('port', 4790)
  };
}

// One webview showing the stream, with its own one-frame-in-flight rule.
class Viewer {
  constructor(webview, isVisible) {
    this.webview = webview;
    this.isVisible = isVisible;
    this.busy = false;
    this.pending = null;
  }

  offer(jpeg) {
    if (this.busy) {
      this.pending = jpeg;
      return;
    }
    this.busy = true;
    this.webview.postMessage({ type: 'frame', data: new Uint8Array(jpeg) }).then((ok) => {
      if (!ok) {
        this.busy = false;
      }
    }, () => { this.busy = false; });
  }

  ack() {
    this.busy = false;
    if (this.pending) {
      const p = this.pending;
      this.pending = null;
      this.offer(p);
    }
  }

  post(msg) {
    this.webview.postMessage(msg).then(undefined, () => undefined);
  }
}

class ScreenStream {
  constructor(log) {
    this.log = log;
    this.viewers = new Set();
    this.paused = false;
    this.child = null;
    this.retry = null;
    this.latest = null; // { jpeg, time }
    this.recorders = new Set();
    this.device = null; // the one in use, or last found
    this.status = { text: 'Starting...', error: false };
    this.frames = 0;
    this.fpsTimer = null;
    this.gen = 0; // bumped by stop(), so a start still looking for a device gives up
  }

  wanted() {
    return !this.paused && [...this.viewers].some((v) => v.isVisible());
  }

  streaming() {
    return this.child !== null && this.latest !== null && Date.now() - this.latest.time < 1000;
  }

  update() {
    if (this.wanted()) {
      if (!this.child && !this.retry) {
        this.start();
      }
    } else {
      clearTimeout(this.retry);
      this.retry = null;
      this.stop();
      this.setStatus(this.paused ? 'Paused: the capture device is free' : 'Hidden', false);
    }
  }

  setStatus(text, error) {
    this.status = { text, error };
    for (const v of this.viewers) {
      v.post({ type: 'status', text, error });
    }
  }

  addViewer(viewer) {
    this.viewers.add(viewer);
    viewer.post({ type: 'status', ...this.status });
    if (this.latest) {
      viewer.offer(this.latest.jpeg);
    }
    this.update();
  }

  removeViewer(viewer) {
    this.viewers.delete(viewer);
    this.update();
  }

  async start() {
    const s = settings();
    const ffmpeg = findFfmpeg(s.ffmpeg);
    if (!ffmpeg) {
      this.setStatus('ffmpeg not found: install it (winget install Gyan.FFmpeg) or set retroz80.screen.ffmpeg', true);
      return;
    }
    this.child = 'starting';
    const gen = ++this.gen;
    let device = s.device;
    if (!device) {
      this.setStatus('Looking for a capture device...', false);
      device = pickDevice(await listDevices(ffmpeg));
    }
    if (gen !== this.gen) {
      return;
    }
    if (!this.wanted()) {
      this.child = null;
      return;
    }
    if (!device) {
      this.child = null;
      this.setStatus('No video capture device found: plug it in, or set retroz80.screen.device', true);
      this.later();
      return;
    }
    this.device = device;
    const args = ffmpegArgs(device, s.reencode);
    this.log.appendLine(`screen: ${ffmpeg} ${args.join(' ')}`);
    this.setStatus(`Opening ${device}...`, false);
    const child = cp.spawn(ffmpeg, args, { windowsHide: true, stdio: ['ignore', 'pipe', 'pipe'] });
    this.child = child;
    const splitter = new JpegSplitter();
    let stderr = '';
    child.stdout.on('data', (chunk) => {
      for (const jpeg of splitter.push(chunk)) {
        this.frame(jpeg);
      }
    });
    child.stderr.on('data', (d) => {
      stderr = (stderr + d.toString()).slice(-2000);
    });
    child.on('error', (err) => {
      stderr += err.message;
    });
    child.on('close', (code) => {
      if (this.child !== child) {
        return;
      }
      this.child = null;
      clearInterval(this.fpsTimer);
      this.fpsTimer = null;
      const last = stderr.trim().split(/\r?\n/).pop() || `ffmpeg stopped (exit ${code})`;
      this.log.appendLine(`screen: ${stderr.trim() || last}`);
      if (this.wanted()) {
        const busy = /in use|could not run graph|I\/O error|busy/i.test(stderr) ? ' (in use by another program?)' : '';
        this.setStatus(`${device}: ${last}${busy}. Trying again...`, true);
        this.later();
      }
    });
    this.frames = 0;
    this.fpsTimer = setInterval(() => {
      const size = this.latest ? jpegSize(this.latest.jpeg) : null;
      const dims = size ? `${size.width}×${size.height}` : '';
      if (this.frames === 0) {
        this.setStatus(`${device}: no picture (is the board on, and its HDMI in?)`, true);
      } else {
        this.setStatus(`${device} · ${dims} · ${this.frames} fps`, false);
      }
      this.frames = 0;
    }, 1000);
  }

  later() {
    clearTimeout(this.retry);
    this.retry = setTimeout(() => {
      this.retry = null;
      this.update();
    }, RETRY_MS);
  }

  stop() {
    this.gen++;
    const child = this.child;
    this.child = null;
    clearInterval(this.fpsTimer);
    this.fpsTimer = null;
    if (child && child !== 'starting') {
      child.kill();
    }
  }

  frame(jpeg) {
    const time = Date.now();
    this.latest = { jpeg, time };
    this.frames++;
    for (const r of this.recorders) {
      r(jpeg, time);
    }
    for (const v of this.viewers) {
      if (v.isVisible()) {
        v.offer(jpeg);
      }
    }
  }

  dispose() {
    clearTimeout(this.retry);
    this.stop();
  }
}

// ---- the HTTP side, for the MCP tools ---------------------------------------
function serve(stream, port, log) {
  const server = http.createServer((req, res) => {
    const url = new URL(req.url, 'http://127.0.0.1');
    const send = (status, type, body) => {
      res.writeHead(status, { 'Content-Type': type, 'Content-Length': Buffer.byteLength(body), 'Cache-Control': 'no-store' });
      res.end(body);
    };
    if (url.pathname === '/device') {
      const d = settings().device || stream.device;
      return d ? send(200, 'text/plain; charset=utf-8', d) : send(404, 'text/plain', 'no device known');
    }
    if (url.pathname === '/status') {
      return send(200, 'application/json', JSON.stringify({ streaming: stream.streaming(), paused: stream.paused,
        device: stream.device, status: stream.status.text }));
    }
    if (!stream.streaming()) {
      return send(503, 'text/plain', 'not streaming: the capture device is free');
    }
    if (url.pathname === '/frame.jpg') {
      return send(200, 'image/jpeg', stream.latest.jpeg);
    }
    if (url.pathname === '/record') {
      const ms = Math.min(30000, Math.max(0, Number(url.searchParams.get('ms')) || 2000));
      const parts = [];
      let t0 = null;
      const rec = (jpeg, time) => {
        t0 = t0 === null ? time : t0;
        const head = Buffer.alloc(12);
        head.writeDoubleBE(time - t0, 0);
        head.writeUInt32BE(jpeg.length, 8);
        parts.push(head, jpeg);
      };
      stream.recorders.add(rec);
      setTimeout(() => {
        stream.recorders.delete(rec);
        send(200, 'application/octet-stream', Buffer.concat(parts));
      }, ms);
      return undefined;
    }
    return send(404, 'text/plain', 'not found');
  });
  server.on('error', (err) => log.appendLine(`screen: no frames for MCP on port ${port}: ${err.message}`));
  server.listen(port, '127.0.0.1');
  server.unref(); // never what keeps a process alive
  return server;
}

// ---- the tab ------------------------------------------------------------------
// The view settings go in the page itself: a message sent before the page's
// script has run is not sure to arrive (as in the zx emulator's screen panel).
function page(nonce, view) {
  return `<!DOCTYPE html><html><head><meta charset="utf-8">
<meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; script-src 'nonce-${nonce}';">
<style>
html, body { margin: 0; padding: 0; height: 100%; overflow: hidden; background: #000; }
#wrap { position: absolute; inset: 0; display: flex; align-items: center; justify-content: center; overflow: auto; }
canvas { display: block; flex: none; }
#keys { position: absolute; right: 6px; top: 4px; font: 11px var(--vscode-font-family); color: #ccc;
  background: rgba(0,0,0,.55); padding: 1px 6px; border-radius: 3px; pointer-events: none; }
body.typing #keys { color: #8f8; }
body:not(:hover):not(.typing) #keys { opacity: 0; }
#status { position: absolute; left: 6px; bottom: 4px; font: 11px var(--vscode-font-family); color: #ccc;
  background: rgba(0,0,0,.55); padding: 1px 6px; border-radius: 3px; pointer-events: none; transition: opacity .4s; }
#status.error { color: #f88; opacity: 1 !important; }
body:not(:hover) #status:not(.error) { opacity: 0; }
</style></head><body><div id="wrap"><canvas id="c"></canvas></div>
<div id="status">Starting...</div>
<div id="keys">Click to type on the board</div>
<script nonce="${nonce}">
const layoutFor = ${layoutFor.toString()};
const prescaleFactor = ${prescaleFactor.toString()};
const vscode = acquireVsCodeApi();
const canvas = document.getElementById('c');
const ctx = canvas.getContext('2d');
const prescaled = document.createElement('canvas');
const prescaledCtx = prescaled.getContext('2d');
const status = document.getElementById('status');
let view = ${JSON.stringify(view)};
let frame = null; // the last decoded frame, kept for redraws on resize
function layout() {
  const w = frame ? frame.width : 720, h = frame ? frame.height : 576;
  const l = layoutFor(view.scale, window.innerWidth, window.innerHeight, window.devicePixelRatio || 1, w, h);
  if (canvas.width !== l.canvasW || canvas.height !== l.canvasH) {
    canvas.width = l.canvasW; canvas.height = l.canvasH;
  }
  canvas.style.width = l.cssW + 'px';
  canvas.style.height = l.cssH + 'px';
}
function draw() {
  if (!frame) return;
  const w = canvas.width, h = canvas.height;
  if (view.filter === 'bilinear') {
    ctx.imageSmoothingEnabled = true; ctx.imageSmoothingQuality = 'low';
    ctx.drawImage(frame, 0, 0, w, h);
  } else if (view.filter === 'sharp-bilinear') {
    const k = prescaleFactor(w, h, frame.width, frame.height);
    if (prescaled.width !== frame.width * k || prescaled.height !== frame.height * k) {
      prescaled.width = frame.width * k; prescaled.height = frame.height * k;
    }
    prescaledCtx.imageSmoothingEnabled = false;
    prescaledCtx.drawImage(frame, 0, 0, prescaled.width, prescaled.height);
    ctx.imageSmoothingEnabled = true; ctx.imageSmoothingQuality = 'low';
    ctx.drawImage(prescaled, 0, 0, w, h);
  } else {
    ctx.imageSmoothingEnabled = false;
    ctx.drawImage(frame, 0, 0, w, h);
  }
}
window.addEventListener('resize', () => { layout(); draw(); });
layout();
window.addEventListener('message', async (e) => {
  const m = e.data;
  if (m.type === 'frame') {
    try {
      const bmp = await createImageBitmap(new Blob([m.data], { type: 'image/jpeg' }));
      const resized = !frame || frame.width !== bmp.width || frame.height !== bmp.height;
      if (frame) frame.close();
      frame = bmp;
      if (resized) layout();
      draw();
    } catch (err) { /* a damaged frame: skip it */ }
    vscode.postMessage({ type: 'ack' });
  } else if (m.type === 'status') {
    status.textContent = m.text;
    status.className = m.error ? 'error' : '';
  } else if (m.type === 'view') {
    view = m.view; layout(); draw();
  }
});
// Keys: while the tab has focus every key goes to the board, down and up,
// and none to VS Code; leaving the tab lets go of whatever is held.
const keysHint = document.getElementById('keys');
const held = new Set();
function typing(on) {
  document.body.classList.toggle('typing', on);
  keysHint.textContent = on ? 'Typing on the board' : 'Click to type on the board';
}
function onKey(e, down) {
  if (!e.code) return;
  e.preventDefault();
  e.stopPropagation();
  if (!down && !held.has(e.code)) return;
  if (down) held.add(e.code); else held.delete(e.code);
  vscode.postMessage({ type: 'key', code: e.code, down });
}
window.addEventListener('keydown', (e) => onKey(e, true), true);
window.addEventListener('keyup', (e) => onKey(e, false), true);
window.addEventListener('focus', () => typing(true));
window.addEventListener('blur', () => {
  typing(false);
  if (held.size) { held.clear(); vscode.postMessage({ type: 'keysUp' }); }
});
typing(document.hasFocus());
vscode.postMessage({ type: 'ready' });
</script></body></html>`;
}

function viewSettings() {
  const c = vscode.workspace.getConfiguration('retroz80.screen');
  return normaliseView({ filter: c.get('filter'), scale: c.get('scale') });
}

// The one Show Screen tab, as the zx emulator's: opened beside the editor,
// brought forward where it is if already open.
class ScreenPanel {
  constructor(stream, onDispose) {
    this.stream = stream;
    this.panel = vscode.window.createWebviewPanel(PANEL_TYPE, 'Board Screen',
      { viewColumn: vscode.ViewColumn.Beside, preserveFocus: true },
      { enableScripts: true, retainContextWhenHidden: true });
    this.panel.iconPath = new vscode.ThemeIcon('device-desktop');
    this.panel.webview.html = page(Math.random().toString(36).slice(2), viewSettings());
    this.viewer = new Viewer(this.panel.webview, () => this.panel.visible);
    const keys = new BridgeKeys((text) => this.viewer.post({ type: 'status', text, error: true }));
    this.panel.webview.onDidReceiveMessage((m) => {
      if (m && m.type === 'ack') {
        this.viewer.ack();
      } else if (m && m.type === 'key' && typeof m.code === 'string') {
        keys.call(m.down ? 'key_down' : 'key_up', { key: m.code });
      } else if (m && m.type === 'keysUp') {
        keys.call('key_up', {});
      } else if (m && m.type === 'ready') {
        this.viewer.busy = false;
        stream.addViewer(this.viewer);
      }
    });
    this.panel.onDidChangeViewState(() => {
      stream.update();
      if (this.panel.visible && stream.latest) {
        this.viewer.offer(stream.latest.jpeg);
      }
    });
    this.panel.onDidDispose(() => {
      stream.removeViewer(this.viewer);
      onDispose();
    });
  }

  // Brought forward where it is, never moved, and focus left in the editor.
  show() {
    if (!this.panel.visible) {
      this.panel.reveal(this.panel.viewColumn, true);
    }
  }
}

async function pickScaling() {
  const current = viewSettings();
  const items = [{ label: 'Filter', kind: vscode.QuickPickItemKind.Separator }];
  for (const f of FILTERS) {
    items.push({ label: `${f.id === current.filter ? '$(check)' : '$(blank)'} ${f.label}`, detail: f.detail,
      setting: 'filter', value: f.id });
  }
  items.push({ label: 'Size', kind: vscode.QuickPickItemKind.Separator });
  for (const s of SCALES) {
    items.push({ label: `${s.id === current.scale ? '$(check)' : '$(blank)'} ${s.label}`, detail: s.detail,
      setting: 'scale', value: s.id });
  }
  const pick = await vscode.window.showQuickPick(items, { placeHolder: 'How the board\'s screen is drawn' });
  if (pick && pick.setting) {
    await vscode.workspace.getConfiguration('retroz80.screen').update(pick.setting, pick.value,
      vscode.ConfigurationTarget.Global);
  }
}

function activateScreen(context, log) {
  const output = log || vscode.window.createOutputChannel('retro-z80 Screen');
  const stream = new ScreenStream(output);
  let panel = null;
  let server = null;
  const showScreen = () => {
    if (panel) {
      panel.show();
    } else {
      panel = new ScreenPanel(stream, () => { panel = null; });
    }
  };
  const listen = () => {
    if (server) {
      server.close();
      server = null;
    }
    const port = settings().port;
    if (port > 0) {
      server = serve(stream, port, output);
    }
  };
  listen();
  const setPaused = (paused) => {
    stream.paused = paused;
    vscode.commands.executeCommand('setContext', 'retroz80.screenPaused', paused);
    stream.update();
  };

  context.subscriptions.push(
    { dispose: () => { stream.dispose(); if (server) { server.close(); } } },
    vscode.commands.registerCommand('retroz80.showScreen', showScreen),
    vscode.commands.registerCommand('retroz80.screenScaling', pickScaling),
    vscode.commands.registerCommand('retroz80.screenPause', () => setPaused(true)),
    vscode.commands.registerCommand('retroz80.screenResume', () => setPaused(false)),
    vscode.commands.registerCommand('retroz80.screenSave', async () => {
      if (!stream.latest) {
        vscode.window.showWarningMessage('No frame from the board yet.');
        return;
      }
      const jpeg = stream.latest.jpeg;
      const folder = vscode.workspace.workspaceFolders ? vscode.workspace.workspaceFolders[0].uri.fsPath : process.cwd();
      const stamp = new Date().toISOString().replace(/[:T]/g, '-').slice(0, 19);
      const uri = await vscode.window.showSaveDialog({ defaultUri: vscode.Uri.file(path.join(folder, `screen-${stamp}.jpg`)),
        filters: { JPEG: ['jpg'] } });
      if (uri) {
        fs.writeFileSync(uri.fsPath, jpeg);
      }
    }),
    vscode.commands.registerCommand('retroz80.screenDevice', async () => {
      const ffmpeg = findFfmpeg(settings().ffmpeg);
      if (!ffmpeg) {
        vscode.window.showErrorMessage('ffmpeg not found: install it (winget install Gyan.FFmpeg) or set retroz80.screen.ffmpeg.');
        return;
      }
      const names = await listDevices(ffmpeg);
      const auto = `Auto-detect (now: ${pickDevice(names) || 'none found'})`;
      const pick = await vscode.window.showQuickPick([auto, ...names], { placeHolder: 'The capture device the board\'s HDMI goes into' });
      if (pick !== undefined) {
        await vscode.workspace.getConfiguration('retroz80.screen').update('device', pick === auto ? '' : pick,
          vscode.ConfigurationTarget.Global);
      }
    }),
    // A debug session on the board brings the screen up, as the emulator's does.
    vscode.debug.onDidStartDebugSession((session) => {
      if (session.type === 'retro-z80' && vscode.workspace.getConfiguration('retroz80.screen').get('showOnDebug', true)) {
        showScreen();
      }
    }),
    vscode.workspace.onDidChangeConfiguration((e) => {
      if (e.affectsConfiguration('retroz80.screen.port')) {
        listen();
      }
      if (e.affectsConfiguration('retroz80.screen.filter') || e.affectsConfiguration('retroz80.screen.scale')) {
        const view = viewSettings();
        for (const v of stream.viewers) {
          v.post({ type: 'view', view });
        }
      }
      if (['device', 'ffmpeg', 'reencode'].some((k) => e.affectsConfiguration('retroz80.screen.' + k))) {
        stream.stop();
        stream.update();
      }
    })
  );
  vscode.commands.executeCommand('setContext', 'retroz80.screenPaused', false);
  return stream;
}

module.exports = { activateScreen, ScreenStream, serve, page };
