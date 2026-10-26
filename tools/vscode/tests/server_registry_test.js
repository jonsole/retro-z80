// Tests for server_registry.js -- finding every running bridge from the
// adverts each one writes. Plain Node, no vscode API and no test framework:
//
//   node tools/vscode/tests/server_registry_test.js
//
// The advert text below is the layout tools/rz80bridge/advert.py writes,
// and tools/test/test_bridge.py holds it to that.

const assert = require('assert');
const path = require('path');
const r = require('../server_registry');

let failures = 0;
function test(name, body) {
  try {
    body();
    console.log('ok   ' + name);
  } catch (err) {
    failures++;
    console.log('FAIL ' + name);
    console.log(err.stack);
  }
}

function advert(pid, fields = {}) {
  return JSON.stringify(Object.assign({
    version: 1,
    pid,
    host: '127.0.0.1',
    ports: { dap: 4780, mcp: 8780, console: 4781 },
    serialPort: 'COM5',
    started: '2026-09-23T17:00:00Z',
    exe: 'C:\\retro-z80\\tools\\rz80_bridge.py',
    cwd: 'C:\\retro-z80',
    program: null
  }, fields));
}

// A directory in memory, and a process table of the pids given as alive.
function fakeIo(files, alivePids) {
  const unlinked = [];
  return {
    unlinked,
    readdir: () => Object.keys(files),
    readFile: (file) => {
      const text = files[path.basename(file)];
      if (text === undefined) {
        throw new Error('ENOENT');
      }
      return text;
    },
    unlink: (file) => unlinked.push(path.basename(file)),
    alive: (pid) => alivePids.includes(pid)
  };
}

test('the directory is where the server writes it', () => {
  assert.strictEqual(
    r.advertDirectory({ env: { LOCALAPPDATA: 'C:\\Users\\me\\AppData\\Local' }, platform: 'win32' }),
    path.join('C:\\Users\\me\\AppData\\Local', 'retro-z80', 'bridges'));
  assert.strictEqual(
    r.advertDirectory({ env: { RZ80_BRIDGE_ADVERT_DIR: '/tmp/adverts', LOCALAPPDATA: 'x' }, platform: 'win32' }),
    '/tmp/adverts');
  assert.strictEqual(
    r.advertDirectory({ env: { XDG_RUNTIME_DIR: '/run/user/1000' }, platform: 'linux', home: '/home/me' }),
    path.join('/run/user/1000', 'retro-z80', 'bridges'));
  assert.strictEqual(
    r.advertDirectory({ env: {}, platform: 'linux', home: '/home/me' }),
    path.join('/home/me', '.cache', 'retro-z80', 'bridges'));
});

test('an advert reads as a bridge, with no MCP as null', () => {
  const server = r.parseAdvert(advert(1234, { program: 'C:\\games\\game.rimg' }));
  assert.deepStrictEqual(server.ports, { dap: 4780, mcp: 8780, console: 4781 });
  assert.strictEqual(server.pid, 1234);
  assert.strictEqual(server.program, 'C:\\games\\game.rimg');
  assert.strictEqual(server.serialPort, 'COM5');
  assert.strictEqual(r.parseAdvert(advert(1, { ports: { dap: 4780, console: 4781, mcp: null } })).ports.mcp, null);
});

test('what cannot be connected to is not a server', () => {
  assert.strictEqual(r.parseAdvert('{not json'), null);
  assert.strictEqual(r.parseAdvert(advert(1, { version: 2 })), null);
  assert.strictEqual(r.parseAdvert(advert(1, { ports: { dap: 0, console: 4781 } })), null);
  assert.strictEqual(r.parseAdvert(advert(1, { ports: { dap: 4780 } })), null);
  assert.strictEqual(r.parseAdvert(advert('12')), null);
});

test('the live servers are listed newest first, and the dead tidied away', () => {
  const io = fakeIo({
    '100.json': advert(100, { started: '2026-09-23T10:00:00Z' }),
    '200.json': advert(200, { started: '2026-09-23T12:00:00Z', ports: { dap: 14780, console: 14781 } }),
    '300.json': advert(300),              // killed: the process is gone
    '400.json.tmp': '{',                   // a dead writer's half-file
    '500.json.tmp': '{',                   // a live one mid-write: left alone
    'notes.txt': 'not an advert'
  }, [100, 200, 500]);
  const servers = r.liveServers('dir', io);
  assert.deepStrictEqual(servers.map((s) => s.pid), [200, 100]);
  assert.deepStrictEqual(io.unlinked.sort(), ['300.json', '400.json.tmp']);
});

