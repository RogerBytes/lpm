#!/usr/bin/env python3
# --- lpm launcher: in-game LPM menu, shown OVER the running game -- GTK4 ---
#
# Usage: zgu-game-menu.py <x11|wayland> <prefix_folder>
#
# Started by zgu-gamepad-exit-watcher.py (which, despite its historical name, is now the
# "menu opener": gamepad combo or keyboard hotkey) and exits by itself once an entry was
# used or the menu was closed. The game is NOT paused.
#
# The menu is a plain list of entries (MENU below). An entry is either an action (a key to
# send, "quit") or a submenu: adding a feature later = adding one entry, nothing else changes.
#
# Inputs, each one enough on its own:
#   - Gamepad (SDL2, read in this process, never by injecting keys): D-pad / left stick up and
#     down move, A validates, B goes back (closes the menu from the main level).
#   - Keyboard: Up/Down, Enter, Escape (back / close).
#   - Mouse: click an entry.
#
# Keys are sent AFTER the menu window is closed (short delay, so the focus is back on the game):
# xdotool on X11, ydotool on Wayland. Same tools as zgu-gamepad-alttab-watcher.py.
# "Quit the game" offers F4 and Esc (the game's own way out) and "Force quit", which asks for a
# confirmation then stops the wineserver of this game's prefix (zgu_common.close_prefix_game),
# exactly what the old quit combo did.
#
# Labels come from the environment (LPM_MENU_*, translated by the orchestrator); the English
# text below is the fallback.

import os
import shutil
import signal
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from zgu_common import (
    GAMEPAD_AXIS_THRESHOLD,
    GAMEPAD_POLL_MS,
    SDL_CONTROLLER_AXIS_LEFTY,
    SDL_CONTROLLER_BUTTON_A,
    SDL_CONTROLLER_BUTTON_B,
    SDL_CONTROLLER_BUTTON_DPAD_DOWN,
    SDL_CONTROLLER_BUTTON_DPAD_UP,
    close_prefix_game,
    init_sdl,
    load_sdl2,
    sync_controllers,
)

try:
    import gi
    gi.require_version("Gtk", "4.0")
    from gi.repository import Gtk, Gdk, GLib
except Exception as exc:  # pragma: no cover - system dependency missing
    sys.stderr.write("zgu-game-menu: GTK4/PyGObject unavailable (%s)\n" % exc)
    sys.exit(1)

if len(sys.argv) < 3 or sys.argv[1] not in ("x11", "wayland") or not sys.argv[2]:
    sys.stderr.write("Usage: zgu-game-menu.py <x11|wayland> <prefix_folder>\n")
    sys.exit(1)

SESSION_KIND = sys.argv[1]
PREFIX_DIR = sys.argv[2]


def label(name, default):
    return os.environ.get("LPM_MENU_" + name, "").strip() or default


# --- Keys that can be sent: name -> (xdotool key spec, ydotool key sequence). Linux key
# codes (linux/input-event-codes.h): ALT=56 TAB=15 ENTER=28 F4=62 F11=87 ESC=1.
KEYS = {
    "alt+tab": ("alt+Tab", ["56:1", "15:1", "15:0", "56:0"]),
    "alt+enter": ("alt+Return", ["56:1", "28:1", "28:0", "56:0"]),
    "f4": ("F4", ["62:1", "62:0"]),
    "f11": ("F11", ["87:1", "87:0"]),
    "escape": ("Escape", ["1:1", "1:0"]),
}


def _xdotool():
    if shutil.which("xdotool"):
        return "xdotool"
    if os.access("/run/host/usr/bin/xdotool", os.X_OK):
        return "/run/host/usr/bin/xdotool"
    return None


