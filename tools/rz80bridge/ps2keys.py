"""PC keys as PS/2 scan code set 2 bytes, for the KEY control command
(ticket #44; serial spec, section 4; input spec, section 3): what a PS/2
keyboard would send as a key goes down (make) and comes up (break: F0, with
E0 first for the extended keys).

A key is named by the browser's KeyboardEvent.code ("KeyA", "ShiftLeft",
"ArrowUp"), which the Board Screen tab passes on as it is, or by a plain
name: "A", "5", "ENTER", "SPACE", "SHIFT", "CTRL", "ALT", "ESC", "UP",
"F1", "," and so on (case does not matter). type_text() turns text into
key presses on a US layout.
"""

# KeyboardEvent.code -> (extended, code)
CODES = {}
for _letter, _code in zip("ABCDEFGHIJKLMNOPQRSTUVWXYZ",
                          [0x1C, 0x32, 0x21, 0x23, 0x24, 0x2B, 0x34, 0x33, 0x43, 0x3B, 0x42, 0x4B, 0x3A,
                           0x31, 0x44, 0x4D, 0x15, 0x2D, 0x1B, 0x2C, 0x3C, 0x2A, 0x1D, 0x22, 0x35, 0x1A]):
    CODES["Key" + _letter] = (False, _code)
for _digit, _code in zip("1234567890", [0x16, 0x1E, 0x26, 0x25, 0x2E, 0x36, 0x3D, 0x3E, 0x46, 0x45]):
    CODES["Digit" + _digit] = (False, _code)
for _n, _code in zip(range(1, 13), [0x05, 0x06, 0x04, 0x0C, 0x03, 0x0B, 0x83, 0x0A, 0x01, 0x09, 0x78, 0x07]):
    CODES["F%d" % _n] = (False, _code)
for _n, _code in zip(range(10), [0x70, 0x69, 0x72, 0x7A, 0x6B, 0x73, 0x74, 0x6C, 0x75, 0x7D]):
    CODES["Numpad%d" % _n] = (False, _code)
CODES.update({
    "Backquote": (False, 0x0E), "Minus": (False, 0x4E), "Equal": (False, 0x55), "Backspace": (False, 0x66),
    "Tab": (False, 0x0D), "BracketLeft": (False, 0x54), "BracketRight": (False, 0x5B),
    "Backslash": (False, 0x5D), "CapsLock": (False, 0x58), "Semicolon": (False, 0x4C), "Quote": (False, 0x52),
    "Enter": (False, 0x5A), "ShiftLeft": (False, 0x12), "Comma": (False, 0x41), "Period": (False, 0x49),
    "Slash": (False, 0x4A), "ShiftRight": (False, 0x59), "ControlLeft": (False, 0x14), "AltLeft": (False, 0x11),
    "Space": (False, 0x29), "IntlBackslash": (False, 0x61), "Escape": (False, 0x76),
    "ScrollLock": (False, 0x7E), "NumLock": (False, 0x77), "NumpadMultiply": (False, 0x7C),
    "NumpadSubtract": (False, 0x7B), "NumpadAdd": (False, 0x79), "NumpadDecimal": (False, 0x71),
    "AltRight": (True, 0x11), "ControlRight": (True, 0x14), "MetaLeft": (True, 0x1F), "MetaRight": (True, 0x27),
    "ContextMenu": (True, 0x2F), "Insert": (True, 0x70), "Home": (True, 0x6C), "PageUp": (True, 0x7D),
    "Delete": (True, 0x71), "End": (True, 0x69), "PageDown": (True, 0x7A), "ArrowUp": (True, 0x75),
    "ArrowLeft": (True, 0x6B), "ArrowDown": (True, 0x72), "ArrowRight": (True, 0x74),
    "NumpadDivide": (True, 0x4A), "NumpadEnter": (True, 0x5A),
})

# plain names (upper case) -> KeyboardEvent.code
ALIASES = {k.upper(): k for k in CODES}
ALIASES.update({c: "Key" + c for c in "ABCDEFGHIJKLMNOPQRSTUVWXYZ"})
ALIASES.update({c: "Digit" + c for c in "0123456789"})
ALIASES.update({
    "ENTER": "Enter", "RETURN": "Enter", "SPACE": "Space", " ": "Space", "SHIFT": "ShiftLeft",
    "LSHIFT": "ShiftLeft", "RSHIFT": "ShiftRight", "CTRL": "ControlLeft", "CONTROL": "ControlLeft",
    "RCTRL": "ControlRight", "ALT": "AltLeft", "RALT": "AltRight", "ALTGR": "AltRight", "ESC": "Escape",
    "UP": "ArrowUp", "DOWN": "ArrowDown", "LEFT": "ArrowLeft", "RIGHT": "ArrowRight", "BACKSPACE": "Backspace",
    "DEL": "Delete", "INS": "Insert", "PGUP": "PageUp", "PGDN": "PageDown", "CAPS": "CapsLock",
    "WIN": "MetaLeft", "MENU": "ContextMenu",
    "`": "Backquote", "-": "Minus", "=": "Equal", "[": "BracketLeft", "]": "BracketRight", "\\": "Backslash",
    ";": "Semicolon", "'": "Quote", ",": "Comma", ".": "Period", "/": "Slash",
})

# text on a US layout: character -> (code, shifted)
TYPED = {}
for _c in "abcdefghijklmnopqrstuvwxyz":
    TYPED[_c] = ("Key" + _c.upper(), False)
    TYPED[_c.upper()] = ("Key" + _c.upper(), True)
for _plain, _shifted, _code in zip("1234567890`-=[]\\;',./", "!@#$%^&*()~_+{}|:\"<>?",
                                   ["Digit%s" % d for d in "1234567890"] +
                                   ["Backquote", "Minus", "Equal", "BracketLeft", "BracketRight", "Backslash",
                                    "Semicolon", "Quote", "Comma", "Period", "Slash"]):
    TYPED[_plain] = (_code, False)
    TYPED[_shifted] = (_code, True)
TYPED.update({" ": ("Space", False), "\n": ("Enter", False), "\r": ("Enter", False), "\t": ("Tab", False),
              "\b": ("Backspace", False), "\x1b": ("Escape", False)})


def lookup(name):
    """A key's KeyboardEvent.code, from that code or a plain name. ValueError if unknown."""
    if name in CODES:
        return name
    code = ALIASES.get(str(name).upper())
    if code is None:
        raise ValueError("no such key: %r (a KeyboardEvent.code such as KeyA, or a name such as A, ENTER, "
                         "SHIFT, UP, F1)" % name)
    return code


def make(name):
    ext, code = CODES[lookup(name)]
    return bytes([0xE0, code]) if ext else bytes([code])


def brk(name):
    ext, code = CODES[lookup(name)]
    return bytes([0xE0, 0xF0, code]) if ext else bytes([0xF0, code])


def type_text(text):
    """Typing text: per character, (down, up, character), the bytes for its
    keys going down (Shift first for a shifted one) and coming up."""
    steps = []
    for ch in text:
        if ch not in TYPED:
            raise ValueError("cannot type %r on a US layout" % ch)
        code, shifted = TYPED[ch]
        down = (make("ShiftLeft") if shifted else b"") + make(code)
        up = brk(code) + (brk("ShiftLeft") if shifted else b"")
        steps.append((down, up, ch))
    return steps
