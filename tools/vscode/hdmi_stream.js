// The board's HDMI output, through a USB capture device: ffmpeg reads the
// device and writes its MJPEG frames to a pipe, untouched (-c:v copy), and
// this splits the pipe into whole JPEGs. No vscode here, so it tests in Node.

'use strict';

const cp = require('child_process');
const fs = require('fs');
const path = require('path');

const SOI = Buffer.from([0xff, 0xd8]);
const MAX_FRAME = 4 * 1024 * 1024;

// Splits a byte stream of back-to-back JPEGs into frames. It walks the
// marker segments by their lengths and scans only the entropy-coded data for
// the next marker, so bytes inside a header never end a frame early.
class JpegSplitter {
  constructor() {
    this.buf = Buffer.alloc(0);
    this.state = 'seek';
    this.pos = 0;
  }

  push(chunk) {
    this.buf = this.buf.length ? Buffer.concat([this.buf, chunk]) : chunk;
    const frames = [];
    for (;;) {
      const b = this.buf;
      if (b.length > MAX_FRAME) {
        this.buf = Buffer.alloc(0);
        this.state = 'seek';
        return frames;
      }
      if (this.state === 'seek') {
        const i = b.indexOf(SOI);
        if (i < 0) {
          this.buf = b.subarray(Math.max(0, b.length - 1));
          return frames;
        }
        this.buf = b.subarray(i);
        this.pos = 2;
        this.state = 'segment';
        continue;
      }
      if (this.state === 'segment') {
        const p = this.pos;
        if (p + 2 > b.length) {
          return frames;
        }
        if (b[p] !== 0xff) {
          this.buf = b.subarray(1); // lost: find the next frame
          this.state = 'seek';
          continue;
        }
        const m = b[p + 1];
        if (m === 0xff) {
          this.pos++; // a fill byte
        } else if (m === 0xd9) {
          frames.push(Buffer.from(b.subarray(0, p + 2)));
          this.buf = b.subarray(p + 2);
          this.state = 'seek';
        } else if (m === 0x01 || (m >= 0xd0 && m <= 0xd7)) {
          this.pos += 2;
        } else {
          if (p + 4 > b.length) {
            return frames;
          }
          const next = p + 2 + b.readUInt16BE(p + 2);
          if (next > b.length) {
            return frames;
          }
          this.pos = next;
          if (m === 0xda) {
            this.state = 'entropy';
          }
        }
        continue;
      }
      // Entropy-coded data: 0xFF is followed by 0x00 (a stuffed byte), a
      // restart marker or a fill byte, or else it starts the next marker.
      let p = this.pos;
      for (;;) {
        p = b.indexOf(0xff, p);
        if (p < 0 || p + 1 >= b.length) {
          this.pos = p < 0 ? b.length : p;
          return frames;
        }
        const n = b[p + 1];
        if (n === 0x00 || (n >= 0xd0 && n <= 0xd7)) {
          p += 2;
        } else if (n === 0xff) {
          p++;
        } else {
          break;
        }
      }
      this.pos = p;
      this.state = 'segment';
    }
  }
}

// The width and height in a JPEG's start-of-frame segment, or null.
function jpegSize(jpeg) {
  let p = 2;
  while (p + 4 <= jpeg.length && jpeg[p] === 0xff) {
    const m = jpeg[p + 1];
    if (m >= 0xc0 && m <= 0xcf && m !== 0xc4 && m !== 0xc8 && m !== 0xcc) {
      return p + 9 <= jpeg.length ? { width: jpeg.readUInt16BE(p + 7), height: jpeg.readUInt16BE(p + 5) } : null;
    }
    p += 2 + jpeg.readUInt16BE(p + 2);
  }
  return null;
}

// Where ffmpeg is: the setting, the PATH, then (on Windows) where winget,
// Chocolatey and Scoop put it. null if nowhere.
function findFfmpeg(setting, env = process.env, platform = process.platform, exists = fs.existsSync,
  readdir = (d) => fs.readdirSync(d)) {
  if (setting) {
    return setting;
  }
  const exe = platform === 'win32' ? 'ffmpeg.exe' : 'ffmpeg';
  const sep = platform === 'win32' ? ';' : ':';
  const candidates = (env.PATH || env.Path || '').split(sep).filter(Boolean).map((d) => path.join(d, exe));
  if (platform === 'win32') {
    const local = env.LOCALAPPDATA || '';
    const packages = path.join(local, 'Microsoft', 'WinGet', 'Packages');
    candidates.push(path.join(local, 'Microsoft', 'WinGet', 'Links', exe));
    try {
      for (const pkg of readdir(packages).filter((n) => /ffmpeg/i.test(n))) {
        candidates.push(path.join(packages, pkg, 'bin', exe));
        try {
          for (const inner of readdir(path.join(packages, pkg))) {
            candidates.push(path.join(packages, pkg, inner, 'bin', exe));
          }
        } catch (err) {
          // not a folder
        }
      }
    } catch (err) {
      // no winget packages
    }
    candidates.push(path.join(env.ProgramData || 'C:\\ProgramData', 'chocolatey', 'bin', exe));
    candidates.push(path.join(env.USERPROFILE || '', 'scoop', 'shims', exe));
  }
  return candidates.find((c) => exists(c)) || null;
}

// ffmpeg's input for a capture device on this platform.
function inputArgs(device, platform = process.platform) {
  if (platform === 'win32') {
    return ['-f', 'dshow', '-rtbufsize', '32M', '-i', 'video=' + device];
  }
  if (platform === 'darwin') {
    return ['-f', 'avfoundation', '-i', device];
  }
  return ['-f', 'v4l2', '-input_format', 'mjpeg', '-i', device];
}

// The whole ffmpeg command line: MJPEG frames on stdout. reencode is for a
// device that does not send MJPEG itself.
function ffmpegArgs(device, reencode = false, platform = process.platform) {
  return ['-hide_banner', '-loglevel', 'error', '-fflags', 'nobuffer', ...inputArgs(device, platform),
    '-an', ...(reencode ? ['-c:v', 'mjpeg', '-q:v', '4'] : ['-c:v', 'copy']), '-f', 'mjpeg', 'pipe:1'];
}

// The video devices in `ffmpeg -list_devices true -f dshow -i dummy`'s output.
function parseDshowDevices(text) {
  const names = [];
  for (const line of text.split(/\r?\n/)) {
    const m = /"([^"]+)"\s+\(video\)/.exec(line);
    if (m) {
      names.push(m[1]);
    }
  }
  return names;
}

// The capture device to use when none is set: one whose name says capture
// or HDMI, else the first.
function pickDevice(names) {
  return names.find((n) => /capture|hdmi|cam link/i.test(n)) || names[0] || null;
}

function listDevices(ffmpeg, platform = process.platform) {
  return new Promise((resolve) => {
    if (platform !== 'win32') {
      resolve(platform === 'darwin' ? ['0'] : ['/dev/video0']);
      return;
    }
    cp.execFile(ffmpeg, ['-hide_banner', '-list_devices', 'true', '-f', 'dshow', '-i', 'dummy'],
      { windowsHide: true, timeout: 10000 }, (err, stdout, stderr) => resolve(parseDshowDevices(stdout + stderr)));
  });
}

module.exports = { JpegSplitter, jpegSize, findFfmpeg, inputArgs, ffmpegArgs, parseDshowDevices, pickDevice, listDevices };