def send_key(name):
    x11_spec, ydo_seq = KEYS[name]
    try:
        xdotool = _xdotool()
        if SESSION_KIND == "x11" and xdotool:
            subprocess.run([xdotool, "key", x11_spec], check=False,
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        elif shutil.which("ydotool"):
            subprocess.run(["ydotool", "key", *ydo_seq], check=False,
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except Exception:
        pass  # best-effort: a missed key must never crash the menu


def quit_game():
    close_prefix_game(PREFIX_DIR)


# --- The menu. Entry = (label, kind, value): kind "key" (value = name in KEYS), "call"
# (value = function), "submenu" (value = list of entries). Add a feature = add an entry.
def build_menu():
    # Alt+Tab is deliberately NOT here: it stays the L1+L2+R1+R2+R3 hold + D-pad left/right
    # (zgu-gamepad-alttab-watcher.py).
    window_menu = [
        (label("ALTENTER", "Alt+Enter"), "key", "alt+enter"),
        ("F11", "key", "f11"),
    ]
    force_menu = [
        (label("QUIT_CONFIRM", "Yes, force quit the game"), "call", quit_game),
        (label("QUIT_CANCEL", "No, back"), "back", None),
    ]
    quit_menu = [
        ("F4", "key", "f4"),
        (label("ESCAPE", "Esc"), "key", "escape"),
        (label("FORCE", "Force quit the game"), "submenu", force_menu),
    ]
    return [
        (label("WINDOW", "Window"), "submenu", window_menu),
        (label("QUIT", "Quit the game"), "submenu", quit_menu),
    ]


CSS = b"""
window.lpm-menu { background-color: #1a1a1a; color: #ffffff; border-radius: 14px; }
.lpm-menu-title { font-size: 22px; font-weight: bold; padding: 18px 24px 6px 24px; color: #ffffff; }
.lpm-menu-hint { font-size: 14px; padding: 6px 24px 14px 24px; color: #9a9a9a; }
list.lpm-menu-list { background-color: transparent; }
list.lpm-menu-list row { padding: 10px 18px; margin: 2px 14px; background-color: transparent; color: #ffffff; }
list.lpm-menu-list row:selected { background-color: #3a6ea5; border-radius: 8px; color: #ffffff; }
.lpm-menu-entry { font-size: 24px; color: #ffffff; }
"""


class MenuWindow(Gtk.Window):
    def __init__(self, app):
        super().__init__(application=app)
        self.add_css_class("lpm-menu")
        self.set_title("LPM")
        self.set_default_size(520, 460)
        self.set_resizable(False)
        self.set_decorated(False)
        self.stack = []          # (entries, title, selected index) of the levels above
        self.entries = build_menu()
        self.title_text = label("TITLE", "LPM menu")
        self.pending = None      # action to run once the window is closed
        self.closing = False

        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
        self.title_label = Gtk.Label(label=self.title_text, xalign=0)
        self.title_label.add_css_class("lpm-menu-title")
        box.append(self.title_label)
        self.listbox = Gtk.ListBox()
        self.listbox.add_css_class("lpm-menu-list")
        self.listbox.set_selection_mode(Gtk.SelectionMode.SINGLE)
        self.listbox.set_activate_on_single_click(True)
        self.listbox.connect("row-activated", lambda _lb, row: self.activate_index(row.get_index()))
        self.listbox.set_vexpand(True)
        box.append(self.listbox)
        hint = Gtk.Label(label=label("HINT", "A: validate    B: back"), xalign=0)
        hint.add_css_class("lpm-menu-hint")
        box.append(hint)
        self.set_child(box)

        keys = Gtk.EventControllerKey()
        keys.connect("key-pressed", self.on_key)
        self.add_controller(keys)
        self.connect("close-request", self.on_close_request)
        self.refill(0)

    def refill(self, select):
        child = self.listbox.get_first_child()
        while child is not None:
            nxt = child.get_next_sibling()
            self.listbox.remove(child)
            child = nxt
        for entry_label, kind, _value in self.entries:
            text = entry_label + (" ▸" if kind == "submenu" else "")
            lbl = Gtk.Label(label=text, xalign=0)
            lbl.add_css_class("lpm-menu-entry")
            self.listbox.append(lbl)
        row = self.listbox.get_row_at_index(max(0, min(select, len(self.entries) - 1)))
        if row:
            self.listbox.select_row(row)
            row.grab_focus()

    def selected_index(self):
        row = self.listbox.get_selected_row()
        return row.get_index() if row else 0

    def move(self, step):
        idx = (self.selected_index() + step) % len(self.entries)
        row = self.listbox.get_row_at_index(idx)
        self.listbox.select_row(row)
        row.grab_focus()

    def activate_index(self, idx):
        _label, kind, value = self.entries[idx]
        if kind == "submenu":
            self.stack.append((self.entries, self.title_label.get_text(), idx))
            self.title_label.set_text(_label)
            self.entries = value
            self.refill(0)
        elif kind == "back":
            self.go_back()
        else:
            self.pending = (kind, value)
            self.finish()

    def go_back(self):
        if not self.stack:
            self.finish()
            return
        self.entries, title, idx = self.stack.pop()
        self.title_label.set_text(title)
        self.refill(idx)

    def gamepad_validate(self):
        self.activate_index(self.selected_index())

    def gamepad_cancel(self):
        self.go_back()

    def on_key(self, _ctrl, keyval, _code, _state):
        if keyval in (Gdk.KEY_Up, Gdk.KEY_KP_Up):
            self.move(-1)
        elif keyval in (Gdk.KEY_Down, Gdk.KEY_KP_Down):
            self.move(1)
        elif keyval in (Gdk.KEY_Return, Gdk.KEY_KP_Enter, Gdk.KEY_space):
            self.activate_index(self.selected_index())
        elif keyval == Gdk.KEY_Escape:
            self.go_back()
        else:
            return False
        return True

    def on_close_request(self, _win):
        self.closing = True
        return False

    def finish(self):
        """Close the window, wait for the focus to go back to the game, then run the action."""
        if self.closing:
            return
        self.closing = True
        pending = self.pending
        self.close()
        GLib.timeout_add(350, self.run_pending, pending)

    @staticmethod
    def run_pending(pending):
        if pending:
            kind, value = pending
            if kind == "key":
                send_key(value)
            elif kind == "call":
                value()
        app.quit()
        return False


# --- Gamepad (SDL2), read here: D-pad / left stick up-down, A validate, B back ---
_sdl = None
_pads = []
_prev = {}
_next_scan = 0.0


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
    for pad in _pads:
        state = _prev.setdefault(pad, {"a": 1, "b": 1, "dir": 0})  # held at start: ignored
        a = _sdl.SDL_GameControllerGetButton(pad, SDL_CONTROLLER_BUTTON_A)
        b = _sdl.SDL_GameControllerGetButton(pad, SDL_CONTROLLER_BUTTON_B)
        up = _sdl.SDL_GameControllerGetButton(pad, SDL_CONTROLLER_BUTTON_DPAD_UP)
        down = _sdl.SDL_GameControllerGetButton(pad, SDL_CONTROLLER_BUTTON_DPAD_DOWN)
        axis = _sdl.SDL_GameControllerGetAxis(pad, SDL_CONTROLLER_AXIS_LEFTY)
        direction = -1 if (up or axis < -GAMEPAD_AXIS_THRESHOLD) else (1 if (down or axis > GAMEPAD_AXIS_THRESHOLD) else 0)
        if direction and direction != state["dir"]:
            win.move(direction)
        if a and not state["a"]:
            win.gamepad_validate()
        if b and not state["b"]:
            win.gamepad_cancel()
        state.update(a=a, b=b, dir=direction)
    return True


def on_activate(application):
    application.hold()  # keep running after the window closes: the action runs right after
    # SDL2 installs its own SIGTERM/SIGINT handlers, which would swallow the signal the opener
    # sends when the game ends: handle both here so the menu always goes away.
    for sig in (signal.SIGTERM, signal.SIGINT):
        GLib.unix_signal_add(GLib.PRIORITY_HIGH, sig, lambda: (application.quit(), False)[1])
    provider = Gtk.CssProvider()
    provider.load_from_data(CSS)
    Gtk.StyleContext.add_provider_for_display(
        Gdk.Display.get_default(), provider, Gtk.STYLE_PROVIDER_PRIORITY_USER)
    win = MenuWindow(application)
    win.present()
    init_gamepad()
    GLib.timeout_add(GAMEPAD_POLL_MS, tick_gamepad, win)


app = Gtk.Application(application_id="org.lpm.GameMenu")
app.connect("activate", on_activate)
sys.exit(app.run([sys.argv[0]]))
