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
# "Quit the game" offers Esc, Alt+F4 (the game's own ways out) and "Force quit", which asks for a
# confirmation then stops the wineserver of this game's prefix (zgu_common.close_prefix_game),
# exactly what the old quit combo did. Every entry closes the menu first.
#
# The menu closes by itself as soon as it loses the focus after having had it (click on the game,
# Alt+Tab...): otherwise it would stay hidden behind the game with no way to bring it back.
#
# Look: when the desktop composites (transparency available) the window is FULLSCREEN and
# transparent: a dark translucent veil over the whole screen with the menu "card" centered in it
# (the layout centers it, so it works the same on X11 and Wayland). A click on the veil, outside
# the card, closes the menu. Without compositing a fullscreen window would hide the game behind
# an opaque rectangle, so a small opaque window is used instead (centered with xdotool on X11).
# <XDG config>/lpm/menu.conf: "backdrop=off" forces the small window (see zgu_common.load_menu_conf).
#
# IF A FULLSCREEN GAME REACTS BADLY to this window (minimizes, loses mouse/pad), tricks to try,
# simplest first (none is implemented, on purpose: see how real games behave first):
#   1. X11: mark the window "always on top" (_NET_WM_STATE_ABOVE, e.g. a client message sent
#      with libX11 through ctypes, or `wmctrl -i -r <id> -b add,above`). GTK4 removed
#      set_keep_above(), so it has to be done from outside, as xdotool is already used here.
#   2. Wayland: an "overlay" layer surface (wlr-layer-shell, library gtk4-layer-shell). Works on
#      KDE and wlroots compositors (sway...), NOT on GNOME's Mutter.
#   3. Last resort: backdrop=off in menu.conf (small window), or no veil for that game.
#
# Labels come from the environment (LPM_MENU_*, translated by the orchestrator); the English
# text below is the fallback.

import importlib.util
import os
import shutil
import signal
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from zgu_common import (
    close_keyboard_if_running,
    GAMEPAD_AXIS_THRESHOLD,
    GAMEPAD_POLL_MS,
    SDL_CONTROLLER_AXIS_LEFTX,
    SDL_CONTROLLER_AXIS_LEFTY,
    SDL_CONTROLLER_BUTTON_DPAD_LEFT,
    SDL_CONTROLLER_BUTTON_DPAD_RIGHT,
    SDL_CONTROLLER_BUTTON_A,
    SDL_CONTROLLER_BUTTON_B,
    SDL_CONTROLLER_BUTTON_DPAD_DOWN,
    SDL_CONTROLLER_BUTTON_DPAD_UP,
    close_prefix_game,
    runtime_file,
    init_sdl,
    load_sdl2,
    sync_controllers,
)

try:
    import gi
    gi.require_version("Gtk", "4.0")
    from gi.repository import Gtk, Gdk, GLib
    from zgu_overlay import place_on_x11, pointer_monitor, use_veil, xdotool_path
    import zgu_audio
    from zgu_inject import Injector
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
    "alt+f4": ("alt+F4", ["56:1", "62:1", "62:0", "56:0"]),
    "f11": ("F11", ["87:1", "87:0"]),
    "escape": ("Escape", ["1:1", "1:0"]),
}


_xdotool = xdotool_path


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


def gamepad_mouse_on():
    return os.path.exists(runtime_file("gamepad-mouse"))


def toggle_gamepad_mouse(_new_state=None):
    """Asks the watcher (zgu-gamepad-exit-watcher.py) to turn the gamepad mouse on / off."""
    try:
        with open(runtime_file("gamepad-cmd"), "w", encoding="utf-8") as f:
            f.write("mouse-toggle\n")
    except OSError:
        pass


# --- MangoHud overlay. The launcher (zgl-launcher-orchestrator.sh) starts the game with MangoHud
# loaded but HIDDEN and writes the prefix path in "overlay-armed"; only then is the entry shown.
# MangoHud's own toggle key is Shift_R+F12 (the launcher sets it explicitly). ---
KEY_RIGHTSHIFT, KEY_F12 = 54, 88


def overlay_armed():
    try:
        with open(runtime_file("overlay-armed"), encoding="utf-8") as f:
            return f.read().strip().rstrip("/") == PREFIX_DIR.rstrip("/")
    except OSError:
        return False


def overlay_visible():
    return os.path.exists(runtime_file("overlay-visible"))


