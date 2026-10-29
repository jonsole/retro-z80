"""The board's HDMI output, through a USB capture device, for the MCP tools
screen_capture and screen_record.

A capture device opens for one program at a time. While VS Code's Board
Screen view streams, the extension holds it and serves its frames on
http://127.0.0.1:4790 (RZ80_SCREEN_PORT): /frame.jpg, the latest frame, and
/record?ms=N, the frames of the next N ms (see _unpack); /device, the
device it uses. Otherwise ffmpeg reads the device here. The device sends
MJPEG, so frames are passed on as they come (-c:v copy).

    environment: RZ80_FFMPEG (ffmpeg's path), RZ80_SCREEN_DEVICE (the
    capture device's name; left out, VS Code's retroz80.screen.device, else
    one whose name says capture or HDMI)
"""

import glob
import os
import re
import shutil
import struct
import subprocess
import sys
import time
import urllib.error
import urllib.request

HOST = "127.0.0.1"
VIEW_PORT = int(os.environ.get("RZ80_SCREEN_PORT", "4790"))
WARMUP_FRAMES = 10  # a device just opened can give a stale frame or two first


class ScreenError(Exception):
    pass


def split_jpegs(data):
    """Back-to-back JPEGs -> a list of them. Walks the marker segments by
    their lengths and scans only entropy-coded data for markers."""
    frames, i, n = [], 0, len(data)
    while True:
        start = data.find(b"\xff\xd8", i)
        if start < 0:
            return frames
        p = start + 2
        end = None
        while p + 2 <= n:
            if data[p] != 0xFF:
                break
            m = data[p + 1]
            if m == 0xFF:
                p += 1
            elif m == 0xD9:
                end = p + 2
                break
            elif m == 0x01 or 0xD0 <= m <= 0xD7:
                p += 2
            else:
                if p + 4 > n:
                    break
                p += 2 + struct.unpack(">H", data[p + 2:p + 4])[0]
                if m == 0xDA:
                    while True:
                        p = data.find(b"\xff", p)
                        if p < 0 or p + 1 >= n:
                            p = n
                            break
                        q = data[p + 1]
                        if q == 0x00 or 0xD0 <= q <= 0xD7:
                            p += 2
                        elif q == 0xFF:
                            p += 1
                        else:
                            break
        if end is None:
            i = start + 2
            continue
        frames.append(data[start:end])
        i = end


def jpeg_size(jpeg):
    """(width, height) from a JPEG's start-of-frame segment, or None."""
    p = 2
    while p + 4 <= len(jpeg) and jpeg[p] == 0xFF:
        m = jpeg[p + 1]
        if 0xC0 <= m <= 0xCF and m not in (0xC4, 0xC8, 0xCC):
            h, w = struct.unpack(">HH", jpeg[p + 5:p + 9])
            return w, h
        p += 2 + struct.unpack(">H", jpeg[p + 2:p + 4])[0]
    return None


def find_ffmpeg():
    exe = os.environ.get("RZ80_FFMPEG") or shutil.which("ffmpeg")
    if exe:
        return exe
    if sys.platform == "win32":
        local = os.environ.get("LOCALAPPDATA", "")
        for pattern in (r"Microsoft\WinGet\Links\ffmpeg.exe", r"Microsoft\WinGet\Packages\*ffmpeg*\bin\ffmpeg.exe",
                        r"Microsoft\WinGet\Packages\*ffmpeg*\*\bin\ffmpeg.exe"):
            hits = sorted(glob.glob(os.path.join(local, pattern)), reverse=True)  # case-blind on Windows
            if hits:
                return hits[0]
    raise ScreenError("ffmpeg not found: put it on the PATH or set RZ80_FFMPEG")


def input_args(device):
    if sys.platform == "win32":
        return ["-f", "dshow", "-rtbufsize", "32M", "-i", "video=" + device]
    if sys.platform == "darwin":
        return ["-f", "avfoundation", "-i", device]
    return ["-f", "v4l2", "-input_format", "mjpeg", "-i", device]


def parse_dshow_devices(text):
    return re.findall(r'"([^"]+)"\s+\(video\)', text)


def pick_device(names):
    for n in names:
        if re.search(r"capture|hdmi|cam link", n, re.I):
            return n
    return names[0] if names else None


def find_device(ffmpeg):
    """RZ80_SCREEN_DEVICE, else the VS Code setting retroz80.screen.device (the
    extension answers /device while VS Code runs), else auto-detected."""
    if os.environ.get("RZ80_SCREEN_DEVICE"):
        return os.environ["RZ80_SCREEN_DEVICE"]
    named = _from_view("/device", 1)
    if named:
        return named.decode("utf-8")
    if sys.platform != "win32":
        return "0" if sys.platform == "darwin" else "/dev/video0"
    r = subprocess.run([ffmpeg, "-hide_banner", "-list_devices", "true", "-f", "dshow", "-i", "dummy"],
                       capture_output=True, text=True, timeout=15)
    device = pick_device(parse_dshow_devices(r.stdout + r.stderr))
    if not device:
        raise ScreenError("no video capture device found: is the HDMI capture device plugged in?")
    return device


