#!/usr/bin/env python3
# --- lpm launcher: on-screen keyboard driven by the gamepad (or mouse), over the game -- GTK4 ---
#
# Usage: zgu-virtual-keyboard.py <x11|wayland> <prefix_folder>
#
# Opened (and closed again) from the LPM menu ("Virtual keyboard") or with L1+L2+R1+R2+R3 held then D-pad down
# (zgu-gamepad-exit-watcher.py). Stays open until closed (Select, the close key, Esc on a real
# keyboard, a click outside the card, or the end of the game).
#
# KEY LAYOUT: the keys are PHYSICAL positions (evdev codes); the label of each one comes from the
# keyboard layout the desktop is using right now (Gdk.Display.map_keycode: AZERTY, QWERTZ,
# Dvorak..., X11 AND Wayland: GTK receives the layout from the display server). Pressing a key
# sends that physical key (plus Shift / AltGr when selected), so what is typed is exactly what the
# label says. If GTK cannot tell the layout, a US layout is shown and a notice says so.
#
# SENDING A KEY: keys go to the window that has the focus. On X11 the keyboard is a window that never
# takes the focus (keyboard_mode=auto), so the game keeps it and the key is sent at once. Otherwise (Wayland,
# or keyboard_mode=hide) for each key the keyboard hides
# itself (the game gets the focus back), waits keyboard_delay_ms (menu.conf, default 50), sends the
# key, and shows itself again IMMEDIATELY. Same method on X11 and Wayland.
#
# Gamepad (SDL2, read here): D-pad / left stick move, A types the key, B Backspace, X Space,
# Y Shift (held 0.6 s: shift lock), Start Enter, L1 / R1 cursor left / right, Select closes.

import fcntl
import importlib.util
import os
import signal
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from zgu_common import (  # noqa: E402
    GAMEPAD_AXIS_THRESHOLD,
    GAMEPAD_POLL_MS,
    SDL_CONTROLLER_AXIS_LEFTX,
    SDL_CONTROLLER_AXIS_LEFTY,
    SDL_CONTROLLER_BUTTON_A,
    SDL_CONTROLLER_BUTTON_B,
    SDL_CONTROLLER_BUTTON_BACK,
    SDL_CONTROLLER_BUTTON_DPAD_DOWN,
    SDL_CONTROLLER_BUTTON_DPAD_LEFT,
    SDL_CONTROLLER_BUTTON_DPAD_RIGHT,
    SDL_CONTROLLER_BUTTON_DPAD_UP,
    SDL_CONTROLLER_BUTTON_LEFTSHOULDER,
    SDL_CONTROLLER_BUTTON_RIGHTSHOULDER,
    SDL_CONTROLLER_BUTTON_START,
    SDL_CONTROLLER_BUTTON_X,
    SDL_CONTROLLER_BUTTON_Y,
    init_sdl,
    load_menu_conf,
    load_sdl2,
    sync_controllers,
)
from zgu_inject import Injector  # noqa: E402

try:
    import gi
    gi.require_version("Gtk", "4.0")
    from gi.repository import Gtk, Gdk, GLib
    from zgu_overlay import x11_focus_window, x11_restore_focus, x11_set_hints, x11_xid, xwayland_available, place_on_x11, pointer_monitor, use_veil
except Exception as exc:  # pragma: no cover - system dependency missing
    sys.stderr.write("zgu-virtual-keyboard: GTK4/PyGObject unavailable (%s)\n" % exc)
    sys.exit(1)

if len(sys.argv) < 3 or sys.argv[1] not in ("x11", "wayland") or not sys.argv[2]:
    sys.stderr.write("Usage: zgu-virtual-keyboard.py <x11|wayland> <prefix_folder>\n")
    sys.exit(1)

SESSION_KIND = sys.argv[1]
PREFIX_DIR = sys.argv[2]
# Wayland session: the WINDOW can still be an X11 window (XWayland), which allows the "never takes the
# focus" hints; the KEYS are still injected the Wayland way (SESSION_KIND), they must reach native
# Wayland games too. keyboard_mode=hide in menu.conf keeps a native Wayland window.
WINDOW_KIND = SESSION_KIND
if SESSION_KIND == "wayland" and load_menu_conf().get("keyboard_mode", "auto").strip().lower() != "hide" \
        and xwayland_available():
    os.environ["GDK_BACKEND"] = "x11"
    WINDOW_KIND = "x11"