def _diag_log(message):
    try:
        path = os.path.join(os.environ.get("XDG_DATA_HOME") or os.path.join(os.path.expanduser("~"), ".local", "share"),
                            "lpm", "menu-watcher.log")
        with open(path, "a", encoding="utf-8") as f:
            f.write("%s [menu] %s\n" % (time.strftime("%Y-%m-%d %H:%M:%S"), message))
    except OSError:
        pass


def _mangohud_env_count():
    """Number of processes with MANGOHUD=1 in their environment (the library itself cannot be checked
    reliably: the maps of sandboxed processes are often unreadable)."""
    count = 0
    for pid in os.listdir("/proc"):
        if not pid.isdigit():
            continue
        try:
            with open("/proc/%s/environ" % pid, "rb") as f:
                if b"MANGOHUD=1" in f.read():
                    count += 1
        except OSError:
            continue
    return count


def toggle_overlay(new_state):
    try:
        _diag_log("overlay toggle -> %s (MANGOHUD=1 in the environment of %d process(es))"
                  % ("on" if new_state else "off", _mangohud_env_count()))
        Injector(SESSION_KIND).hold([KEY_RIGHTSHIFT, KEY_F12])
        if new_state:
            open(runtime_file("overlay-visible"), "w").close()
        else:
            os.remove(runtime_file("overlay-visible"))
    except OSError:
        pass


def start_keyboard():
    """Starts the virtual keyboard (it keeps running after this menu has exited); closes it when it is already open."""
    if close_keyboard_if_running():
        return
    try:
        subprocess.Popen([sys.executable, os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                                        "zgu-virtual-keyboard.py"), SESSION_KIND, PREFIX_DIR],
                         stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                         start_new_session=True)
    except OSError:
        pass


# --- The menu. Entry = (label, kind, value): kind "key" (value = name in KEYS), "call"
# (value = function), "submenu" (value = list of entries). Add a feature = add an entry.
def build_menu():
    # Alt+Tab is deliberately NOT here: it stays the L1+L2+R1+R2+R3 hold + D-pad left/right
    # (zgu-gamepad-alttab-watcher.py).
    # Kinds: "key" = send a key, then close the menu; "key" = send a key, then show the menu
    # again (the game may need more than one try); "call" = run a function, menu stays open.
    window_menu = [
        (label("ALTENTER", "Alt+Enter"), "key", "alt+enter"),
        ("F4", "key", "f4"),
        ("F11", "key", "f11"),
    ]
    force_menu = [
        (label("QUIT_CONFIRM", "Yes, force quit the game"), "call", quit_game, {"danger": True}),
        (label("QUIT_CANCEL", "No, back"), "back", None),
    ]
    altf4_menu = [
        (label("ALTF4_CONFIRM", "Yes, send Alt+F4"), "key", "alt+f4"),
        (label("QUIT_CANCEL", "No, back"), "back", None),
    ]
    # Esc first: some games have no gamepad shortcut for their own menu.
    quit_menu = [
        (label("ESCAPE", "Esc"), "key", "escape"),
        ("Alt+F4", "submenu", altf4_menu),
        (label("FORCE", "Force quit the game"), "submenu", force_menu, {"danger": True}),
    ]
    root = [
        (label("WINDOW", "Window"), "submenu", window_menu),
        (label("KEYBOARD", "Virtual keyboard"), "call", start_keyboard),
        (label("MOUSE", "Gamepad mouse"), "switch", (gamepad_mouse_on, toggle_gamepad_mouse)),
    ]
    if overlay_armed():
        root.append((label("OVERLAY", "FPS overlay"), "switch", (overlay_visible, toggle_overlay)))
    if zgu_audio.available() and zgu_audio.get_volume() is not None:
        root.append((label("VOLUME", "Volume"), "slider",
                     (lambda: zgu_audio.get_volume() or 0, zgu_audio.set_volume)))
        root.append((label("MUTE", "Mute"), "switch", (zgu_audio.get_mute, zgu_audio.set_mute)))
    # Quit goes last, set apart by a thin line
    root.append((label("QUIT", "Quit the game"), "submenu", quit_menu, {"sep": True}))
    return root