def _from_view(path, timeout):
    """The extension's answer, or None if it is not streaming."""
    try:
        with urllib.request.urlopen("http://%s:%d%s" % (HOST, VIEW_PORT, path), timeout=timeout) as r:
            return r.read()
    except (urllib.error.URLError, OSError):
        return None


def _unpack(data):
    """/record's answer: per frame, its time in ms (a big-endian double), its
    length (4 bytes, big-endian) and the JPEG."""
    frames, p = [], 0
    while p + 12 <= len(data):
        ms, n = struct.unpack(">dI", data[p:p + 12])
        frames.append((ms / 1000.0, data[p + 12:p + 12 + n]))
        p += 12 + n
    return frames


_device = None


def _open():
    """ffmpeg reading the device, MJPEG frames on its stdout."""
    global _device
    ffmpeg = find_ffmpeg()
    if _device is None or os.environ.get("RZ80_SCREEN_DEVICE"):
        _device = find_device(ffmpeg)
    args = [ffmpeg, "-hide_banner", "-loglevel", "error", "-fflags", "nobuffer"] + input_args(_device) +         ["-an", "-c:v", "copy", "-f", "mjpeg", "pipe:1"]
    return subprocess.Popen(args, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE)


def _read_frames(seconds, count=None):
    """Frames from ffmpeg, each with its arrival time, after the warm-up:
    for seconds of wall-clock time, or until count frames."""
    global _device
    p = _open()
    buf, got, t0, deadline = b"", [], None, time.time() + seconds + 15
    try:
        while time.time() < deadline:
            chunk = p.stdout.read1(65536) if hasattr(p.stdout, "read1") else p.stdout.read(65536)
            if not chunk:
                break
            buf += chunk
            frames = split_jpegs(buf)
            if frames:
                buf = buf[buf.rfind(frames[-1]) + len(frames[-1]):]
            now = time.time()
            for f in frames:
                got.append((now, f))
                if len(got) == WARMUP_FRAMES:
                    t0 = now
            if len(got) > WARMUP_FRAMES and (now - t0 >= seconds or (count and len(got) >= WARMUP_FRAMES + count)):
                break
    finally:
        p.kill()
        err = p.stderr.read().decode("utf-8", "replace").strip().splitlines()
        p.wait()
    kept = got[WARMUP_FRAMES:] if t0 is not None else got[-1:]
    if not kept:
        _device = None  # look again next time: unplugged, or another device
        raise ScreenError("no frames from the capture device: %s" % (
            err[-1] if err else "ffmpeg gave nothing (is the device in use by another program?)"))
    return [(t - kept[0][0], f) for t, f in kept]


def capture():
    """The screen now: (jpeg, where it came from)."""
    jpeg = _from_view("/frame.jpg", 3)
    if jpeg:
        return jpeg, "the VS Code view's stream"
    return _read_frames(0, count=1)[-1][1], "ffmpeg"


def record(seconds):
    """The frames of the next few seconds: (list of (time, jpeg), fps, where from)."""
    data = _from_view("/record?ms=%d" % int(seconds * 1000), seconds + 5)
    if data:
        frames = _unpack(data)
        source = "the VS Code view's stream"
    else:
        frames = _read_frames(seconds)
        source = "ffmpeg"
    span = frames[-1][0] - frames[0][0] if len(frames) > 1 else 0
    return frames, (len(frames) - 1) / span if span > 0 else 0, source


def save_sequence(frames, fps, path):
    """Write frames to path: .mjpeg as they are, a folder of numbered JPEGs if
    path ends with a slash or is a folder, else whatever ffmpeg makes of the
    extension (.avi and .mkv keep the JPEGs; .mp4 and .gif re-encode)."""
    if path.endswith(("/", "\\")) or os.path.isdir(path):
        os.makedirs(path, exist_ok=True)
        for i, f in enumerate(frames):
            with open(os.path.join(path, "frame%04d.jpg" % i), "wb") as out:
                out.write(f)
        return
    frames = [f for _, f in frames]
    data = b"".join(frames)
    if path.lower().endswith((".mjpeg", ".mjpg")):
        with open(path, "wb") as out:
            out.write(data)
        return
    codec = ["-c:v", "copy"] if path.lower().endswith((".avi", ".mkv", ".mov")) else []
    if path.lower().endswith(".mp4"):
        codec = ["-pix_fmt", "yuv420p"]
    r = subprocess.run([find_ffmpeg(), "-hide_banner", "-loglevel", "error", "-y", "-framerate", "%.3f" % fps,
                        "-f", "mjpeg", "-i", "pipe:0"] + codec + [path], input=data, capture_output=True, timeout=120)
    if r.returncode != 0:
        raise ScreenError("ffmpeg could not write %s: %s" % (path, r.stderr.decode("utf-8", "replace").strip()))
