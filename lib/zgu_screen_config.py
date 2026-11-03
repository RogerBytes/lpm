# Settings, constants and shared state of the loading screen (zgu-launcher-screen.py):
# command-line arguments, sizes, timings, environment texts and the GTK stylesheet.
#
# This module reads sys.argv at import, so it must be imported by the program itself.

import importlib
import os
import random
import sys

# lib/ is the folder of this script: zgu_common.py sits next to it, whatever the way it is started.
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from zgu_common import PICKER_BUTTON_CSS, PICKER_TEXT_CSS

# Stop here, with a clear message, if GTK4 is missing (the other modules import it directly).
try:
    import gi
    gi.require_version("Gtk", "4.0")
    importlib.import_module("gi.repository.Gtk")
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
# --- Per-game messages at the bottom center (text of <game dir>/lpm/settings/loading-message.txt, passed
# by the orchestrator in LPM_LOADING_MESSAGE): explain a long loading (mods, shaders...). One
# line of the file = one message; ONE message at a time (a long one is wrapped on up to
# LOADING_MESSAGE_MAX_LINES lines); several messages alternate in file order with the same
# fades and black gap as the gamepad tips, each shown a bit longer (LOADING_MESSAGE_PERIOD_S).
# Not translated: it is the user's own text. Hidden while the picker is on screen. ---
LOADING_MESSAGES = [" ".join(l.split()) for l in os.environ.get("LPM_LOADING_MESSAGE", "").split("\n")]
LOADING_MESSAGES = [m for m in LOADING_MESSAGES if m]
LOADING_MESSAGE_PERIOD_S = 6.0
message_start = [None]
LOADING_MESSAGE_FONT_SIZE = 18
LOADING_MESSAGE_LINE_HEIGHT = 26
LOADING_MESSAGE_MAX_LINES = 4
LOADING_MESSAGE_MAX_WIDTH_FRACTION = 0.6
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
help_sequence = []  # indices of the help lines in display order, extended as time goes on


def extend_help_sequence(sequence, count, upto):
    """Extend `sequence` (in place) until it has more than `upto` entries. It is built in
    shuffled rounds where every line appears once, and a round never starts with the line
    that ended the previous one, so the same line is never shown twice in a row."""
    while len(sequence) <= upto:
        round_ = random.sample(range(count), count)
        if sequence and count > 1 and round_[0] == sequence[-1]:
            round_[0], round_[1] = round_[1], round_[0]
        sequence.extend(round_)
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
LABEL_ZONE_TOP_PADDING = 8
# On a launcher with a picker (NO_LABEL off), the logo is low from the start (picker AND loading screen, no jump), the logo and
# the label go down together by this amount (their mutual distance is unchanged).
LABEL_SHIFT_DOWN = 48
# The logo goes down this much MORE than the label, to bring them closer (gap about halved).
LOGO_EXTRA_DOWN = 24
# Logo and label go down TOGETHER by this fraction of the screen height (picker AND loading
# screen), to sit right above the banner. A fraction, not pixels: same look at any resolution.
BLOCK_EXTRA_DOWN_FRACTION = 0.05

CURSOR_IDLE_S = 1.0

# A selected entry too long for the card scrolls sideways so it can be read: it starts
# MARQUEE_START_DELAY_S after the selection, moves at MARQUEE_SPEED_PX_S, waits
# MARQUEE_END_PAUSE_S at the end, comes back the other way to the start and loops.
MARQUEE_START_DELAY_S = 0.9
MARQUEE_SPEED_PX_S = 90.0
MARQUEE_END_PAUSE_S = 1.2
MARQUEE_TICK_MS = 16

# Held direction (d-pad or left stick) on the picker list: first move on press, then after
# GAMEPAD_REPEAT_DELAY_S one move every GAMEPAD_REPEAT_INTERVAL_S while it stays held.
GAMEPAD_REPEAT_DELAY_S = 0.4
GAMEPAD_REPEAT_INTERVAL_S = 0.07