CSS = b"""
/* One radius everywhere, the theme's own window corners overridden. Only BACKGROUNDS are
   translucent (rgba): texts keep an opaque color. */
window.lpm-menu, window.lpm-menu.background, window.lpm-menu.csd {
    background-color: transparent;
    color: #ffffff;
    box-shadow: none;
}
/* Veil mode (fullscreen): dark translucent veil, card in the middle. */
/* Veil: ~70% black, a bit lighter around the card (vignette: darker toward the screen edges). */
.lpm-veil {
    background-color: rgba(0, 0, 0, 0.66);
    background-image: radial-gradient(circle farthest-corner at 50% 50%, rgba(0, 0, 0, 0) 0%, rgba(0, 0, 0, 0.30) 100%);
}
/* Card: thin light border and a soft bluish glow so it stands out of the veil. */
.lpm-card {
    background-color: rgba(26, 26, 26, 0.92);
    border: 1px solid rgba(255, 255, 255, 0.18);
    border-radius: 10px;
    box-shadow: 0 0 40px rgba(58, 110, 165, 0.10), 0 8px 30px rgba(0, 0, 0, 0.5);
    min-width: 520px;
}
/* Compact mode (no compositing): the small window itself is the opaque card. */
window.lpm-menu.lpm-compact, window.lpm-menu.lpm-compact.background, window.lpm-menu.lpm-compact.csd {
    background-color: #1a1a1a;
    border-radius: 10px;
}
window.lpm-compact .lpm-veil, window.lpm-compact .lpm-card { background-color: transparent; background-image: none; border: none; box-shadow: none; }
.lpm-menu-title { font-size: 22px; font-weight: bold; padding: 18px 24px 6px 24px; color: #ffffff; }
.lpm-menu-hint { font-size: 14px; padding: 6px 24px 14px 24px; color: #bdbdbd; }
list.lpm-menu-list { background-color: transparent; }
list.lpm-menu-list row { padding: 10px 18px; margin: 2px 14px; background-color: transparent; color: #ffffff; border-radius: 10px; }
list.lpm-menu-list row:selected { background-color: #3a6ea5; color: #ffffff; }
.lpm-menu-entry { font-size: 24px; color: #ffffff; }
.lpm-menu-chevron { font-size: 28px; color: rgba(255, 255, 255, 0.55); }
.lpm-menu-pct { font-size: 20px; color: #ffffff; min-width: 64px; }
list.lpm-menu-list row.lpm-sep { margin-top: 12px; border-top: 1px solid rgba(255, 255, 255, 0.15); border-radius: 0 0 10px 10px; padding-top: 14px; }
list.lpm-menu-list row.lpm-danger .lpm-menu-entry { color: #e57373; }
list.lpm-menu-list row:selected .lpm-menu-chevron { color: #ffffff; }
"""


