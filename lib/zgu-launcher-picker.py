#!/usr/bin/env python3
# --- lpm launcher: home-made multi-entry picker, DEGRADED fallback of
# zgl-launcher-runtime.sh, with EXPLICIT Validate/Cancel -- GTK4/Libadwaita ---
#
# Usage: zgu-launcher-picker.py <title> <prompt> <validate_label> <cancel_label>
#                                 <entry1> [<entry2> ...]
# On stdout: the chosen label, ONLY on validation.
# Exit code:
#   0 -- validated (stdout contains the chosen label)
#   2 -- explicitly cancelled (Cancel/Escape/window close) -- nothing on stdout
#   1 -- error (GTK unavailable...) -- nothing on stdout
#
# Only used by zgl-launcher-runtime.sh in its fallback case (loading screen disabled for
# this game via ".lpm-no-loadingscreen", or lpm shortcut bypassed). zgl-launcher-orchestrator.sh
# shows the same picker EMBEDDED in its single window (see zgu-launcher-screen.py,
# "Gtk.Overlay"); GTK4 removed "set_keep_above" with no portable equivalent, so a
# separate window cannot be kept on top.
#
# In the fallback case there is NO loading-screen background behind it, so this is a
# NORMAL, DECORATED window (standard title bar and close button). Closing it with the
# cross is a normal way to cancel, handled exactly like the Cancel button (see
# on_close_request).
#
# Three inputs, each able to validate OR cancel on its own:
#   - Keyboard: Up/Down arrows to navigate, Enter to validate, Escape to cancel.
#   - Gamepad: read HERE in SDL2 (see "init_gamepad"/"tick_gamepad") -- Up/Down (D-pad or
#     left stick) move the selection, A validates, B cancels -- acting DIRECTLY on our own
#     GTK widgets, never via a key injected into the focused window. Injecting keys depends
#     on window-manager focus, which a new window may be denied ("focus stealing
#     prevention": the gamepad only responded after a click or several seconds), and
#     Wayland has no portable way to force focus from outside. Reading the gamepad in this
#     process works the same on X11 AND Wayland.
#   - Mouse: click to select a row (never to validate, single or double click), and two
#     visible "Validate"/"Cancel" buttons.

import sys
import os
import ctypes
import ctypes.util

try:
    import gi
    gi.require_version("Gtk", "4.0")
    from gi.repository import Gtk, Gdk, GLib
except Exception as exc:  # pragma: no cover - system dependency missing
    sys.stderr.write("zgu-launcher-picker: GTK4/PyGObject indisponible (%s)\n" % exc)
    sys.exit(1)

if len(sys.argv) < 6:
    sys.stderr.write(
        "Usage: zgu-launcher-picker.py <titre> <prompt> <label_valider> <label_annuler> "
        "<entree1> [<entree2> ...]\n"
    )
    sys.exit(1)

TITLE = sys.argv[1]
PROMPT = sys.argv[2]
VALIDATE_LABEL = sys.argv[3]
CANCEL_LABEL = sys.argv[4]
ENTRIES = sys.argv[5:]

WIN_WIDTH, WIN_HEIGHT = 900, 680

# Size AND color of the list labels use direct Pango markup (span size=..., foreground=...),
# never CSS: a user gtk.css (USER priority) can override an application CSS "font-size" but
# never a Pango attribute set on the text. Same for color: these Gtk.Labels have no CSS
# class of their own and only inherit "color" from "listbox row", and inheritance loses to
# an explicit rule the system theme sets on the "label" node (seen as black text on white).
ENTRY_FONT_SIZE_PX = 25

