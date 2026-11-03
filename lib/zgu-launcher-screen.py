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
# all (loading screen disabled for this game via "lpm/settings/no-loadingscreen", or lpm shortcut
# bypassed). With no background behind it, it is shown as a normal DECORATED window. Both
# share the same interaction (keyboard/gamepad/mouse, Validate/Cancel) and the same styles
# (zgu_common.py).
#
# Layout of the program (all in lib/):
#   zgu-launcher-screen.py   this file: gamepad reading, the window itself, polling, main()
#   zgu_screen_config.py     arguments, constants, shared state and the stylesheet
#   zgu_screen_picker.py     PickerMixin: the picker card (keyboard/gamepad/mouse, marquee)
#   zgu_screen_draw.py       DrawMixin: everything drawn with Cairo
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
#     must be shown. Seven or more lines: TITLE, PROMPT, VALIDATE_LABEL, CANCEL_LABEL,
#     PAD_VALIDATE_LABEL, PAD_CANCEL_LABEL (texts shown next to the gamepad A/B icons, see
#     set_pad_mode), then one entry per line. Read at the same polling as the control file: once it appears
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

# lib/ is the folder of this script: the modules next to it are found whatever the way it is started.
import os
import sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import time

import gi
gi.require_version("Gtk", "4.0")
from gi.repository import Gtk, Gdk, GLib
import cairo

from zgu_screen_config import (
    BLOCK_EXTRA_DOWN_FRACTION,
    CONTROL_FILE,
    CSS,
    CURSOR_IDLE_S,
    GAMEPAD_REPEAT_DELAY_S,
    GAMEPAD_REPEAT_INTERVAL_S,
    HAS_BANNER,
    LABEL_ZONE_HEIGHT,
    LOGO_PATH,
    LOGO_VERTICAL_OFFSET,
    NO_LABEL,
    PICKER_BOX_HEIGHT,
    PICKER_REQUEST_FILE,
    POLL_MS,
    SPIN_TICK_MS,
    TOP_ZONE_MAX_WIDTH_FRACTION,
    TOP_ZONE_MIN_MARGIN,
    entry_label_text,
    gamepad_pads,
    is_wayland,
    picker_request_pending,
    show_indicator,
    spinner_angle,
    title_text,
    windows,
)
from zgu_common import (
    GAMEPAD_AXIS_THRESHOLD,
    GAMEPAD_POLL_MS,
    SDL_CONTROLLER_AXIS_LEFTY,
    SDL_CONTROLLER_BUTTON_A,
    SDL_CONTROLLER_BUTTON_B,
    SDL_CONTROLLER_BUTTON_DPAD_DOWN,
    SDL_CONTROLLER_BUTTON_DPAD_UP,
    init_sdl,
    load_sdl2,
)
from zgu_screen_draw import DrawMixin
from zgu_screen_picker import PickerMixin

# --- Gamepad -> direct picker navigation in SDL2, inside this process. Injecting keys
# (xdotool/ydotool) into the focused window depends on window-manager focus, which a new
# window may be denied ("focus stealing prevention": the gamepad only responded after a
# click or several seconds), and Wayland has no portable way to force focus from outside.
# Reading the gamepad HERE and acting directly on our own GTK widgets works the same on X11
# AND Wayland. Vertical only, single selection: no LEFT/RIGHT and no X/L1/R1 buttons.
_sdl = None
_gamepad_prev_a = {}
_gamepad_prev_b = {}
_gamepad_prev_dpad_y = {}
_gamepad_prev_stick_y = {}
_gamepad_next_repeat = {}



def init_gamepad():
    """Fully best-effort: a missing libSDL2 or no detected gamepad must NEVER prevent the
    loading screen/picker from working with keyboard/mouse. Gamepad reading is part of
    the window itself, so it cannot simply exit like a dedicated script could."""
    global _sdl
    try:
        sdl = load_sdl2()
        if sdl is None:
            return
        if not init_sdl(sdl):
            return
        for i in range(sdl.SDL_NumJoysticks()):
            if sdl.SDL_IsGameController(i):
                handle = sdl.SDL_GameControllerOpen(i)
                if handle:
                    gamepad_pads.append(handle)
                    _gamepad_prev_a[handle] = 0
                    _gamepad_prev_b[handle] = 0
                    _gamepad_prev_dpad_y[handle] = 0
                    _gamepad_prev_stick_y[handle] = 0
                    _gamepad_next_repeat[handle] = 0.0
        _sdl = sdl
    except Exception:
        _sdl = None