class MenuWindow(Gtk.Window):
    def __init__(self, app):
        super().__init__(application=app)
        self.add_css_class("lpm-menu")
        self.set_title("LPM menu")
        self.set_decorated(False)
        self.veil = use_veil()
        if self.veil:
            self.fullscreen_on_pointer_monitor()
        else:
            self.add_css_class("lpm-compact")
            self.set_default_size(520, 460)
            self.set_resizable(False)
        self.stack = []          # (entries, title, selected index) of the levels above
        self.entries = build_menu()
        self.title_text = label("TITLE", "LPM menu")
        self.pending = None      # action to run once the window is closed
        self.closing = False
        self.was_active = False  # has had the focus at least once
        self.busy = False        # losing the focus is expected (not used for now)

        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
        box.add_css_class("lpm-card")
        box.set_halign(Gtk.Align.CENTER)
        box.set_valign(Gtk.Align.CENTER)
        self.card = box
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
        if self.veil:
            veil = Gtk.Box()
            veil.add_css_class("lpm-veil")
            veil.set_hexpand(True)
            veil.set_vexpand(True)
            box.set_hexpand(True)   # the card takes the whole space, halign/valign center it
            box.set_vexpand(True)
            veil.append(box)
            click = Gtk.GestureClick()
            click.connect("pressed", self.on_veil_pressed)
            self.add_controller(click)
            self.set_child(veil)
            self.card.set_size_request(520, 460)
        else:
            box.set_halign(Gtk.Align.FILL)
            box.set_valign(Gtk.Align.FILL)
            self.set_child(box)

        keys = Gtk.EventControllerKey()
        keys.connect("key-pressed", self.on_key)
        self.add_controller(keys)
        self.connect("close-request", self.on_close_request)
        self.connect("notify::is-active", self.on_active_changed)
        self.refill(0)

    def fullscreen_on_pointer_monitor(self):
        monitor = pointer_monitor(SESSION_KIND)
        if monitor is not None:
            self.fullscreen_on_monitor(monitor)
            geo = monitor.get_geometry()
            self.set_default_size(geo.width, geo.height)  # also right when no window manager
        else:
            self.fullscreen()

    def on_veil_pressed(self, _gesture, _n, x, y):
        """A click on the veil, outside the card, closes the menu."""
        ok, rect = self.card.compute_bounds(self)
        if ok and not (rect.get_x() <= x <= rect.get_x() + rect.get_width()
                       and rect.get_y() <= y <= rect.get_y() + rect.get_height()):
            self.closing = True
            self.close()
            app.quit()

    def refill(self, select):
        child = self.listbox.get_first_child()
        while child is not None:
            nxt = child.get_next_sibling()
            self.listbox.remove(child)
            child = nxt
        self.rows = []
        for entry in self.entries:
            entry_label, kind, value = entry[:3]
            opts = entry[3] if len(entry) > 3 else {}
            row = Gtk.ListBoxRow()
            if opts.get("sep"):
                row.add_css_class("lpm-sep")
            if opts.get("danger"):
                row.add_css_class("lpm-danger")
            box = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=14)
            lbl = Gtk.Label(label=entry_label, xalign=0)
            lbl.add_css_class("lpm-menu-entry")
            lbl.set_hexpand(True)
            box.append(lbl)
            info = {}
            if kind == "submenu":
                chevron = Gtk.Label(label="›")
                chevron.add_css_class("lpm-menu-chevron")
                box.append(chevron)
            elif kind == "switch":
                switch = Gtk.Switch()
                switch.set_valign(Gtk.Align.CENTER)
                switch.set_can_target(False)   # the row handles the click
                switch.set_focusable(False)
                info["on"] = bool(value[0]())
                switch.set_active(info["on"])
                info["switch"] = switch
                box.append(switch)
            elif kind == "slider":
                scale = Gtk.Scale.new_with_range(Gtk.Orientation.HORIZONTAL, 0, zgu_audio.MAXIMUM, zgu_audio.STEP)
                scale.set_draw_value(False)
                scale.set_size_request(220, -1)
                scale.set_valign(Gtk.Align.CENTER)
                scale.set_focusable(False)
                pct = Gtk.Label(label="")
                pct.add_css_class("lpm-menu-pct")
                info.update(scale=scale, pct=pct, value=int(value[0]()))
                scale.set_value(info["value"])
                pct.set_text("%d %%" % info["value"])
                scale.connect("value-changed", self.on_scale_changed, len(self.rows))
                box.append(scale)
                box.append(pct)
            row.set_child(box)
            self.listbox.append(row)
            self.rows.append(info)
        row = self.listbox.get_row_at_index(max(0, min(select, len(self.entries) - 1)))
        if row:
            self.listbox.select_row(row)
            row.grab_focus()

    def on_scale_changed(self, scale, idx):
        info = self.rows[idx]
        new = int(round(scale.get_value()))
        if new == info.get("value"):
            return  # programmatic update, nothing to do
        info["value"] = new
        info["pct"].set_text("%d %%" % new)
        self.entries[idx][2][1](new)

    def adjust(self, step):
        """Left / right on the selected row: moves a slider."""
        idx = self.selected_index()
        if self.entries[idx][1] != "slider":
            return
        scale = self.rows[idx]["scale"]
        scale.set_value(max(0, min(zgu_audio.MAXIMUM, scale.get_value() + step * zgu_audio.STEP)))

    def selected_index(self):
        row = self.listbox.get_selected_row()
        return row.get_index() if row else 0

    def move(self, step):
        idx = (self.selected_index() + step) % len(self.entries)
        row = self.listbox.get_row_at_index(idx)
        self.listbox.select_row(row)
        row.grab_focus()

    def activate_index(self, idx):
        _label, kind, value = self.entries[idx][:3]
        if kind == "switch":
            info = self.rows[idx]
            info["on"] = not info["on"]
            info["switch"].set_active(info["on"])
            value[1](info["on"])      # the menu stays open
        elif kind == "slider":
            pass                      # left / right (or a click on the bar) change it
        elif kind == "submenu":
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
        elif keyval in (Gdk.KEY_Left, Gdk.KEY_KP_Left):
            self.adjust(-1)
        elif keyval in (Gdk.KEY_Right, Gdk.KEY_KP_Right):
            self.adjust(1)
        elif keyval in (Gdk.KEY_Return, Gdk.KEY_KP_Enter, Gdk.KEY_space):
            self.activate_index(self.selected_index())
        elif keyval == Gdk.KEY_Escape:
            self.go_back()
        else:
            return False
        return True

    def on_active_changed(self, _win, _param):
        if self.is_active():
            self.was_active = True
            self.busy = False
        elif self.was_active and not self.busy and not self.closing:
            # Focus went elsewhere (click on the game, Alt+Tab...): close the menu -- unless it comes
            # back within a moment (the notice of the gamepad mouse takes the focus for an instant).
            GLib.timeout_add(700, self.close_if_still_unfocused)

    def close_if_still_unfocused(self):
        if not self.is_active() and not self.closing:
            self.closing = True
            self.close()
            app.quit()
        return False

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
        state = _prev.setdefault(pad, {"a": 1, "b": 1, "dir": 0, "h": 0, "hnext": 0.0})  # held at start: ignored
        a = _sdl.SDL_GameControllerGetButton(pad, SDL_CONTROLLER_BUTTON_A)
        b = _sdl.SDL_GameControllerGetButton(pad, SDL_CONTROLLER_BUTTON_B)
        up = _sdl.SDL_GameControllerGetButton(pad, SDL_CONTROLLER_BUTTON_DPAD_UP)
        down = _sdl.SDL_GameControllerGetButton(pad, SDL_CONTROLLER_BUTTON_DPAD_DOWN)
        axis = _sdl.SDL_GameControllerGetAxis(pad, SDL_CONTROLLER_AXIS_LEFTY)
        direction = -1 if (up or axis < -GAMEPAD_AXIS_THRESHOLD) else (1 if (down or axis > GAMEPAD_AXIS_THRESHOLD) else 0)
        if direction and direction != state["dir"]:
            win.move(direction)
        left = _sdl.SDL_GameControllerGetButton(pad, SDL_CONTROLLER_BUTTON_DPAD_LEFT)
        right = _sdl.SDL_GameControllerGetButton(pad, SDL_CONTROLLER_BUTTON_DPAD_RIGHT)
        axis_x = _sdl.SDL_GameControllerGetAxis(pad, SDL_CONTROLLER_AXIS_LEFTX)
        horizontal = -1 if (left or axis_x < -GAMEPAD_AXIS_THRESHOLD) else (1 if (right or axis_x > GAMEPAD_AXIS_THRESHOLD) else 0)
        if horizontal != state["h"]:
            state["h"] = horizontal
            state["hnext"] = now + 0.40       # a held direction repeats after 0.4 s
            if horizontal:
                win.adjust(horizontal)
        elif horizontal and now >= state["hnext"]:
            state["hnext"] = now + 0.10
            win.adjust(horizontal)
        if a and not state["a"]:
            win.gamepad_validate()
        if b and not state["b"]:
            win.gamepad_cancel()
        state.update(a=a, b=b, dir=direction)
    return True