# Fixed dark theme, white text, green Validate button: INDEPENDENT of the current GTK/desktop
# theme (a Linux without a desktop environment often has no GTK theme at all), for an
# identical look everywhere. Same palette as the embedded picker of the loading screen (see
# zgu-launcher-screen.py), applied here to the whole window since there is no black
# background behind to extend visually.
CSS = b"""
window, .lpm-picker-root {
    background-color: #1a1a1a;
    color: #ffffff;
}
.lpm-picker-title {
    font-weight: bold;
    font-size: 24px;
    color: #ffffff;
}
.lpm-picker-prompt {
    font-size: 20px;
    color: #cccccc;
}
/* Noeud CSS "list", PAS "listbox" -- le widget est "Gtk.ListBox" mais son noeud CSS en
   GTK4 s'appelle "list" ; le selecteur "listbox" ne correspondait a rien du tout, d'ou le
   fond reste blanc malgre les regles ci-dessous (symptome observe). */
list {
    background-color: transparent;
}
list row {
    padding: 8px 14px;
    background-color: transparent;
    color: #ffffff;
}
list row:selected {
    background-color: #3a6ea5;
    border-radius: 8px;
    color: #ffffff;
}
.lpm-picker-button {
    font-size: 20px;
}
/* Bordure : couleur du fond du bouton eclaircie uniformement (+0x20 par canal), jamais le
   blanc par defaut du theme --. "border" en raccourci complet
   (style + largeur + couleur), meme logique que "background-image: none" plus haut : ne
   laisser aucune propriete de bordure heritee du theme. */
.lpm-picker-validate-button {
    background-image: none;
    background-color: #2e7d32;
    border: 1px solid #4e9d52;
    color: #ffffff;
}
.lpm-picker-validate-button:hover {
    background-image: none;
    background-color: #388e3c;
    border: 1px solid #58ae5c;
}
.lpm-picker-cancel-button {
    background-image: none;
    background-color: #3a3a3a;
    border: 1px solid #5a5a5a;
    color: #ffffff;
}
.lpm-picker-cancel-button:hover {
    background-image: none;
    background-color: #474747;
    border: 1px solid #676767;
}
"""


def _entry_markup(text):
    escaped = GLib.markup_escape_text(text)
    pango_units = int(round(ENTRY_FONT_SIZE_PX * 0.75 * 1024))  # px (96dpi) -> pt*1024
    return '<span size="%d" foreground="#ffffff">%s</span>' % (pango_units, escaped)


# --- Gamepad -> direct picker navigation in SDL2 (see file header). Vertical only,
# single selection: no LEFT/RIGHT and no X/L1/R1 buttons. ---
GAMEPAD_POLL_MS = 20
GAMEPAD_AXIS_THRESHOLD = int(32767 * 0.5)  # 50% of the axis travel

SDL_INIT_JOYSTICK = 0x00000200
SDL_INIT_GAMECONTROLLER = 0x00002000
SDL_INIT_EVENTS = 0x00004000
SDL_CONTROLLER_BUTTON_A = 0
SDL_CONTROLLER_BUTTON_B = 1
SDL_CONTROLLER_BUTTON_DPAD_UP = 11
SDL_CONTROLLER_BUTTON_DPAD_DOWN = 12
SDL_CONTROLLER_AXIS_LEFTY = 1

GAMECONTROLLERDB_PATH = os.path.join(
    os.path.dirname(os.path.abspath(__file__)), "data", "gamecontrollerdb.txt"
)

_sdl = None
_gamepad_pads = []
_gamepad_prev_a = {}
_gamepad_prev_b = {}
_gamepad_prev_dpad_y = {}
_gamepad_prev_stick_y = {}


def _load_sdl2():
    names = []
    found = ctypes.util.find_library("SDL2")
    if found:
        names.append(found)
    names += ["libSDL2-2.0.so.0", "libSDL2-2.0.so", "SDL2"]
    for name in names:
        try:
            return ctypes.CDLL(name)
        except OSError:
            continue
    return None


def init_gamepad():
    """Fully best-effort: a missing libSDL2 or no detected gamepad must NEVER prevent this
    picker from working with keyboard/mouse. Gamepad reading is part of the window itself,
    so it cannot simply exit like a dedicated script could."""
    global _sdl
    try:
        sdl = _load_sdl2()
        if sdl is None:
            return
        os.environ.setdefault("SDL_VIDEODRIVER", "dummy")
        os.environ.setdefault("SDL_JOYSTICK_ALLOW_BACKGROUND_EVENTS", "1")
        sdl.SDL_Init.restype = ctypes.c_int
        sdl.SDL_Init.argtypes = [ctypes.c_uint32]
        sdl.SDL_NumJoysticks.restype = ctypes.c_int
        sdl.SDL_IsGameController.restype = ctypes.c_int
        sdl.SDL_IsGameController.argtypes = [ctypes.c_int]
        sdl.SDL_GameControllerOpen.restype = ctypes.c_void_p
        sdl.SDL_GameControllerOpen.argtypes = [ctypes.c_int]
        sdl.SDL_GameControllerUpdate.restype = None
        sdl.SDL_GameControllerGetButton.restype = ctypes.c_uint8
        sdl.SDL_GameControllerGetButton.argtypes = [ctypes.c_void_p, ctypes.c_int]
        sdl.SDL_GameControllerGetAxis.restype = ctypes.c_int16
        sdl.SDL_GameControllerGetAxis.argtypes = [ctypes.c_void_p, ctypes.c_int]
        add_mappings = getattr(sdl, "SDL_GameControllerAddMappingsFromFile", None)
        if add_mappings is not None:
            add_mappings.restype = ctypes.c_int
            add_mappings.argtypes = [ctypes.c_char_p]
        if sdl.SDL_Init(SDL_INIT_JOYSTICK | SDL_INIT_GAMECONTROLLER | SDL_INIT_EVENTS) != 0:
            return
        if add_mappings is not None and os.path.isfile(GAMECONTROLLERDB_PATH):
            add_mappings(GAMECONTROLLERDB_PATH.encode("utf-8"))
        for i in range(sdl.SDL_NumJoysticks()):
            if sdl.SDL_IsGameController(i):
                handle = sdl.SDL_GameControllerOpen(i)
                if handle:
                    _gamepad_pads.append(handle)
                    _gamepad_prev_a[handle] = 0
                    _gamepad_prev_b[handle] = 0
                    _gamepad_prev_dpad_y[handle] = 0
                    _gamepad_prev_stick_y[handle] = 0
        _sdl = sdl
    except Exception:
        _sdl = None