test('an advert naming another pid than its file is not believed', () => {
  const io = fakeIo({ '100.json': advert(999) }, [100, 999]);
  assert.deepStrictEqual(r.liveServers('dir', io), []);
});

test('no directory yet is no servers', () => {
  const io = fakeIo({}, []);
  io.readdir = () => {
    throw new Error('ENOENT');
  };
  assert.deepStrictEqual(r.liveServers('dir', io), []);
});

test('a bridge is named by its program, its serial port and its DAP port', () => {
  const server = r.parseAdvert(advert(7, { program: 'C:\\games\\game.rimg' }));
  assert.strictEqual(r.describeServer(server), 'game.rimg on COM5 (:4780)');
  assert.strictEqual(r.describeServer(r.parseAdvert(advert(7))), 'COM5 (:4780)');
  assert.ok(r.detailServer(server).includes('pid 7'));
  assert.ok(r.detailServer(server).includes('console :4781'));
});

test('the same server is the same process, or the same DAP port without one', () => {
  const a = { pid: 5, ports: { dap: 4780 } };
  assert.ok(r.sameServer(a, { pid: 5, ports: { dap: 4780 } }));
  assert.ok(!r.sameServer(a, { pid: 6, ports: { dap: 4780 } }));
  assert.ok(r.sameServer(a, { pid: null, ports: { dap: 4780 } }));
  assert.ok(!r.sameServer(a, undefined));
});

test('a launch\'s "bridgePorts" asks for the settings, a new bridge, or a named one', () => {
  const defaults = { dap: 4780, mcp: 8780, console: 4781 };
  assert.deepStrictEqual(r.launchPorts(undefined, defaults), { request: null });
  assert.deepStrictEqual(r.launchPorts('auto', defaults), { request: { auto: true } });
  assert.deepStrictEqual(r.launchPorts({ dap: 14780, console: 14781 }, defaults),
    { request: { ports: { dap: 14780, mcp: 8780, console: 14781 } } });
  assert.ok(r.launchPorts({ dap: 0 }, defaults).error);
  assert.ok(r.launchPorts('new', defaults).error);
  assert.ok(r.launchPorts([4780], defaults).error);
});

test('serverInfo reads the same as an advert', () => {
  const body = JSON.parse(advert(42, { ports: { dap: 62251, mcp: 62252, console: 62253 } }));
  assert.deepStrictEqual(r.fromServerInfo(body).ports, { dap: 62251, mcp: 62252, console: 62253 });
  assert.strictEqual(r.fromServerInfo(undefined), null);
});

test('a server\'s build version is read, and shown in its detail', () => {
  const server = r.parseAdvert(advert(7, { serverVersion: '0.3.0' }));
  assert.strictEqual(server.version, '0.3.0');
  assert.ok(r.detailServer(server).includes('v0.3.0'));
  assert.strictEqual(r.parseAdvert(advert(7)).version, null);
});

test('a server older than the extension is noticed; -dev is its release\'s equal', () => {
  assert.deepStrictEqual(r.versionNumbers('0.3.1-dev'), [0, 3, 1]);
  assert.strictEqual(r.versionNumbers('dev'), null);
  assert.strictEqual(r.serverIsOlder('0.2.9', '0.3.0'), true);
  assert.strictEqual(r.serverIsOlder('0.2.10', '0.3.0'), true);
  assert.strictEqual(r.serverIsOlder('0.3.0', '0.3.0'), false);
  assert.strictEqual(r.serverIsOlder('0.3.0-dev', '0.3.0'), false);
  assert.strictEqual(r.serverIsOlder('0.10.0', '0.9.0'), false);
  assert.strictEqual(r.serverIsOlder('1.0.0', '0.9.9'), false);
  // No version at all: a server from before versions were reported.
  assert.strictEqual(r.serverIsOlder(null, '0.3.0'), true);
  // Something unreadable is not worth a warning.
  assert.strictEqual(r.serverIsOlder('custom', '0.3.0'), false);
});

if (failures > 0) {
  console.log(`\n${failures} failed`);
  process.exit(1);
}
console.log('\nall passed');
