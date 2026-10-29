// hdmi_stream.js: the JPEG splitter, ffmpeg's command line and the device
// list, with no capture device.
//
//   node tools/vscode/tests/hdmi_stream_test.js

'use strict';

const assert = require('assert');
const path = require('path');
const { test, done } = require('./harness');
const { JpegSplitter, jpegSize, findFfmpeg, ffmpegArgs, parseDshowDevices, pickDevice } = require('../hdmi_stream');

// A small JPEG-shaped frame: SOI, an APP0 whose payload holds FF D9 (which
// must not end the frame), SOF0 with its size, SOS, entropy data with a
// stuffed FF 00 and a restart marker, EOI.
function frame(width, height, fill) {
  const seg = (m, body) => Buffer.concat([Buffer.from([0xff, m, (body.length + 2) >> 8, (body.length + 2) & 0xff]), body]);
  const sof = Buffer.from([8, height >> 8, height & 0xff, width >> 8, width & 0xff, 1, 1, 0x11, 0]);
  return Buffer.concat([Buffer.from([0xff, 0xd8]), seg(0xe0, Buffer.from([0x4a, 0xff, 0xd9, 0x00])), seg(0xc0, sof),
    seg(0xda, Buffer.from([1, 1, 0, 0, 63, 0])), Buffer.from([fill, 0xff, 0x00, fill, 0xff, 0xd3, fill]),
    Buffer.from([0xff, 0xd9])]);
}

test('whole frames come out whole, header bytes and stuffing ignored', () => {
  const a = frame(720, 576, 1);
  const b = frame(720, 480, 2);
  const s = new JpegSplitter();
  const out = s.push(Buffer.concat([Buffer.from('junk'), a, b]));
  assert.deepStrictEqual(out, [a, b]);
});

test('frames split across chunks at every byte', () => {
  const a = frame(720, 576, 1);
  const b = frame(320, 200, 7);
  const all = Buffer.concat([a, b, a]);
  for (let cut = 1; cut < all.length; cut++) {
    const s = new JpegSplitter();
    const out = [...s.push(all.subarray(0, cut)), ...s.push(all.subarray(cut))];
    assert.deepStrictEqual(out, [a, b, a], `cut at ${cut}`);
  }
});

test('a frame byte by byte', () => {
  const a = frame(16, 16, 3);
  const s = new JpegSplitter();
  const out = [];
  for (const byte of a) {
    out.push(...s.push(Buffer.from([byte])));
  }
  assert.deepStrictEqual(out, [a]);
});

test('jpegSize reads the start of frame', () => {
  assert.deepStrictEqual(jpegSize(frame(720, 576, 0)), { width: 720, height: 576 });
  assert.strictEqual(jpegSize(Buffer.from([0xff, 0xd8])), null);
});

test('ffmpeg is the setting, else on the PATH, else winget\'s', () => {
  assert.strictEqual(findFfmpeg('/opt/ffmpeg'), '/opt/ffmpeg');
  const onPath = path.join('/opt/bin', 'ffmpeg');
  assert.strictEqual(findFfmpeg('', { PATH: '/usr/bin:/opt/bin' }, 'linux', (p) => p === onPath), onPath);
  const winget = path.join('L', 'Microsoft', 'WinGet', 'Packages', 'Gyan.FFmpeg_x', 'ffmpeg-9-full', 'bin', 'ffmpeg.exe');
  const readdir = (d) => (d.endsWith('Packages') ? ['Other', 'Gyan.FFmpeg_x'] : ['ffmpeg-9-full']);
  assert.strictEqual(findFfmpeg('', { PATH: '', LOCALAPPDATA: 'L' }, 'win32', (p) => p === winget, readdir), winget);
  assert.strictEqual(findFfmpeg('', { PATH: '' }, 'linux', () => false), null);
});

test('ffmpeg copies the device\'s MJPEG to stdout', () => {
  const a = ffmpegArgs('USB3.0 HD Video Capture', false, 'win32');
  assert.deepStrictEqual(a.slice(a.indexOf('-f')), ['-f', 'dshow', '-rtbufsize', '32M', '-i', 'video=USB3.0 HD Video Capture',
    '-an', '-c:v', 'copy', '-f', 'mjpeg', 'pipe:1']);
  assert.ok(ffmpegArgs('/dev/video0', true, 'linux').join(' ').includes('-f v4l2 -input_format mjpeg -i /dev/video0 -an -c:v mjpeg'));
});

test('the device list, and the pick when none is set', () => {
  const text = '[in#0 @ 1] "Integrated Camera" (video)\n[in#0 @ 1]   Alternative name "@device_pnp_x"\n' +
    '[in#0 @ 1] "USB3.0 HD Video Capture" (video)\n[in#0 @ 1] "Microphone (USB3.0 HD Audio Capture)" (audio)\n';
  const names = parseDshowDevices(text);
  assert.deepStrictEqual(names, ['Integrated Camera', 'USB3.0 HD Video Capture']);
  assert.strictEqual(pickDevice(names), 'USB3.0 HD Video Capture');
  assert.strictEqual(pickDevice(['Integrated Camera']), 'Integrated Camera');
  assert.strictEqual(pickDevice([]), null);
});

done();