TITLE = "LPM keyboard"
KEY_SHIFT, KEY_ALTGR = 42, 100
UNIT = 58  # pixels of a normal key


def text(name, default):
    return os.environ.get("LPM_KB_" + name, "").strip() or default


# --- Physical layout. (kind, evdev code, width in key units). kinds: char, shift, altgr, key
# (a fixed label, sent as is), close. Chars get their label from the current layout.
def _chars(codes):
    return [("char", c, 1.0) for c in codes]


# Aligned grid: 14 columns of the same width, so up / down always lands on the key just above
# or below (a real keyboard is staggered, which is awkward with a D-pad). Same key ORDER as a
# real keyboard. "caps" is the shift lock (letters only, like Caps Lock).
ROWS = [
    _chars([41, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13]) + [("key", 14, 1.0, "⌫")],
    [("key", 15, 1.0, "Tab")] + _chars([16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27]) + [("key", 1, 1.0, "Esc")],
    [("caps", 0, 1.0, "⇪")] + _chars([30, 31, 32, 33, 34, 35, 36, 37, 38, 39, 40, 43]) + [("key", 28, 1.0, "⏎")],
    [("shift", KEY_SHIFT, 1.0, "⇧")] + _chars([86, 44, 45, 46, 47, 48, 49, 50, 51, 52, 53])
    + [("altgr", KEY_ALTGR, 1.0, "AltGr"), ("close", 0, 1.0, "✕")],
    [("key", 105, 1.0, "←"), ("key", 108, 1.0, "↓"), ("key", 103, 1.0, "↑"), ("key", 106, 1.0, "→"),
     ("key", 57, 10.0, "␣")],
]

# US fallback labels (code -> (normal, shifted)), only used when GTK cannot give the layout.
_US_ROWS = ["`1234567890-=", "qwertyuiop[]", "asdfghjkl;'\\", "zxcvbnm,./"]
_US_CODES = [[41, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13], [16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27],
             [30, 31, 32, 33, 34, 35, 36, 37, 38, 39, 40, 43], [44, 45, 46, 47, 48, 49, 50, 51, 52, 53]]
_US_SHIFT = dict(zip("`1234567890-=[];'\\,./", '~!@#$%^&*()_+{}:"|<>?'))
US_LABELS = {}
for _codes, _chars_ in zip(_US_CODES, _US_ROWS):
    for _c, _ch in zip(_codes, _chars_):
        US_LABELS[_c] = (_ch, _US_SHIFT.get(_ch, _ch.upper()))

DEAD = {"dead_circumflex": "^", "dead_diaeresis": "¨", "dead_grave": "`", "dead_acute": "´",
        "dead_tilde": "~", "dead_cedilla": "¸"}


def keyval_text(keyval):
    if not keyval:
        return ""
    codepoint = Gdk.keyval_to_unicode(keyval)
    if codepoint and chr(codepoint).isprintable():
        return chr(codepoint)
    name = Gdk.keyval_name(keyval) or ""
    return DEAD.get(name, name[:3])


class LayoutReader:
    """Label of a physical key on the layout in use now (Gdk.Display.map_keycode), level 0 = normal,
    1 = Shift, 2 = AltGr, 3 = Shift+AltGr."""

    def __init__(self):
        self.display = Gdk.Display.get_default()
        self.detected = False

    def label(self, code, level):
        try:
            ok, keys, keyvals = self.display.map_keycode(code + 8)  # X/Wayland keycode = evdev + 8
        except Exception:
            ok, keys, keyvals = False, [], []
        if ok and keys:
            self.detected = True
            for key, keyval in zip(keys, keyvals):
                if key.group == 0 and key.level == level and keyval:
                    return keyval_text(keyval)
            for key, keyval in zip(keys, keyvals):  # level not defined: show the normal one
                if key.group == 0 and key.level == 0:
                    return keyval_text(keyval)
            return ""
        pair = US_LABELS.get(code)
        return (pair[1] if level & 1 else pair[0]) if pair else ""