def tick_gamepad():
    if _sdl is None or not _gamepad_pads or win is None:
        return True
    _sdl.SDL_GameControllerUpdate()
    for pad in _gamepad_pads:
        a_value = _sdl.SDL_GameControllerGetButton(pad, SDL_CONTROLLER_BUTTON_A)
        if a_value and not _gamepad_prev_a[pad]:
            win.gamepad_validate()
        _gamepad_prev_a[pad] = a_value

        b_value = _sdl.SDL_GameControllerGetButton(pad, SDL_CONTROLLER_BUTTON_B)
        if b_value and not _gamepad_prev_b[pad]:
            win.gamepad_cancel()
        _gamepad_prev_b[pad] = b_value

        dpad_up = _sdl.SDL_GameControllerGetButton(pad, SDL_CONTROLLER_BUTTON_DPAD_UP)
        dpad_down = _sdl.SDL_GameControllerGetButton(pad, SDL_CONTROLLER_BUTTON_DPAD_DOWN)
        dpad_dir = -1 if dpad_up else (1 if dpad_down else 0)
        if dpad_dir != _gamepad_prev_dpad_y[pad] and dpad_dir != 0:
            win.gamepad_move_selection(dpad_dir)
        _gamepad_prev_dpad_y[pad] = dpad_dir

        stick_y = _sdl.SDL_GameControllerGetAxis(pad, SDL_CONTROLLER_AXIS_LEFTY)
        if stick_y <= -GAMEPAD_AXIS_THRESHOLD:
            stick_dir = -1
        elif stick_y >= GAMEPAD_AXIS_THRESHOLD:
            stick_dir = 1
        else:
            stick_dir = 0
        if stick_dir != _gamepad_prev_stick_y[pad] and stick_dir != 0:
            win.gamepad_move_selection(stick_dir)
        _gamepad_prev_stick_y[pad] = stick_dir
    return True


