"""Synthetic keyboard / mouse input, shared by the virtual keyboard and the gamepad mouse.

X11: XTest (libXtst through ctypes), straight to the X server, no process spawned per event.
Wayland: ydotool (needs its ydotoold service), one process per call, so callers batch.

Codes are Linux evdev key codes (linux/input-event-codes.h): the PHYSICAL key, so what is typed
depends on the user's keyboard layout, exactly as with a real keyboard. X keycodes are evdev + 8.

Tests: with LPM_INJECT_LOG=<file> nothing is sent, every event is appended to the file instead.
"""

import ctypes
import os
import shutil
import subprocess
import time

BTN_LEFT, BTN_MIDDLE, BTN_RIGHT = 1, 2, 3  # X11 button numbers; wheel up/down = 4/5
# ydotool "click" codes: 0x40 = press, 0x80 = release, low bits = button (0 left, 1 right, 2 middle)
_YDO_BUTTON = {BTN_LEFT: 0, BTN_RIGHT: 1, BTN_MIDDLE: 2}


class Injector:
    def __init__(self, session_kind):
        self.session = session_kind
        self.log_path = os.environ.get("LPM_INJECT_LOG", "")
        self._x = None
        self._x_tried = False

    # --- helpers -------------------------------------------------------------------------
    def _log(self, text):
        with open(self.log_path, "a", encoding="utf-8") as f:
            f.write(text + "\n")

    def _xtest(self):
        """(libX11, libXtst, display) or None."""
        if self._x_tried:
            return self._x
        self._x_tried = True
        if self.session != "x11":
            return None
        try:
            x11 = ctypes.CDLL("libX11.so.6")
            xtst = ctypes.CDLL("libXtst.so.6")
            x11.XOpenDisplay.restype = ctypes.c_void_p
            x11.XOpenDisplay.argtypes = [ctypes.c_char_p]
            x11.XFlush.argtypes = [ctypes.c_void_p]
            xtst.XTestFakeKeyEvent.argtypes = [ctypes.c_void_p, ctypes.c_uint, ctypes.c_int, ctypes.c_ulong]
            xtst.XTestFakeButtonEvent.argtypes = [ctypes.c_void_p, ctypes.c_uint, ctypes.c_int, ctypes.c_ulong]
            xtst.XTestFakeRelativeMotionEvent.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_int, ctypes.c_ulong]
            display = x11.XOpenDisplay(None)
            if display:
                self._x = (x11, xtst, ctypes.c_void_p(display))
        except Exception:
            self._x = None
        return self._x

    @staticmethod
    def _ydotool(*args):
        if not shutil.which("ydotool"):
            return
        try:
            subprocess.run(["ydotool", *[str(a) for a in args]], check=False,
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=5)
        except Exception:
            pass  # best-effort: a missed event must never crash the caller

    # --- keyboard ------------------------------------------------------------------------
    def hold(self, codes, seconds=0.15):
        """Like tap(), but keeps the keys down for `seconds` before releasing them. For programs that
        poll the keyboard state (MangoHud checks it about once per frame): a press and release
        in the same instant is never seen by them."""
        codes = list(codes)
        if self.log_path:
            self._log("hold " + " ".join(str(c) for c in codes))
            return
        x = self._xtest()
        if x:
            x11, xtst, display = x
            for code in codes:
                xtst.XTestFakeKeyEvent(display, code + 8, 1, 0)
            x11.XFlush(display)
            time.sleep(seconds)
            for code in reversed(codes):
                xtst.XTestFakeKeyEvent(display, code + 8, 0, 0)
            x11.XFlush(display)
        else:
            self._ydotool("key", "--key-delay", int(seconds * 1000), *["%d:1" % c for c in codes],
                          *["%d:0" % c for c in reversed(codes)])

    def tap(self, codes):
        """Press every code in order, then release them in reverse order (e.g. [42, 30] = Shift+A).
        One call, so on Wayland it is a single ydotool process."""
        codes = list(codes)
        if self.log_path:
            self._log("tap " + " ".join(str(c) for c in codes))
            return
        x = self._xtest()
        if x:
            x11, xtst, display = x
            for code in codes:
                xtst.XTestFakeKeyEvent(display, code + 8, 1, 0)
            for code in reversed(codes):
                xtst.XTestFakeKeyEvent(display, code + 8, 0, 0)
            x11.XFlush(display)
        else:
            seq = ["%d:1" % c for c in codes] + ["%d:0" % c for c in reversed(codes)]
            self._ydotool("key", *seq)

    # --- mouse ---------------------------------------------------------------------------
    def move(self, dx, dy):
        if not dx and not dy:
            return
        if self.log_path:
            self._log("move %d %d" % (dx, dy))
            return
        x = self._xtest()
        if x:
            x11, xtst, display = x
            xtst.XTestFakeRelativeMotionEvent(display, int(dx), int(dy), 0)
            x11.XFlush(display)
        else:
            self._ydotool("mousemove", "-x", int(dx), "-y", int(dy))

    def button(self, button, down):
        """button: BTN_LEFT / BTN_MIDDLE / BTN_RIGHT."""
        if self.log_path:
            self._log("button %d %s" % (button, "down" if down else "up"))
            return
        x = self._xtest()
        if x:
            x11, xtst, display = x
            xtst.XTestFakeButtonEvent(display, button, int(down), 0)
            x11.XFlush(display)
        else:
            self._ydotool("click", "0x%02X" % ((0x40 if down else 0x80) | _YDO_BUTTON[button]))

    def wheel(self, direction):
        """-1 = scroll up, 1 = scroll down (one notch)."""
        if self.log_path:
            self._log("wheel %d" % direction)
            return
        x = self._xtest()
        if x:
            x11, xtst, display = x
            number = 4 if direction < 0 else 5
            xtst.XTestFakeButtonEvent(display, number, 1, 0)
            xtst.XTestFakeButtonEvent(display, number, 0, 0)
            x11.XFlush(display)
        else:
            self._ydotool("mousemove", "--wheel", "-x", 0, "-y", direction)
