#!/usr/bin/env python3
# --- lpm launcher: single fullscreen window (black background + splash + indicator) AND,
# when needed, the LPM Launcher picker (multi-entry) -- GTK4/Libadwaita ---
#
# Usage: zgu-launcher-screen.py <control_file> [<indicator_text>] [<logo_png>] [<no_label>] [<has_banner>]
#
# One single GTK4 window shows either the background or the picker, replacing the former
# separate zgu-launcher-blackscreen.py and zgu-launcher-picker.py (picker as a second
# window on top). GTK4 removed "set_keep_above"/"set_skip_taskbar_hint"/
# "set_skip_pager_hint" (legacy X11 window-manager hints, no portable GTK4 equivalent on
# X11 or Wayland), so stacking two windows can no longer work reliably. Here the picker is
# just a widget shown/hidden in a "Gtk.Overlay" over the background.
#
# zgu-launcher-picker.py still exists separately as the fallback picker of
# zgl-launcher-runtime.sh, used ONLY when this script (the loading screen) did not run at
# all (loading screen disabled for this game via ".lpm-no-loadingscreen", or lpm shortcut
# bypassed). With no background behind it, it is shown as a normal DECORATED window. Both
# share the same interaction (keyboard/gamepad/mouse, Validate/Cancel) but stay two files:
# lib/*.py scripts are self-contained with no cross-imports, so the list/button building
# logic is duplicated rather than extracted.
#
# <control_file>: text file of FOUR lines, re-read in a loop (every 150ms):
#   Line 1 -- background: "NONE" (black only), "<path>" (centered PNG image), or "STOP"
#     (the script exits cleanly, lines 2-4 ignored).
#   Line 2 -- the "loading" indicator (text + spinner, bottom right): "IND_SHOW"/"IND_HIDE".
#   Line 3 -- the title (game name), shown at the top ONLY if no logo (<logo_png>) was given.
#   Line 4 -- the label of the chosen entry (once the picker is resolved), shown in the
#     band between the logo and the banner.
#
# Picker protocol: TWO separate files derived from <control_file>, never mixed with the 4
# lines above (zgl-launcher-runtime.sh also rewrites lines 2 and 3, so mixing could corrupt
# reads/writes):
#   "<control_file>.picker-req" -- written by zgl-launcher-orchestrator.sh when a picker
#     must be shown. Five or more lines: TITLE, PROMPT, VALIDATE_LABEL, CANCEL_LABEL, then
#     one entry per line. Read at the same polling as the control file: once it appears
#     (and no picker is already shown), its content fills the list and the picker card
#     becomes visible; the file is then deleted (processed once).
#   "<control_file>.picker-res" -- written by THIS script once the user validated or
#     cancelled: line 1 = "OK" or "CANCEL", line 2 (only if "OK") = the chosen label.
#     The orchestrator waits for this file to appear (its own polling).
#
# The indicator is drawn in pure Cairo (no Gtk.Spinner): that widget does not render at
# all in a minimal environment without a complete GTK theme.
#
# Transparency: no RGBA visual is requested ("get_rgba_visual"/"set_visual" no longer exist
# in GTK4). Not needed: drawing ALWAYS paints an opaque black first ("OPERATOR_SOURCE" +
# alpha=1), so the window never has to be really transparent.

import math
import random
import sys
import os
import time
import ctypes
import ctypes.util

try:
    import gi
    gi.require_version("Gtk", "4.0")
    from gi.repository import Gtk, Gdk, GLib
    import cairo
except Exception as exc:  # pragma: no cover - system dependency missing
    sys.stderr.write("zgu-launcher-screen: GTK4/PyGObject indisponible (%s)\n" % exc)
    sys.exit(1)

if len(sys.argv) < 2:
    sys.stderr.write("Usage: zgu-launcher-screen.py <control_file> [<indicator_text>] [<logo_png>] [<no_label>] [<has_banner>]\n")
    sys.exit(1)

CONTROL_FILE = sys.argv[1]
INDICATOR_TEXT = sys.argv[2] if len(sys.argv) > 2 else ""
LOGO_PATH = sys.argv[3] if len(sys.argv) > 3 else ""
NO_LABEL = (sys.argv[4] if len(sys.argv) > 4 else "0") == "1"
HAS_BANNER = (sys.argv[5] if len(sys.argv) > 5 else "0") == "1"
POLL_MS = 150
SPIN_TICK_MS = 60

PICKER_REQUEST_FILE = CONTROL_FILE + ".picker-req"
PICKER_RESULT_FILE = CONTROL_FILE + ".picker-res"

SPINNER_SIZE = 20
MARGIN_RIGHT = 28
MARGIN_BOTTOM = 24
TEXT_SPINNER_GAP = 10
FONT_SIZE = 16

ENTRY_LABEL_FONT_SIZE = 30