class PickerWindow(Gtk.Window):
    def __init__(self):
        super().__init__(title=TITLE or VALIDATE_LABEL)
        self.selected = None
        self.cancelled = False

        self.set_default_size(WIN_WIDTH, WIN_HEIGHT)
        # Normal decorated window (see file header): Gtk.Window default, nothing to disable.

        self.connect("close-request", self.on_close_request)
        key_ctrl = Gtk.EventControllerKey()
        key_ctrl.connect("key-pressed", self.on_key_pressed)
        self.add_controller(key_ctrl)

        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=10)
        # "lpm-picker-root" in ADDITION to the "window" selector in the CSS: this Box covers
        # the whole client area, so its own background guarantees the color even if a
        # minimal/themeless environment makes the "window" node background unreliable.
        box.add_css_class("lpm-picker-root")
        box.set_margin_top(16)
        box.set_margin_bottom(16)
        box.set_margin_start(16)
        box.set_margin_end(16)
        self.set_child(box)

        if TITLE:
            title_label = Gtk.Label(label=TITLE, xalign=0)
            title_label.add_css_class("lpm-picker-title")
            box.append(title_label)

        if PROMPT:
            prompt_label = Gtk.Label(label=PROMPT, xalign=0, wrap=True)
            prompt_label.add_css_class("lpm-picker-prompt")
            box.append(prompt_label)

        scroll = Gtk.ScrolledWindow()
        scroll.set_policy(Gtk.PolicyType.NEVER, Gtk.PolicyType.AUTOMATIC)
        scroll.set_vexpand(True)
        box.append(scroll)

        self.listbox = Gtk.ListBox()
        self.listbox.set_selection_mode(Gtk.SelectionMode.BROWSE)
        # "row-activated" is NOT connected (see file header): the mouse only selects,
        # never validates (single or double click).
        listbox_key_ctrl = Gtk.EventControllerKey()
        listbox_key_ctrl.connect("key-pressed", self.on_listbox_key_pressed)
        self.listbox.add_controller(listbox_key_ctrl)
        scroll.set_child(self.listbox)

        first_row = None
        for entry in ENTRIES:
            row = Gtk.ListBoxRow()
            label = Gtk.Label(xalign=0)
            label.set_markup(_entry_markup(entry))
            row.set_child(label)
            self.listbox.append(row)
            if first_row is None:
                first_row = row

        button_box = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8)
        button_box.set_halign(Gtk.Align.END)

        cancel_button = Gtk.Button(label=CANCEL_LABEL)
        cancel_button.add_css_class("lpm-picker-button")
        cancel_button.add_css_class("lpm-picker-cancel-button")
        cancel_button.connect("clicked", self.on_cancel_clicked)
        button_box.append(cancel_button)

        # "lpm-picker-validate-button" (our own colors), never "suggested-action" (see file
        # header): independent of any desktop theme.
        validate_button = Gtk.Button(label=VALIDATE_LABEL)
        validate_button.add_css_class("lpm-picker-button")
        validate_button.add_css_class("lpm-picker-validate-button")
        validate_button.connect("clicked", self.on_validate_clicked)
        button_box.append(validate_button)

        box.append(button_box)

        if first_row is not None:
            self.listbox.select_row(first_row)
        self.listbox.grab_focus()

    def on_close_request(self, _window):
        # Decorated window: closing with the cross cancels, exactly like the Cancel button.
        self.cancelled = True
        loop.quit()
        return False  # let the actual close proceed normally

    def on_key_pressed(self, _ctrl, keyval, _keycode, _state):
        if keyval == Gdk.KEY_Escape:
            self.cancelled = True
            loop.quit()
            return True
        return False

    def on_listbox_key_pressed(self, _ctrl, keyval, _keycode, _state):
        if keyval in (Gdk.KEY_Return, Gdk.KEY_KP_Enter):
            self._validate_row(self.listbox.get_selected_row())
            return True
        return False

    def on_validate_clicked(self, _button):
        self._validate_row(self.listbox.get_selected_row())

    def on_cancel_clicked(self, _button):
        self.cancelled = True
        loop.quit()

    def _validate_row(self, row):
        if row is None:
            return
        # "get_text()", never "get_label()" -- see zgu-launcher-screen.py for the
        # distinction (only "get_text()" strips the Pango markup).
        label_widget = row.get_child()
        self.selected = label_widget.get_text()
        loop.quit()

    # --- Gamepad navigation (see init_gamepad()/tick_gamepad() above): direct actions
    # on our own widgets, never a key injected from outside. ---
    def gamepad_move_selection(self, delta):
        row = self.listbox.get_selected_row()
        idx = row.get_index() if row is not None else -1
        new_row = self.listbox.get_row_at_index(idx + delta)
        if new_row is not None:
            self.listbox.select_row(new_row)
            new_row.grab_focus()

    def gamepad_validate(self):
        self._validate_row(self.listbox.get_selected_row())

    def gamepad_cancel(self):
        self.cancelled = True
        loop.quit()


loop = None
win = None


def main():
    global loop, win
    Gtk.init()

    style_provider = Gtk.CssProvider()
    style_provider.load_from_data(CSS)
    Gtk.StyleContext.add_provider_for_display(
        Gdk.Display.get_default(),
        style_provider,
        Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION,
    )

    win = PickerWindow()
    win.present()

    # "GLib.idle_add", NOT a direct call: "init_gamepad()" loads libSDL2 via ctypes, which
    # can be slow (or block) in a restricted environment (for a Flatpak Lutris this runs
    # inside its sandbox, see zgl-launcher-runtime.sh). A direct call before "loop.run()"
    # would delay the first display: "present()" is requested above but only reaches the
    # display server once the event loop runs (otherwise nothing appeared at all). "idle_add"
    # lets the window show first, then loads the gamepad.
    GLib.idle_add(init_gamepad)
    GLib.timeout_add(GAMEPAD_POLL_MS, tick_gamepad)

    loop = GLib.MainLoop()
    loop.run()

    if win.cancelled:
        sys.exit(2)
    if win.selected:
        print(win.selected)
        sys.exit(0)
    sys.exit(1)


if __name__ == "__main__":
    main()