def tick_gamepad():
    if _sdl is None or not gamepad_pads:
        return True
    _sdl.SDL_GameControllerUpdate()
    for pad in gamepad_pads:
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
        stick_y = _sdl.SDL_GameControllerGetAxis(pad, SDL_CONTROLLER_AXIS_LEFTY)
        if dpad_up or dpad_down:
            direction = -1 if dpad_up else 1
        elif stick_y <= -GAMEPAD_AXIS_THRESHOLD:
            direction = -1
        elif stick_y >= GAMEPAD_AXIS_THRESHOLD:
            direction = 1
        else:
            direction = 0

        now = time.monotonic()
        if direction == 0:
            _gamepad_prev_dpad_y[pad] = 0
        else:
            if direction != _gamepad_prev_dpad_y[pad]:
                fire = True
                _gamepad_next_repeat[pad] = now + GAMEPAD_REPEAT_DELAY_S
            elif now >= _gamepad_next_repeat[pad]:
                fire = True
                _gamepad_next_repeat[pad] = now + GAMEPAD_REPEAT_INTERVAL_S
            else:
                fire = False
            _gamepad_prev_dpad_y[pad] = direction
            if fire:
                for win in windows:
                    if win.picker_visible:
                        win.gamepad_move_selection(direction)
    return True


class ScreenWindow(PickerMixin, DrawMixin, Gtk.Window):
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

        self._init_picker_state()

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

        top_zone_bottom = self._compute_logo_layout()
        self._compute_zones(top_zone_bottom)
        self.current_surface = None
        self._setup_controllers()

        self.fullscreen_on_monitor(monitor)

    def _compute_logo_layout(self):
        geom = self.monitor_geom
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

        # Size of the banner, read in advance (splash.png sits next to logo.png): the picker
        # shows no banner at first, yet the logo must already be where it will stay.
        self.banner_probe = None
        banner_file = os.path.join(os.path.dirname(LOGO_PATH), "splash.png") if LOGO_PATH else ""
        if HAS_BANNER and os.path.isfile(banner_file):
            try:
                self.banner_probe = cairo.ImageSurface.create_from_png(banner_file)
            except Exception:
                self.banner_probe = None

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
        return top_zone_bottom

    def _compute_zones(self, top_zone_bottom):
        geom = self.monitor_geom
        self.block_extra_down = 0 if NO_LABEL else geom.height * BLOCK_EXTRA_DOWN_FRACTION
        self.title_zone_bottom = top_zone_bottom
        self.title_centered = NO_LABEL

        self.label_zone_top = self.zone_top_y
        self.label_zone_bottom = self.zone_top_y + (0 if NO_LABEL else LABEL_ZONE_HEIGHT)
        self.banner_zone_top = self.label_zone_bottom
        self.banner_zone_height = max(0, geom.height - self.banner_zone_top)

    def _setup_controllers(self):
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
        key_ctrl.set_propagation_phase(Gtk.PropagationPhase.CAPTURE)  # sees keys the list consumes (arrows)
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

    def _init_picker_state(self):
        # --- Picker (see file header): built once here, hidden by default -- a centered
        # "card" over the background, never a second window. ---
        self.picker_visible = False
        self.marquee_row = None
        self.marquee_source = 0
        self.marquee_pending = 0
        self.marquee_state = {}
        self.pad_mode = False
        self.picker_scrollable = False
        self.last_pointer_pos = None
        self.validate_label = self.cancel_label = ""
        self.pad_validate_label = self.pad_cancel_label = ""
        self.picker_entries = []  # [(row, label_text), ...]
        self.picker_listbox = None

    def on_active_changed(self, *_args):
        # Disabled by default, see "keep_focus_env" in zgl-launcher-orchestrator.sh: forcibly
        # taking focus back minimized fullscreen Wine games. Only active if the game has a
        # ".lpm-keep-focus" file (passed via LPM_KEEP_FOCUS).
        if os.environ.get("LPM_KEEP_FOCUS") != "1":
            return
        if not self.get_property("is-active"):
            self.present()


    def on_motion(self, _ctrl, x, y):
        # GTK also emits "motion" when the content under a still pointer moves (list scrolled
        # by the gamepad): only a real displacement of the pointer counts as mouse input.
        last = self.last_pointer_pos
        self.last_pointer_pos = (x, y)
        if last is None or (abs(x - last[0]) < 2 and abs(y - last[1]) < 2):
            return
        if self.picker_visible:
            self.set_pad_mode(False)
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


last_bg_state = None
last_indicator_state = None
last_title_state = None
last_entry_label_state = None


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
    if picker_request_pending[0] or not windows:
        return True
    if not os.path.isfile(PICKER_REQUEST_FILE):
        return True

    try:
        with open(PICKER_REQUEST_FILE, "r") as f:
            lines = f.read().splitlines()
    except OSError:
        return True

    if len(lines) < 6:
        # File still being written (half read) -- retry on the next tick, never fatal
        # (same best-effort approach as the control file itself).
        return True

    try:
        os.remove(PICKER_REQUEST_FILE)
    except OSError:
        pass

    title, prompt, validate_label, cancel_label = lines[0], lines[1], lines[2], lines[3]
    pad_validate_label, pad_cancel_label = lines[4], lines[5]
    entries = [e for e in lines[6:] if e]
    if not entries:
        return True

    picker_request_pending[0] = True
    for win in windows:
        win.show_picker(title, prompt, validate_label, cancel_label, pad_validate_label, pad_cancel_label, entries)
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
    if picker_request_pending[0] and not any(w.picker_visible for w in windows):
        picker_request_pending[0] = False
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
        sys.stderr.write("zgu-launcher-screen: no screen detected\n")
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