# --- Gamepad help (bottom left, two lines): combos already handled by
# zgu-gamepad-alttab-watcher.py / zgu-gamepad-exit-watcher.py, shown only if a gamepad is
# detected and the picker is not on screen. Icons drawn in cairo (no image file).
# Translated labels are passed by the orchestrator (env variables). ---
HELP_ALTTAB_TEXT = os.environ.get("LPM_HELP_ALTTAB", "").strip()
HELP_QUIT_TEXT = os.environ.get("LPM_HELP_QUIT", "").strip()
# Single-press keys during the combo hold (see zgu-gamepad-alttab-watcher.py):
# D-pad up = F4, D-pad down = Alt+Enter, Select = F11.
HELP_F4_TEXT = os.environ.get("LPM_HELP_F4", "").strip()
HELP_ALTENTER_TEXT = os.environ.get("LPM_HELP_ALTENTER", "").strip()
HELP_F11_TEXT = os.environ.get("LPM_HELP_F11", "").strip()
HELP_MARGIN_LEFT = 28
HELP_LINE_HEIGHT = 34
HELP_FONT_SIZE = 15
HELP_PILL_FONT_SIZE = 12
HELP_PILL_HEIGHT = 22
HELP_GAP = 6
# Height taken from the banner area when the help is shown (1 line + margin).
# One line at a time, alternating with a fade to black between lines:
# HELP_PERIOD_S = total duration of a line (fades included), HELP_FADE_S = duration of each fade.
HELP_PERIOD_S = 4.75
HELP_FADE_S = 0.35
help_start = [None]
HELP_RESERVED_HEIGHT = MARGIN_BOTTOM + HELP_LINE_HEIGHT + 10
# Room left on the right for "Loading" + spinner (help text must never reach it).
HELP_RIGHT_RESERVED = 260

PICKER_BOX_HEIGHT = 680
PICKER_BOX_WIDTH = 900
TOP_ZONE_MAX_WIDTH_FRACTION = 0.29
TOP_ZONE_MIN_MARGIN = 40
LOGO_VERTICAL_OFFSET = 45
TOP_TITLE_FONT_SIZE = 84
TOP_TITLE_BOTTOM_PADDING = 48

LABEL_ZONE_HEIGHT = 90
LABEL_ZONE_TOP_PADDING = 16

CURSOR_IDLE_S = 1.0

MAX_BANNER_WIDTH_FRACTION = 0.80
BANNER_VERTICAL_LIFT = 30
BANNER_EXTRA_LIFT_NO_LABEL = 15

# Vertical offset of the picker from the exact screen center: a bit more room above,
# where the logo/title are shown.
PICKER_VERTICAL_OFFSET = 50

# Size AND color of the list labels use direct Pango markup (span size=..., foreground=...),
# never CSS: a user gtk.css (USER priority) can override an application CSS "font-size" but
# never a Pango attribute set on the text. Same for color: these Gtk.Labels have no CSS
# class of their own and only inherit "color" from ".lpm-picker-card listbox row", and
# inheritance loses to any explicit rule the system theme sets on the "label" node (seen as
# black text on white despite the "row" rule).
ENTRY_FONT_SIZE_PX = 25

is_wayland = (os.environ.get("XDG_SESSION_TYPE", "").lower() == "wayland") or bool(
    os.environ.get("WAYLAND_DISPLAY")
)

show_indicator = [True]
spinner_angle = [0.0]
title_text = [""]
entry_label_text = [""]