# The logo is attached to the banner (splash image): its bottom edge sits LOGO_BANNER_GAP above
# the banner, or SUBTITLE_BAND_HEIGHT above it on a launcher with a picker (NO_LABEL off), where
# that band is always kept free for the label of the chosen entry (episode, chapter...).
LOGO_BANNER_GAP = 28
# Without a picker the banner is also moved down by this fraction of the screen height (the logo
# stays where it is), so the logo does not look glued to it (about 1 cm on a 27" screen).
BANNER_EXTRA_DOWN_FRACTION = 0.04
SUBTITLE_BAND_HEIGHT = 84
# With a picker, space kept between the logo and the picker card (the card goes down, its
# bottom edge stays where it is, so it becomes shorter) and the least it may be reduced to.
LOGO_PICKER_CLEARANCE = 14
PICKER_CARD_MIN_HEIGHT = 360
# With a banner announced but not loaded yet, the logo waits (no jump) for at most this long.
LOGO_WAIT_FOR_BANNER_S = 2.0

MAX_BANNER_WIDTH_FRACTION = 0.80
BANNER_VERTICAL_LIFT = 30
BANNER_EXTRA_LIFT_NO_LABEL = 15

# Vertical offset of the picker from the exact screen center: a bit more room above,
# where the logo/title are shown.
# (the card is centered below this margin: raising the margin by N moves the card down by N/2)
PICKER_VERTICAL_OFFSET = 142
# Height of the card itself (PICKER_BOX_HEIGHT stays the reference of the logo/label zones).
PICKER_CARD_HEIGHT = 660

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
    padding: 46px 46px 23px 46px;
}
""" + PICKER_TEXT_CSS + b"""
/* Noeud CSS "list", PAS "listbox" -- le widget est "Gtk.ListBox" mais son noeud CSS en
   GTK4 s'appelle "list" ; le selecteur "listbox" ne correspondait a rien du tout, d'ou le
   fond reste blanc malgre les regles ci-dessous (symptome observe). */
.lpm-picker-card list {
    background-color: transparent;
}
.lpm-picker-card list row {
    padding: 20px 32px 22px 32px;
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
    min-height: 34px;
}
/* Always-visible scrollbar (no overlay): tells at once that the list scrolls. Every
   border/shadow/image of the theme is removed (a light line showed on its left side). */
.lpm-picker-card scrollbar {
    background: none;
    background-color: transparent;
    border: none;
    box-shadow: none;
    outline: none;
    padding: 0 2px;
}
.lpm-picker-card scrollbar trough {
    background: none;
    background-color: #2a2a2a;
    border: none;
    box-shadow: none;
    border-radius: 5px;
    min-width: 10px;
}
.lpm-picker-card scrollbar slider {
    background: none;
    background-color: #9a9a9a;
    border: none;
    box-shadow: none;
    min-width: 10px;
    min-height: 48px;
    border-radius: 5px;
}
.lpm-picker-button.lpm-pad-flat,
.lpm-picker-button.lpm-pad-flat:hover {
    background: none;
    background-color: transparent;
    border: none;
    box-shadow: none;
}
.lpm-pad-icon {
    color: #ffffff;
    font-weight: bold;
    font-size: 18px;
    min-width: 30px;
    min-height: 30px;
    border-radius: 15px;
}
.lpm-pad-icon-a { background-color: #2e9e3a; }
.lpm-pad-icon-b { background-color: #c62828; }
""" + PICKER_BUTTON_CSS + b"""
"""

# State shared by the window classes and the polling functions of zgu-launcher-screen.py. Lists
# so that every module sees the same object (a name rebound in one module would not be seen in
# the others).
windows = []                  # the ScreenWindow of each covered monitor
gamepad_pads = []             # SDL handles of the detected gamepads
picker_request_pending = [False]  # a picker request was read and is not resolved yet