CSS = b"""
window.lpm-kb, window.lpm-kb.background, window.lpm-kb.csd {
    background-color: transparent; color: #ffffff; box-shadow: none;
}
.lpm-kb-veil { background-color: rgba(0, 0, 0, 0.25); }
.lpm-kb-card {
    background-color: rgba(26, 26, 26, 0.78);
    border: 1px solid rgba(255, 255, 255, 0.18);
    border-radius: 10px;
    box-shadow: 0 0 40px rgba(58, 110, 165, 0.10), 0 8px 30px rgba(0, 0, 0, 0.5);
    padding: 14px;
}
window.lpm-kb.lpm-compact, window.lpm-kb.lpm-compact.background, window.lpm-kb.lpm-compact.csd {
    background-color: #1a1a1a; border-radius: 10px;
}
window.lpm-compact .lpm-kb-veil, window.lpm-compact .lpm-kb-card {
    background-color: transparent; border: none; box-shadow: none;
}
button.lpm-kb-key {
    background: rgba(70, 70, 70, 0.80); color: #ffffff; border: none; border-radius: 10px;
    font-size: 20px; min-height: 48px; padding: 0; box-shadow: none;
}
button.lpm-kb-key.lpm-kb-on { background: #5a8f5a; }
button.lpm-kb-key.lpm-kb-sel { background: #3a6ea5; }
.lpm-kb-hint { font-size: 14px; color: #bdbdbd; padding: 10px 6px 0 6px; }
"""