def _load_prefix_watch():
    spec = importlib.util.spec_from_file_location(
        "zgu_prefix_watch", os.path.join(os.path.dirname(os.path.abspath(__file__)), "zgu-prefix-watch.py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


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
    if SESSION_KIND == "x11" and not win.veil:
        GLib.timeout_add(200, place_on_x11, win, "LPM menu", "center")
    # Veil mode: the layout centers the card. Compact mode on Wayland: a client cannot position
    # its own window, the compositor decides (most center it).
    init_gamepad()
    GLib.timeout_add(GAMEPAD_POLL_MS, tick_gamepad, win)
    game_watch = _load_prefix_watch().GameEndWatch(PREFIX_DIR)

    def check_game():
        if game_watch.game_ended():
            win.closing = True
            win.close()
            application.quit()
            return False
        return True

    GLib.timeout_add(1000, check_game)


def single_instance():
    """One menu at a time; the lock also tells the gamepad mouse to stay quiet while the menu is open."""
    import fcntl
    base = os.environ.get("XDG_RUNTIME_DIR") or "/tmp"
    handle = open(os.path.join(base, "lpm-game-menu.lock-%d" % os.getuid()), "w")
    try:
        fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        return None
    return handle


_lock = single_instance()
if _lock is None:
    sys.exit(0)
app = Gtk.Application(application_id="org.lpm.GameMenu")
app.connect("activate", on_activate)
sys.exit(app.run([sys.argv[0]]))
