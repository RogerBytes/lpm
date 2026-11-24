#!/usr/bin/env python3
# --- lpm launcher: small notice in the top right corner of the screen, gone after ~2 s -- GTK4 ---
#
# Usage: zgu-toast.py <x11|wayland> <text>
# Never takes the keyboard focus on purpose (not focusable); on X11 it is placed with xdotool,
# on Wayland the compositor decides where a plain window goes.
import os
import sys

import gi

gi.require_version("Gtk", "4.0")
gi.require_version("Gdk", "4.0")
from gi.repository import Gdk, GLib, Gtk  # noqa: E402

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from zgu_overlay import place_on_x11, x11_focus_window, x11_restore_focus, x11_set_hints  # noqa: E402

TITLE = "LPM toast"
SHOW_SECONDS = 2.2
CSS = b"""
window.lpm-toast, window.lpm-toast.background, window.lpm-toast decoration {
  background: transparent; box-shadow: none; border: none; border-radius: 0; }
.lpm-toast-card { background: rgba(26,26,26,0.92); border: 1px solid rgba(255,255,255,0.18);
  border-radius: 10px; padding: 10px 18px; box-shadow: none; }
.lpm-toast-card label { color: #ffffff; font-weight: 600; }
"""


def on_activate(application):
    kind = sys.argv[1] if len(sys.argv) > 1 else "x11"
    text = sys.argv[2] if len(sys.argv) > 2 else ""
    provider = Gtk.CssProvider()
    provider.load_from_data(CSS)
    Gtk.StyleContext.add_provider_for_display(Gdk.Display.get_default(), provider,
                                              Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION)
    win = Gtk.Window(application=application, title=TITLE)
    win.add_css_class("lpm-toast")
    win.set_decorated(False)
    win.set_resizable(False)
    win.set_focusable(False)
    card = Gtk.Box()
    card.add_css_class("lpm-toast-card")
    card.append(Gtk.Label(label=text))
    win.set_child(card)
    if kind == "x11":
        # invisible until it has been moved to the corner (no flash at the default position)
        # type "notification": desktops do not play their opening animation for it, and no focus
        x11_set_hints(win, "NOTIFICATION", no_focus=True)
        game_focus = x11_focus_window()
        win.set_opacity(0.0)
        win.present()
        for delay in (100, 400):  # the window manager may focus the new window: give it back
            GLib.timeout_add(delay, lambda: (x11_restore_focus(game_focus), False)[1])
        GLib.timeout_add(30, place_on_x11, win, TITLE, "topright", 0, lambda: win.set_opacity(1.0), 30, 40)
    else:
        win.present()
    GLib.timeout_add(int(SHOW_SECONDS * 1000), application.quit)


app = Gtk.Application(application_id="org.lpm.Toast", flags=0)
app.connect("activate", on_activate)
GLib.unix_signal_add(GLib.PRIORITY_HIGH, 15, lambda: (app.quit(), False)[1])
sys.exit(app.run([sys.argv[0]]))