class KeyboardWindow(Gtk.Window):
    def __init__(self, application):
        super().__init__(application=application)
        self.add_css_class("lpm-kb")
        self.set_title(TITLE)
        self.set_decorated(False)
        self.injector = Injector(SESSION_KIND)
        self.reader = LayoutReader()
        try:
            self.delay_ms = max(0, int(load_menu_conf().get("keyboard_delay_ms", "50")))
        except ValueError:
            self.delay_ms = 50
        self.shift = False
        self.lock = False  # shift lock: letters stay capital until it is turned off
        self.altgr = False
        self.closing = False
        self.busy = False       # hidden / just shown again: losing the focus is expected
        self.sending = False    # between the key press and the key being sent: input ignored
        self.was_active = False
        self.sel = [2, 0]  # row, index in the row

        # X11: a window that never takes the focus, so the game keeps it and keys go straight to it
        # (no hide / show). Anywhere else, or if that fails, the key flow hides the window instead.
        self.nofocus = False
        self.game_focus = 0
        try:
            mode = load_menu_conf().get("keyboard_mode", "auto").strip().lower()
        except Exception:
            mode = "auto"
        if WINDOW_KIND == "x11" and mode != "hide":
            self.nofocus = x11_set_hints(self, "UTILITY", no_focus=True, above=True)

        self.veil = use_veil()
        if self.veil:
            monitor = pointer_monitor(WINDOW_KIND)
            if monitor is not None:
                self.fullscreen_on_monitor(monitor)
                geo = monitor.get_geometry()
                self.set_default_size(geo.width, geo.height)
            else:
                self.fullscreen()
        else:
            self.add_css_class("lpm-compact")
            self.set_resizable(False)

        card = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=6)
        card.add_css_class("lpm-kb-card")
        self.card = card
        self.keys = []  # rows of dicts: kind, code, units, button
        for row_def in ROWS:
            row_box = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=6)
            row_box.set_halign(Gtk.Align.CENTER)
            row = []
            for item in row_def:
                kind, code, units = item[0], item[1], item[2]
                fixed = item[3] if len(item) > 3 else ""
                button = Gtk.Button()
                button.add_css_class("lpm-kb-key")
                button.set_focusable(False)
                button.set_size_request(int(UNIT * units + 6 * (units - 1)), 52)
                entry = {"kind": kind, "code": code, "units": units, "button": button, "fixed": fixed}
                button.connect("clicked", lambda _b, e=entry: self.press(e))
                row_box.append(button)
                row.append(entry)
            self.keys.append(row)
            card.append(row_box)
        self.hint = Gtk.Label(label="", xalign=0)
        self.hint.add_css_class("lpm-kb-hint")
        card.append(self.hint)

        if self.veil:
            veil = Gtk.Box()
            veil.add_css_class("lpm-kb-veil")
            veil.set_hexpand(True)
            veil.set_vexpand(True)
            card.set_hexpand(True)
            card.set_vexpand(True)
            card.set_halign(Gtk.Align.CENTER)
            card.set_valign(Gtk.Align.END)
            card.set_margin_bottom(40)
            veil.append(card)
            click = Gtk.GestureClick()
            click.connect("pressed", self.on_veil_pressed)
            self.add_controller(click)
            self.set_child(veil)
        else:
            self.set_child(card)

        keys = Gtk.EventControllerKey()
        keys.connect("key-pressed", self.on_key)
        self.add_controller(keys)
        self.connect("close-request", lambda _w: setattr(self, "closing", True) or False)
        self.connect("notify::is-active", self.on_active_changed)
        self.refresh()

    # --- display ---------------------------------------------------------------------------
    def level(self, code=None):
        """Level of a key. The lock only concerns the keys whose normal label is a letter."""
        shifted = self.shift
        if self.lock and code is not None and self.reader.label(code, 0).isalpha():
            shifted = True
        return (1 if shifted else 0) + (2 if self.altgr else 0)

    def refresh(self):
        """Labels (current layout and Shift/AltGr state), toggles and selection."""
        for r, row in enumerate(self.keys):
            for c, entry in enumerate(row):
                button = entry["button"]
                label = self.reader.label(entry["code"], self.level(entry["code"])) if entry["kind"] == "char" else entry["fixed"]
                button.set_label(label or " ")
                on = (entry["kind"] == "shift" and self.shift) or (entry["kind"] == "caps" and self.lock) or (entry["kind"] == "altgr" and self.altgr)
                for cls, active in (("lpm-kb-on", on), ("lpm-kb-sel", [r, c] == self.sel)):
                    if active:
                        button.add_css_class(cls)
                    else:
                        button.remove_css_class(cls)
        notice = "" if self.reader.detected else text("NOLAYOUT", "Keyboard layout not detected (US shown).") + "    "
        self.hint.set_label(notice + text("HINT", "A: key  B: delete  X: space  Y: Shift (hold: lock)  Start: Enter  L1/R1: cursor  Select: close"))

    # --- sending -----------------------------------------------------------------------------
    def press(self, entry):
        if self.sending or self.closing:
            return
        kind, code = entry["kind"], entry["code"]
        if kind == "shift":
            self.shift = not self.shift
            self.refresh()
        elif kind == "caps":
            self.lock = not self.lock
            self.refresh()
        elif kind == "altgr":
            self.altgr = not self.altgr
            self.refresh()
        elif kind == "close":
            self.close_keyboard()
        elif kind == "char":
            codes = ([KEY_SHIFT] if self.level(code) & 1 else []) + ([KEY_ALTGR] if self.altgr else []) + [code]
            self.shift = self.altgr = False
            self.send(codes)
        else:
            self.send([code])

    def ensure_game_focus(self):
        """No-focus mode: if the focus ended up on this window (a click, the window manager), give
        it back to the window that had it when the keyboard opened. Another window that has it is left alone."""
        if not self.nofocus or not self.game_focus:
            return
        current = x11_focus_window()
        if current in (0, x11_xid(self)):
            x11_restore_focus(self.game_focus)

    def send(self, codes):
        """No-focus window (X11): the game has the focus, send at once. Otherwise: hide, give the
        game the focus back, send, show again immediately."""
        if self.nofocus:
            self.ensure_game_focus()
            self.injector.tap(codes)
            self.refresh()
            return
        self.busy = True
        self.sending = True
        self.set_visible(False)

        def do_send():
            self.injector.tap(codes)
            self.set_visible(True)
            self.present()
            self.sending = False  # the next key can be pressed right away
            self.refresh()
            GLib.timeout_add(600, lambda: (setattr(self, "busy", False), False)[1])
            return False

        GLib.timeout_add(self.delay_ms, do_send)

    # --- closing and focus -------------------------------------------------------------------
    def close_keyboard(self):
        if self.closing:
            return
        self.closing = True
        self.close()
        app.quit()

    def on_veil_pressed(self, _gesture, _n, x, y):
        ok, rect = self.card.compute_bounds(self)
        if ok and not (rect.get_x() <= x <= rect.get_x() + rect.get_width()
                       and rect.get_y() <= y <= rect.get_y() + rect.get_height()):
            self.close_keyboard()

    def on_active_changed(self, _win, _param):
        if self.is_active():
            if self.nofocus and WINDOW_KIND != SESSION_KIND:
                # XWayland: the compositor gave the focus to this window and it cannot be given back
                # to a native Wayland game: use the hide / show method instead.
                self.nofocus = False
            if not self.nofocus:
                self.was_active = True
            self.busy = False
            self.refresh()  # on Wayland the layout is only known once the window had the focus
        elif self.was_active and not self.busy and not self.closing:
            self.close_keyboard()

    def on_key(self, _ctrl, keyval, _code, _state):
        if keyval == Gdk.KEY_Escape:
            self.close_keyboard()
            return True
        return False

    # --- gamepad navigation ------------------------------------------------------------------
    def centers(self, row):
        x, out = 0.0, []
        for entry in row:
            out.append(x + entry["units"] / 2.0)
            x += entry["units"] + 0.1
        return out

    def move(self, dr, dc):
        r, c = self.sel
        if dc:
            c = (c + dc) % len(self.keys[r])
        if dr:
            here = self.centers(self.keys[r])[c]
            r = max(0, min(len(self.keys) - 1, r + dr))
            c = min(range(len(self.keys[r])), key=lambda i: abs(self.centers(self.keys[r])[i] - here))
        self.sel = [r, c]
        self.refresh()

    def press_code(self, code):
        """Direct keys of the gamepad (Backspace, Space, Enter, arrows)."""
        if not self.sending and not self.closing:
            self.send([code])

    def gamepad_a(self):
        self.press(self.keys[self.sel[0]][self.sel[1]])

    def gamepad_shift(self):
        """Short press of Y: one capital (or turns the lock off when it is on)."""
        if self.lock:
            self.lock = False
        else:
            self.shift = not self.shift
        self.refresh()

    def gamepad_lock(self):
        """Long press of Y: shift lock on / off."""
        self.lock = not self.lock
        self.shift = False
        self.refresh()