CSS = b"""
.lpm-picker-card {
    background-color: #1a1a1a;
    color: #ffffff;
    border: 2px solid #2f2f2f;
    border-radius: 10px;
    padding: 16px;
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
.lpm-picker-card list {
    background-color: transparent;
}
.lpm-picker-card list row {
    padding: 8px 14px;
    background-color: transparent;
    color: #ffffff;
}
.lpm-picker-card list row:selected {
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


def draw_spinner(cr, cx, cy, radius, angle):
    """8 rotating fading spokes."""
    n = 8
    cr.set_line_width(2.4)
    cr.set_line_cap(cairo.LINE_CAP_ROUND)
    for i in range(n):
        a = angle + i * (2 * math.pi / n)
        alpha = (i + 1) / n
        cr.set_source_rgba(1, 1, 1, alpha)
        cr.move_to(cx + (radius - 3) * math.cos(a), cy + (radius - 3) * math.sin(a))
        cr.line_to(cx + radius * math.cos(a), cy + radius * math.sin(a))
        cr.stroke()


# --- Gamepad -> direct picker navigation in SDL2, inside this process. Injecting keys
# (xdotool/ydotool) into the focused window depends on window-manager focus, which a new
# window may be denied ("focus stealing prevention": the gamepad only responded after a
# click or several seconds), and Wayland has no portable way to force focus from outside.
# Reading the gamepad HERE and acting directly on our own GTK widgets works the same on X11
# AND Wayland. Vertical only, single selection: no LEFT/RIGHT and no X/L1/R1 buttons.
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
    """Fully best-effort: a missing libSDL2 or no detected gamepad must NEVER prevent the
    loading screen/picker from working with keyboard/mouse. Gamepad reading is part of
    the window itself, so it cannot simply exit like a dedicated script could."""
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
    if _sdl is None or not _gamepad_pads:
        return True
    _sdl.SDL_GameControllerUpdate()
    for pad in _gamepad_pads:
        a_value = _sdl.SDL_GameControllerGetButton(pad, SDL_CONTROLLER_BUTTON_A)
        if a_value and not _gamepad_prev_a[pad]:
            for win in windows:
                if win.picker_visible:
                    win.gamepad_validate()
        _gamepad_prev_a[pad] = a_value

        b_value = _sdl.SDL_GameControllerGetButton(pad, SDL_CONTROLLER_BUTTON_B)
        if b_value and not _gamepad_prev_b[pad]:
            for win in windows:
                if win.picker_visible:
                    win.gamepad_cancel()
        _gamepad_prev_b[pad] = b_value

        dpad_up = _sdl.SDL_GameControllerGetButton(pad, SDL_CONTROLLER_BUTTON_DPAD_UP)
        dpad_down = _sdl.SDL_GameControllerGetButton(pad, SDL_CONTROLLER_BUTTON_DPAD_DOWN)
        dpad_dir = -1 if dpad_up else (1 if dpad_down else 0)
        if dpad_dir != _gamepad_prev_dpad_y[pad] and dpad_dir != 0:
            for win in windows:
                if win.picker_visible:
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
            for win in windows:
                if win.picker_visible:
                    win.gamepad_move_selection(stick_dir)
        _gamepad_prev_stick_y[pad] = stick_dir
    return True


class ScreenWindow(Gtk.Window):
    def __init__(self, monitor, geom):
        super().__init__()
        self.set_decorated(False)
        # Window title (tooltip/taskbar preview) = game name, passed by the orchestrator;
        # without it the window appears unnamed.
        window_title = os.environ.get("LPM_WINDOW_TITLE", "").strip()
        if window_title:
            self.set_title(window_title)
        self.monitor = monitor
        self.monitor_geom = geom

        # --- Picker (see file header): built once here, hidden by default -- a centered
        # "card" over the background, never a second window. ---
        self.picker_visible = False
        self.picker_entries = []  # [(row, label_text), ...]
        self.picker_listbox = None

        self.overlay = Gtk.Overlay()
        self.set_child(self.overlay)

        self.drawing_area = Gtk.DrawingArea()
        self.drawing_area.set_hexpand(True)
        self.drawing_area.set_vexpand(True)
        # NO extra "user_data" here: "self.on_draw" is already a bound method, so GTK4 would
        # pass a 5th argument ("None") that its signature ("area, cr, width, height") does
        # not expect -- an error on EVERY frame, invisible because this script's stdout/stderr
        # are redirected to /dev/null by zgl-launcher-orchestrator.sh (nothing gets drawn).
        self.drawing_area.set_draw_func(self.on_draw)
        self.overlay.set_child(self.drawing_area)

        self.picker_card = self._build_picker_card()
        self.picker_card.set_visible(False)
        self.overlay.add_overlay(self.picker_card)

        # Logo (see file header): loaded once, size/position also computed once.
        self.logo_surface = None
        self.logo_draw_x = 0
        self.logo_draw_y = 0
        self.logo_draw_w = 0
        self.logo_draw_h = 0
        self.zone_top_y = max(0, (geom.height - PICKER_BOX_HEIGHT) / 2)

        if LOGO_PATH and os.path.isfile(LOGO_PATH):
            try:
                self.logo_surface = cairo.ImageSurface.create_from_png(LOGO_PATH)
            except Exception:
                self.logo_surface = None

        top_zone_bottom = self.zone_top_y
        top_zone_expanded = NO_LABEL and not HAS_BANNER
        if top_zone_expanded:
            top_zone_bottom = geom.height

        if self.logo_surface is not None:
            usable_h = max(0, top_zone_bottom - 2 * TOP_ZONE_MIN_MARGIN)
            img_w = self.logo_surface.get_width()
            img_h = self.logo_surface.get_height()
            max_w = geom.width * TOP_ZONE_MAX_WIDTH_FRACTION
            max_h = usable_h if usable_h > 0 else geom.height * 0.2
            scale = min(max_w / img_w, max_h / img_h)
            self.logo_draw_w = img_w * scale
            self.logo_draw_h = img_h * scale
            self.logo_draw_x = (geom.width - self.logo_draw_w) / 2
            offset = 0 if top_zone_expanded else LOGO_VERTICAL_OFFSET
            draw_y = (top_zone_bottom - self.logo_draw_h) / 2 + offset
            max_draw_y = top_zone_bottom - self.logo_draw_h - TOP_ZONE_MIN_MARGIN
            self.logo_draw_y = max(TOP_ZONE_MIN_MARGIN, min(draw_y, max_draw_y))

        self.title_zone_bottom = top_zone_bottom
        self.title_centered = NO_LABEL

        self.label_zone_top = self.zone_top_y
        self.label_zone_bottom = self.zone_top_y + (0 if NO_LABEL else LABEL_ZONE_HEIGHT)
        self.banner_zone_top = self.label_zone_bottom
        self.banner_zone_height = max(0, geom.height - self.banner_zone_top)

        self.current_surface = None

        # Auto-hidden mouse cursor -- Gtk.EventControllerMotion replaces GTK3's
        # "motion-notify-event" (removed in GTK4).
        motion = Gtk.EventControllerMotion()
        motion.connect("motion", self.on_motion)
        self.add_controller(motion)
        self.last_motion_ts = time.monotonic()
        self.cursor_hidden = False

        # Escape, handled at WINDOW level (whatever widget has focus) -- cancels the picker
        # if shown, otherwise ignored (the background has nothing to cancel).
        key_ctrl = Gtk.EventControllerKey()
        key_ctrl.connect("key-pressed", self.on_key_pressed)
        self.add_controller(key_ctrl)

        # --- Re-asserting focus/foreground: see file header. Not a fixed-interval timer (it
        # would let a competing window show for up to a whole interval, a guaranteed
        # flicker). Instead listen to the native GTK "is-active" property: as soon as THIS
        # window stops being active (typically the game window took activation), call
        # "present()" again. This is the fastest reaction with portable GTK4 primitives (no
        # "always on top" hint exists, see above), but no portable method (X11 or Wayland)
        # can prevent the loss of activation itself: a brief display of the other window
        # while the compositor handles the notification remains possible. This is a real
        # limit of modern window systems (focus-stealing prevention).
        self.connect("notify::is-active", self.on_active_changed)

        self.fullscreen_on_monitor(monitor)

    def on_active_changed(self, *_args):
        # Disabled by default, see "keep_focus_env" in zgl-launcher-orchestrator.sh: forcibly
        # taking focus back minimized fullscreen Wine games. Only active if the game has a
        # ".lpm-keep-focus" file (passed via LPM_KEEP_FOCUS).
        if os.environ.get("LPM_KEEP_FOCUS") != "1":
            return
        if not self.get_property("is-active"):
            self.present()

    # --- Picker construction (same as zgu-launcher-picker.py, as a widget rather than a
    # separate window -- see file header) ---
    def _build_picker_card(self):
        card = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=10)
        card.add_css_class("lpm-picker-card")
        card.set_halign(Gtk.Align.CENTER)
        card.set_valign(Gtk.Align.CENTER)
        card.set_margin_top(PICKER_VERTICAL_OFFSET)
        card.set_size_request(PICKER_BOX_WIDTH, PICKER_BOX_HEIGHT)

        self.picker_title_label = Gtk.Label(xalign=0, visible=False)
        self.picker_title_label.add_css_class("lpm-picker-title")
        card.append(self.picker_title_label)

        self.picker_prompt_label = Gtk.Label(xalign=0, visible=False, wrap=True)
        self.picker_prompt_label.add_css_class("lpm-picker-prompt")
        card.append(self.picker_prompt_label)

        scroll = Gtk.ScrolledWindow()
        scroll.set_policy(Gtk.PolicyType.NEVER, Gtk.PolicyType.AUTOMATIC)
        scroll.set_vexpand(True)
        card.append(scroll)

        self.picker_listbox = Gtk.ListBox()
        self.picker_listbox.set_selection_mode(Gtk.SelectionMode.BROWSE)
        # "row-activated" is NOT connected -- a click (single or double) only selects,
        # never validates directly.
        listbox_key_ctrl = Gtk.EventControllerKey()
        listbox_key_ctrl.connect("key-pressed", self.on_listbox_key_pressed)
        self.picker_listbox.add_controller(listbox_key_ctrl)
        scroll.set_child(self.picker_listbox)

        button_box = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8)
        button_box.set_halign(Gtk.Align.END)

        self.picker_cancel_button = Gtk.Button()
        self.picker_cancel_button.add_css_class("lpm-picker-button")
        self.picker_cancel_button.add_css_class("lpm-picker-cancel-button")
        self.picker_cancel_button.connect("clicked", self.on_picker_cancel_clicked)
        button_box.append(self.picker_cancel_button)

        # "lpm-picker-validate-button" (our own colors, not "suggested-action", an Adwaita/
        # theme semantic class that would make the button depend on the desktop
        # environment): fixed dark theme, white text, green Validate button, fully
        # independent of the system theme or its absence (Linux without a desktop).
        self.picker_validate_button = Gtk.Button()
        self.picker_validate_button.add_css_class("lpm-picker-button")
        self.picker_validate_button.add_css_class("lpm-picker-validate-button")
        self.picker_validate_button.connect("clicked", self.on_picker_validate_clicked)
        button_box.append(self.picker_validate_button)

        card.append(button_box)
        return card

    def show_picker(self, title, prompt, validate_label, cancel_label, entries):
        self.picker_title_label.set_label(title)
        self.picker_title_label.set_visible(bool(title))
        self.picker_prompt_label.set_label(prompt)
        self.picker_prompt_label.set_visible(bool(prompt))
        self.picker_cancel_button.set_label(cancel_label)
        self.picker_validate_button.set_label(validate_label)

        while True:
            row = self.picker_listbox.get_row_at_index(0)
            if row is None:
                break
            self.picker_listbox.remove(row)

        first_row = None
        for entry in entries:
            row = Gtk.ListBoxRow()
            label = Gtk.Label(xalign=0)
            label.set_markup(_entry_markup(entry))
            row.set_child(label)
            self.picker_listbox.append(row)
            if first_row is None:
                first_row = row

        if first_row is not None:
            self.picker_listbox.select_row(first_row)

        self.picker_visible = True
        self.picker_card.set_visible(True)
        self.picker_listbox.grab_focus()

    def hide_picker(self):
        self.picker_visible = False
        self.picker_card.set_visible(False)

    def _write_picker_result(self, ok, label=""):
        try:
            with open(PICKER_RESULT_FILE, "w") as f:
                if ok:
                    f.write("OK\n" + label + "\n")
                else:
                    f.write("CANCEL\n")
        except OSError:
            pass
        self.hide_picker()

    def on_picker_validate_clicked(self, _button):
        self._validate_selected_row()

    def on_picker_cancel_clicked(self, _button):
        self._write_picker_result(False)

    def _validate_selected_row(self):
        row = self.picker_listbox.get_selected_row()
        if row is None:
            return
        # "get_text()", NEVER "get_label()" -- "get_label()" would return the raw Pango
        # markup ("<span size=...>...</span>"); "get_text()" returns the displayed text
        # with the markup stripped.
        label_widget = row.get_child()
        self._write_picker_result(True, label_widget.get_text())

    # --- Gamepad navigation (see init_gamepad()/tick_gamepad() above): direct actions
    # on our own widgets, never a key injected from outside. ---
    def gamepad_move_selection(self, delta):
        row = self.picker_listbox.get_selected_row()
        idx = row.get_index() if row is not None else -1
        new_row = self.picker_listbox.get_row_at_index(idx + delta)
        if new_row is not None:
            self.picker_listbox.select_row(new_row)
            new_row.grab_focus()

    def gamepad_validate(self):
        if not self.cursor_hidden:
            self.hide_cursor()
        self._validate_selected_row()

    def gamepad_cancel(self):
        if not self.cursor_hidden:
            self.hide_cursor()
        self._write_picker_result(False)

    def on_listbox_key_pressed(self, _ctrl, keyval, _keycode, _state):
        if keyval in (Gdk.KEY_Return, Gdk.KEY_KP_Enter):
            if not self.cursor_hidden:
                self.hide_cursor()
            self._validate_selected_row()
            return True
        return False

    def on_key_pressed(self, _ctrl, keyval, _keycode, _state):
        if self.picker_visible and not self.cursor_hidden:
            self.hide_cursor()
        if keyval == Gdk.KEY_Escape and self.picker_visible:
            self._write_picker_result(False)
            return True
        return False

    def on_motion(self, _ctrl, _x, _y):
        self.last_motion_ts = time.monotonic()
        if self.cursor_hidden:
            self.show_cursor()

    def show_cursor(self):
        self.set_cursor(None)
        self.cursor_hidden = False

    def hide_cursor(self):
        self.set_cursor(Gdk.Cursor.new_from_name("none"))
        self.cursor_hidden = True

    def maybe_hide_cursor_if_idle(self):
        if not self.cursor_hidden and (time.monotonic() - self.last_motion_ts) >= CURSOR_IDLE_S:
            self.hide_cursor()

    # --- Drawing (Gtk.DrawingArea.set_draw_func replaces GTK3's "draw" signal): "cr, width,
    # height" are provided directly, no need for "get_allocation()". ---
    def on_draw(self, _area, cr, width, height):
        cr.set_operator(cairo.OPERATOR_SOURCE)
        cr.set_source_rgba(0, 0, 0, 1)
        cr.paint()
        help_visible = self.gamepad_help_visible()
        if not help_visible:
            help_start[0] = None  # next appearance: restart from black (visible fade-in)
        banner_zone_height = self.banner_zone_height - (HELP_RESERVED_HEIGHT if help_visible else 0)
        if self.current_surface is not None and banner_zone_height > 0:
            cr.set_operator(cairo.OPERATOR_OVER)
            img_w = self.current_surface.get_width()
            img_h = self.current_surface.get_height()
            scale = min(
                1.0,
                (width * MAX_BANNER_WIDTH_FRACTION) / img_w,
                banner_zone_height / img_h,
            )
            off_x = (width - img_w * scale) / 2
            off_y = self.banner_zone_top + (banner_zone_height - img_h * scale) / 2
            extra_lift = BANNER_EXTRA_LIFT_NO_LABEL if NO_LABEL else 0
            off_y = max(self.banner_zone_top, off_y - BANNER_VERTICAL_LIFT - extra_lift)
            cr.translate(off_x, off_y)
            cr.scale(scale, scale)
            cr.set_source_surface(self.current_surface, 0, 0)
            cr.paint()
            cr.identity_matrix()

        cr.set_operator(cairo.OPERATOR_OVER)
        indicator_bottom_y = height - MARGIN_BOTTOM - SPINNER_SIZE / 2

        if show_indicator[0] and INDICATOR_TEXT:
            self.draw_indicator(cr, indicator_bottom_y, width)

        if help_visible:
            self.draw_gamepad_help(cr, indicator_bottom_y, width)

        if entry_label_text[0]:
            self.draw_entry_label(cr, width)

        if self.logo_surface is not None:
            self.draw_logo(cr)
        elif title_text[0]:
            self.draw_top_title(cr, width)

    def gamepad_help_visible(self):
        if not _gamepad_pads or not any((HELP_ALTTAB_TEXT, HELP_QUIT_TEXT, HELP_F4_TEXT,
                                         HELP_ALTENTER_TEXT, HELP_F11_TEXT)):
            return False
        # Wait until the picker is done (requested or shown on any screen).
        if picker_request_pending or any(w.picker_visible for w in windows):
            return False
        return True

    def _help_pill_width(self, cr, kind, label):
        if kind == "dpad":
            return 2 * HELP_PILL_HEIGHT + 4
        if kind in ("dpad_up", "dpad_down"):
            return HELP_PILL_HEIGHT
        cr.set_font_size(HELP_PILL_FONT_SIZE)
        text_w = cr.text_extents(label).width
        if kind in ("L3", "R3"):
            return HELP_PILL_HEIGHT + 2
        return max(34, text_w + 16)

    def _help_rounded_rect(self, cr, x, y, w, h, r):
        cr.new_sub_path()
        cr.arc(x + w - r, y + r, r, -math.pi / 2, 0)
        cr.arc(x + w - r, y + h - r, r, 0, math.pi / 2)
        cr.arc(x + r, y + h - r, r, math.pi / 2, math.pi)
        cr.arc(x + r, y + r, r, math.pi, 3 * math.pi / 2)
        cr.close_path()

    def _help_draw_item(self, cr, kind, label, x, cy):
        """Draw an icon (button pill) starting at x, return its width."""
        w = self._help_pill_width(cr, kind, label)
        h = HELP_PILL_HEIGHT
        top = cy - h / 2
        cr.set_line_width(1.5)
        if kind in ("dpad", "dpad_up", "dpad_down"):
            # One or two square D-pad keys with an arrow: (dx, dy) = arrow direction.
            arrows = {"dpad": ((-1, 0), (1, 0)), "dpad_up": ((0, -1),), "dpad_down": ((0, 1),)}[kind]
            for i, (dx, dy) in enumerate(arrows):
                bx = x + i * (h + 4)
                self._help_rounded_rect(cr, bx, top, h, h, 5)
                cr.set_source_rgba(1, 1, 1, 0.10)
                cr.fill_preserve()
                cr.set_source_rgba(0.91, 0.91, 0.91, 0.75)
                cr.stroke()
                mx = bx + h / 2
                # Tip 4 px from the center along (dx, dy), base 3 px behind, +/-5 px wide.
                cr.move_to(mx + dx * 4, cy + dy * 4)
                cr.line_to(mx - dx * 3 - dy * 5, cy - dy * 3 + dx * 5)
                cr.line_to(mx - dx * 3 + dy * 5, cy - dy * 3 - dx * 5)
                cr.close_path()
                cr.fill()
            return w
        if kind in ("L3", "R3"):
            cr.new_sub_path()
            cr.arc(x + w / 2, cy, h / 2, 0, 2 * math.pi)
        elif kind in ("L2", "R2"):
            self._help_rounded_rect(cr, x, top, w, h, h / 2)
        else:
            self._help_rounded_rect(cr, x, top, w, h, 6)
        cr.set_source_rgba(1, 1, 1, 0.10)
        cr.fill_preserve()
        cr.set_source_rgba(0.91, 0.91, 0.91, 0.75)
        cr.stroke()
        cr.set_font_size(HELP_PILL_FONT_SIZE)
        ext = cr.text_extents(label)
        cr.move_to(x + (w - ext.width) / 2 - ext.x_bearing, cy - ext.y_bearing - ext.height / 2)
        cr.show_text(label)
        return w

    def _help_line_items(self, buttons, with_direction, text):
        """with_direction: False, True (left/right arrows), or the name of a key type to
        add after the "+" ("dpad_up", "dpad_down", "Select")."""
        items = [(b, b) for b in buttons]
        if with_direction:
            items.append(("plus", "+"))
            kind = "dpad" if with_direction is True else with_direction
            items.append((kind, "Select" if kind == "Select" else ""))
        return items, text

    def _help_line_width(self, cr, items, text):
        total = 0
        for kind, label in items:
            if kind == "plus":
                cr.set_font_size(HELP_FONT_SIZE)
                total += cr.text_extents("+").x_advance + 2 * HELP_GAP
            else:
                total += self._help_pill_width(cr, kind, label) + HELP_GAP
        cr.set_font_size(HELP_FONT_SIZE)
        total += 8 + cr.text_extents(text).x_advance
        return total

    def draw_gamepad_help(self, cr, bottom_center_y, width):
        cr.select_font_face("sans-serif", cairo.FONT_SLANT_NORMAL, cairo.FONT_WEIGHT_NORMAL)
        lines = []
        if HELP_ALTTAB_TEXT:
            lines.append(self._help_line_items(["L1", "L2", "R1", "R2", "R3"], True, HELP_ALTTAB_TEXT))
        hotkey = ["L1", "L2", "R1", "R2", "R3"]
        for text, kind in ((HELP_F4_TEXT, "dpad_up"), (HELP_ALTENTER_TEXT, "dpad_down"),
                           (HELP_F11_TEXT, "Select")):
            if text:
                lines.append(self._help_line_items(hotkey, kind, text))
        if HELP_QUIT_TEXT:
            lines.append(self._help_line_items(["L1", "L2", "R1", "R2", "R3", "L3"], False, HELP_QUIT_TEXT))
        available = width - HELP_MARGIN_LEFT - HELP_RIGHT_RESERVED
        widest = max(self._help_line_width(cr, items, text) for items, text in lines)
        scale = min(1.0, available / widest) if widest > 0 else 1.0

        # Alpha of each line (alternation + cross-fade) from the time elapsed since the help
        # first appeared; a single available line is always opaque.
        now = time.monotonic()
        if help_start[0] is None:
            # First line shown is picked at random: shift the origin by that many whole
            # periods, then lines cycle in order.
            help_start[0] = now - random.randrange(len(lines)) * HELP_PERIOD_S
        elapsed = now - help_start[0]
        cycle = len(lines) * HELP_PERIOD_S

        def line_alpha(k):
            # One line at a time: fade in, full, fade out to black (nothing written), only
            # then the next line appears.
            if len(lines) == 1:
                return 1.0
            u = (elapsed - k * HELP_PERIOD_S) % cycle
            if u < HELP_FADE_S:
                return u / HELP_FADE_S
            if u < HELP_PERIOD_S - HELP_FADE_S:
                return 1.0
            if u < HELP_PERIOD_S:
                return (HELP_PERIOD_S - u) / HELP_FADE_S
            return 0.0

        for k, (items, text) in enumerate(lines):
            alpha = line_alpha(k)
            if alpha <= 0:
                continue
            cr.save()
            cr.scale(scale, scale)
            cr.push_group()
            cy = bottom_center_y / scale
            x = HELP_MARGIN_LEFT / scale
            for kind, label in items:
                cr.set_source_rgba(0.91, 0.91, 0.91, 0.75)
                if kind == "plus":
                    cr.set_font_size(HELP_FONT_SIZE)
                    ext = cr.text_extents("+")
                    cr.move_to(x + HELP_GAP, cy + ext.height / 2)
                    cr.show_text("+")
                    x += ext.x_advance + 2 * HELP_GAP
                else:
                    x += self._help_draw_item(cr, kind, label, x, cy) + HELP_GAP
            cr.set_source_rgba(0.91, 0.91, 0.91, 0.75)
            cr.set_font_size(HELP_FONT_SIZE)
            ext = cr.text_extents(text)
            cr.move_to(x + 8, cy + ext.height / 2)
            cr.show_text(text)
            cr.pop_group_to_source()
            cr.paint_with_alpha(alpha)
            cr.restore()

    def draw_indicator(self, cr, center_y, width):
        cr.select_font_face("sans-serif", cairo.FONT_SLANT_NORMAL, cairo.FONT_WEIGHT_NORMAL)
        cr.set_font_size(FONT_SIZE)
        extents = cr.text_extents(INDICATOR_TEXT)

        spinner_cx = width - MARGIN_RIGHT - SPINNER_SIZE / 2
        text_x = spinner_cx - SPINNER_SIZE / 2 - TEXT_SPINNER_GAP - extents.width

        cr.set_source_rgba(0.91, 0.91, 0.91, 1)
        cr.move_to(text_x, center_y + extents.height / 2)
        cr.show_text(INDICATOR_TEXT)

        draw_spinner(cr, spinner_cx, center_y, SPINNER_SIZE / 2 - 2, spinner_angle[0])

    def draw_entry_label(self, cr, width):
        cr.select_font_face("sans-serif", cairo.FONT_SLANT_NORMAL, cairo.FONT_WEIGHT_BOLD)
        cr.set_font_size(ENTRY_LABEL_FONT_SIZE)
        extents = cr.text_extents(entry_label_text[0])

        label_x = (width - extents.width) / 2
        label_baseline_y = self.label_zone_top + LABEL_ZONE_TOP_PADDING + extents.height

        cr.set_source_rgba(1, 1, 1, 1)
        cr.move_to(label_x, label_baseline_y)
        cr.show_text(entry_label_text[0])

    def draw_logo(self, cr):
        cr.set_operator(cairo.OPERATOR_OVER)
        img_w = self.logo_surface.get_width()
        scale = self.logo_draw_w / img_w
        cr.save()
        cr.translate(self.logo_draw_x, self.logo_draw_y)
        cr.scale(scale, scale)
        cr.set_source_surface(self.logo_surface, 0, 0)
        cr.paint()
        cr.restore()

    def draw_top_title(self, cr, width):
        cr.select_font_face("sans-serif", cairo.FONT_SLANT_NORMAL, cairo.FONT_WEIGHT_BOLD)
        cr.set_font_size(TOP_TITLE_FONT_SIZE)
        extents = cr.text_extents(title_text[0])

        title_x = (width - extents.width) / 2
        if self.title_centered:
            title_baseline_y = (self.title_zone_bottom + extents.height) / 2
        else:
            title_baseline_y = self.title_zone_bottom - TOP_TITLE_BOTTOM_PADDING

        cr.set_source_rgba(1, 1, 1, 1)
        cr.move_to(title_x, title_baseline_y)
        cr.show_text(title_text[0])

    def set_image(self, path):
        try:
            self.current_surface = cairo.ImageSurface.create_from_png(path)
        except Exception:
            self.current_surface = None
        self.drawing_area.queue_draw()

    def clear_image(self):
        self.current_surface = None
        self.drawing_area.queue_draw()

    def queue_redraw(self):
        self.drawing_area.queue_draw()


def get_monitors():
    """List of (Gdk.Monitor, Gdk.Rectangle) to cover. On Wayland, ALL detected monitors (a
    compositor may refuse placement on a specific one). On X11, only the first one: GTK4
    removed "Gdk.Monitor.is_primary()"/"get_primary_monitor()" (non-portable concept), so
    the first enumerated monitor is an accepted fallback."""
    display = Gdk.Display.get_default()
    monitors_model = display.get_monitors()
    n = monitors_model.get_n_items()
    geoms = []
    for i in range(n):
        mon = monitors_model.get_item(i)
        geoms.append((mon, mon.get_geometry()))
    if is_wayland:
        return geoms
    return geoms[:1]


windows = []
last_bg_state = None
last_indicator_state = None
last_title_state = None
last_entry_label_state = None
picker_request_pending = False


def poll_control_file():
    global last_bg_state, last_indicator_state, last_title_state, last_entry_label_state
    try:
        with open(CONTROL_FILE, "r") as f:
            lines = f.read().splitlines()
    except Exception:
        return True

    bg_state = lines[0].strip() if len(lines) > 0 else "NONE"
    indicator_state = lines[1].strip() if len(lines) > 1 else "IND_SHOW"
    title_state = lines[2].strip() if len(lines) > 2 else ""
    entry_label_state = lines[3].strip() if len(lines) > 3 else ""

    if bg_state == "STOP":
        for win in windows:
            win.close()
        loop.quit()
        return False

    if bg_state != last_bg_state:
        last_bg_state = bg_state
        for win in windows:
            if bg_state == "NONE" or not bg_state:
                win.clear_image()
            elif os.path.isfile(bg_state):
                win.set_image(bg_state)
            else:
                win.clear_image()

    if indicator_state != last_indicator_state:
        last_indicator_state = indicator_state
        show_indicator[0] = (indicator_state != "IND_HIDE")
        for win in windows:
            win.queue_redraw()

    if title_state != last_title_state:
        last_title_state = title_state
        title_text[0] = title_state
        for win in windows:
            win.queue_redraw()

    if entry_label_state != last_entry_label_state:
        last_entry_label_state = entry_label_state
        entry_label_text[0] = entry_label_state
        for win in windows:
            win.queue_redraw()

    return True


def poll_picker_request():
    """See file header -- polls the picker request file at the same rate as the control
    file. Processed once (the file is deleted after a successful read): not shown again
    until a new request arrives."""
    global picker_request_pending
    if picker_request_pending or not windows:
        return True
    if not os.path.isfile(PICKER_REQUEST_FILE):
        return True

    try:
        with open(PICKER_REQUEST_FILE, "r") as f:
            lines = f.read().splitlines()
    except OSError:
        return True

    if len(lines) < 4:
        # File still being written (half read) -- retry on the next tick, never fatal
        # (same best-effort approach as the control file itself).
        return True

    try:
        os.remove(PICKER_REQUEST_FILE)
    except OSError:
        pass

    title, prompt, validate_label, cancel_label = lines[0], lines[1], lines[2], lines[3]
    entries = [e for e in lines[4:] if e]
    if not entries:
        return True

    picker_request_pending = True
    for win in windows:
        win.show_picker(title, prompt, validate_label, cancel_label, entries)
    return True


def tick_spinner():
    spinner_angle[0] += 0.35
    if show_indicator[0]:
        for win in windows:
            win.queue_redraw()
    return True


def tick_cursor():
    for win in windows:
        win.maybe_hide_cursor_if_idle()
    return True


def tick_picker_resolved():
    """Once the picker is resolved (result already written by ScreenWindow), let the next
    "poll_picker_request" handle a new request. Kept separate from writing the result
    itself (done in ScreenWindow._write_picker_result) so it does not depend on execution
    order between the windows (Wayland multi-monitor case)."""
    global picker_request_pending
    if picker_request_pending and not any(w.picker_visible for w in windows):
        picker_request_pending = False
    return True


loop = None


def main():
    global loop
    # Explicit "Gtk.init()": no Gtk.Application here (pointless for a utility window with
    # no menu/application lifecycle), so GTK4 initialization must be requested before any
    # widget is created.
    # Taskbar grouping: same WM_CLASS as the game (that of the .desktop generated by lpm,
    # "StartupWMClass", passed by the orchestrator), otherwise the panel shows this window
    # as a separate, unnamed application. Must be done BEFORE Gtk.init() (the class is
    # read when the display is opened).
    wm_class = os.environ.get("LPM_WM_CLASS", "").strip()
    if wm_class:
        try:
            GLib.set_prgname(wm_class)
            Gdk.set_program_class(wm_class)
        except Exception:
            pass
    Gtk.init()

    geoms = get_monitors()
    if not geoms:
        sys.stderr.write("zgu-launcher-screen: aucun écran détecté\n")
        sys.exit(1)

    style_provider = Gtk.CssProvider()
    style_provider.load_from_data(CSS)
    Gtk.StyleContext.add_provider_for_display(
        Gdk.Display.get_default(),
        style_provider,
        Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION,
    )

    for monitor, geom in geoms:
        win = ScreenWindow(monitor, geom)
        win.present()
        windows.append(win)

    # "GLib.idle_add", NOT a direct call -- see zgu-launcher-picker.py for the rationale
    # (this script always runs on the host, never sandboxed, so the risk is lower, but there
    # is no reason to treat the two files differently).
    GLib.idle_add(init_gamepad)
    GLib.timeout_add(GAMEPAD_POLL_MS, tick_gamepad)

    GLib.timeout_add(POLL_MS, poll_control_file)
    GLib.timeout_add(POLL_MS, poll_picker_request)
    GLib.timeout_add(POLL_MS, tick_picker_resolved)
    GLib.timeout_add(SPIN_TICK_MS, tick_spinner)
    GLib.timeout_add(200, tick_cursor)

    loop = GLib.MainLoop()
    loop.run()


if __name__ == "__main__":
    main()