# --- Gamepad polling ---------------------------------------------------------------------------
_sdl = None
_pads = []
_state = {}
_next_scan = 0.0
REPEAT_FIRST_S, REPEAT_S = 0.35, 0.10
LOCK_HOLD_S = 0.6  # Y held this long = shift lock


def init_gamepad():
    global _sdl
    try:
        sdl = load_sdl2()
        if sdl is None or not init_sdl(sdl):
            return
        _sdl = sdl
        sync_controllers(sdl, _pads)
    except Exception:
        _sdl = None


def tick_gamepad(win):
    global _next_scan
    if _sdl is None or win.closing:
        return True
    now = time.monotonic()
    if now >= _next_scan:
        _next_scan = now + 1.0
        sync_controllers(_sdl, _pads)
    if not _pads:
        return True
    _sdl.SDL_GameControllerUpdate()

    def btn(pad, code):
        return _sdl.SDL_GameControllerGetButton(pad, code)

    for pad in _pads:
        # A button already held when the keyboard opens does nothing until released.
        st = _state.setdefault(pad, {"held": {c: 1 for c in (
            SDL_CONTROLLER_BUTTON_A, SDL_CONTROLLER_BUTTON_B, SDL_CONTROLLER_BUTTON_X, SDL_CONTROLLER_BUTTON_Y,
            SDL_CONTROLLER_BUTTON_START, SDL_CONTROLLER_BUTTON_BACK, SDL_CONTROLLER_BUTTON_LEFTSHOULDER,
            SDL_CONTROLLER_BUTTON_RIGHTSHOULDER)}, "dir": (0, 0), "next": 0.0})
        actions = {
            SDL_CONTROLLER_BUTTON_A: win.gamepad_a,
            SDL_CONTROLLER_BUTTON_B: lambda: win.press_code(14),
            SDL_CONTROLLER_BUTTON_X: lambda: win.press_code(57),
            SDL_CONTROLLER_BUTTON_START: lambda: win.press_code(28),
            SDL_CONTROLLER_BUTTON_LEFTSHOULDER: lambda: win.press_code(105),
            SDL_CONTROLLER_BUTTON_RIGHTSHOULDER: lambda: win.press_code(106),
            SDL_CONTROLLER_BUTTON_BACK: win.close_keyboard,
        }
        y_down = btn(pad, SDL_CONTROLLER_BUTTON_Y)
        if y_down and not st["held"][SDL_CONTROLLER_BUTTON_Y]:
            st["y_since"] = now
        elif y_down and st.get("y_since") and now - st["y_since"] >= LOCK_HOLD_S:
            st["y_since"] = None  # long press: lock, done once
            st["y_long"] = True
            win.gamepad_lock()
        elif not y_down and st["held"][SDL_CONTROLLER_BUTTON_Y]:
            if st.get("y_since") and not st.get("y_long"):
                win.gamepad_shift()
            st["y_since"] = None
            st["y_long"] = False
        st["held"][SDL_CONTROLLER_BUTTON_Y] = y_down
        for code, action in actions.items():
            value = btn(pad, code)
            if value and not st["held"][code]:
                action()
            st["held"][code] = value
        ax = _sdl.SDL_GameControllerGetAxis(pad, SDL_CONTROLLER_AXIS_LEFTX)
        ay = _sdl.SDL_GameControllerGetAxis(pad, SDL_CONTROLLER_AXIS_LEFTY)
        dc = -1 if (btn(pad, SDL_CONTROLLER_BUTTON_DPAD_LEFT) or ax < -GAMEPAD_AXIS_THRESHOLD) else (
            1 if (btn(pad, SDL_CONTROLLER_BUTTON_DPAD_RIGHT) or ax > GAMEPAD_AXIS_THRESHOLD) else 0)
        dr = -1 if (btn(pad, SDL_CONTROLLER_BUTTON_DPAD_UP) or ay < -GAMEPAD_AXIS_THRESHOLD) else (
            1 if (btn(pad, SDL_CONTROLLER_BUTTON_DPAD_DOWN) or ay > GAMEPAD_AXIS_THRESHOLD) else 0)
        direction = (dr, dc)
        if direction != (0, 0):
            if direction != st["dir"]:
                win.move(dr, dc)
                st["next"] = now + REPEAT_FIRST_S
            elif now >= st["next"]:
                win.move(dr, dc)
                st["next"] = now + REPEAT_S
        st["dir"] = direction
    return True


def _load_prefix_watch():
    spec = importlib.util.spec_from_file_location(
        "zgu_prefix_watch", os.path.join(os.path.dirname(os.path.abspath(__file__)), "zgu-prefix-watch.py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def on_activate(application):
    application.hold()
    for sig in (signal.SIGTERM, signal.SIGINT):
        GLib.unix_signal_add(GLib.PRIORITY_HIGH, sig, lambda: (application.quit(), False)[1])
    provider = Gtk.CssProvider()
    provider.load_from_data(CSS)
    Gtk.StyleContext.add_provider_for_display(
        Gdk.Display.get_default(), provider, Gtk.STYLE_PROVIDER_PRIORITY_USER)
    win = KeyboardWindow(application)
    win.game_focus = x11_focus_window() if win.nofocus else 0
    win.present()
    if win.nofocus:
        # The window manager may give the focus to the new window: give it back to the game.
        for delay in (100, 400):
            GLib.timeout_add(delay, lambda: (win.ensure_game_focus(), False)[1])
    init_gamepad()
    GLib.timeout_add(GAMEPAD_POLL_MS, tick_gamepad, win)
    game_watch = _load_prefix_watch().GameEndWatch(PREFIX_DIR)

    def check_game():
        if game_watch.game_ended():
            win.close_keyboard()
            return False
        return True

    GLib.timeout_add(1000, check_game)


def single_instance():
    """Only one keyboard at a time (menu entry and D-pad shortcut could both start one)."""
    base = os.environ.get("XDG_RUNTIME_DIR") or "/tmp"
    handle = open(os.path.join(base, "lpm-virtual-keyboard.lock-%d" % os.getuid()), "a+")  # not "w": keep the pid of the running one
    try:
        fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        return None
    handle.seek(0)
    handle.truncate()
    handle.write(str(os.getpid()))  # so that the shortcut can close this keyboard
    handle.flush()
    return handle


_lock = single_instance()
if _lock is None:
    sys.exit(0)
app = Gtk.Application(application_id="org.lpm.VirtualKeyboard")
app.connect("activate", on_activate)
sys.exit(app.run([sys.argv[0]]))
