"""Adw.Application, stylesheet and main() entry point."""

import sys

import gi

gi.require_version("Gtk", "4.0")
gi.require_version("Adw", "1")
from gi.repository import Adw, Gdk, Gio, Gtk  # noqa: E402

from mainwindow import MainWindow

APP_ID = "com.rogerbytes.lpm.gui"


# ---------------------------------------------------------------------------------------
# Forced style for the sidebar back button (self.sidebar_back_button, see MainWindow).
# Most GTK themes flatten ALL buttons inside a headerbar with their own CSS rule
# ("headerbar button"), not just those with the "flat" class, so removing that class is not
# enough to get a visible frame. Colors use rgba(127,127,127,...) instead of theme aliases
# (@theme_bg_color, ...) so it looks the same in light and dark themes.
# An inset box-shadow is used instead of a border on .lpm-back-button: a border adds to the
# requested size and made sidebar_header grow slightly when the button appears (category
# mode only, hidden at the root). An inset box-shadow draws the same frame without
# affecting the requested size.
_BACK_BUTTON_CSS = b"""
.lpm-back-button {
    border-radius: 6px;
    box-shadow: inset 0 0 0 1px rgba(127, 127, 127, 0.4);
    background-color: rgba(127, 127, 127, 0.18);
}
.lpm-back-button:hover {
    background-color: rgba(127, 127, 127, 0.30);
}
"""


def _load_app_css():
    provider = Gtk.CssProvider()
    provider.load_from_data(_BACK_BUTTON_CSS)
    display = Gdk.Display.get_default()
    if display is not None:
        Gtk.StyleContext.add_provider_for_display(
            display, provider, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION
        )


class LpmApp(Adw.Application):
    """HANDLES_OPEN (see __init__) lets GLib convert the "open this .zgp/.zgr file" argument
    (double-click / file association, see bin/lpm section 2) into a Gio.File and route it to
    do_open(), both on first launch and when LPM is already running (GLib then relays the
    call over D-Bus to the running instance).

    Reading sys.argv ourselves does not work: a second process that finds an existing
    instance on the bus only triggers do_activate() remotely and exits, so the file path
    never reaches the running instance."""

    def __init__(self):
        super().__init__(application_id=APP_ID, flags=Gio.ApplicationFlags.HANDLES_OPEN)

    def do_activate(self):
        win = self.props.active_window
        if not win:
            _load_app_css()
            win = MainWindow(self)
        win.present()

    def do_open(self, files, _n_files, _hint):
        """Called by GLib instead of do_activate() when files were passed as arguments (on
        first launch, or relayed over D-Bus to the running instance). "files" is a non-empty
        list of Gio.File. Only the first file is handled: lpm-gui is never invoked with
        several paths at once."""
        win = self.props.active_window
        if not win:
            _load_app_css()
            win = MainWindow(self)
        path = files[0].get_path()
        if path:
            win.open_install_for(path)
        win.present()


def main():
    app = LpmApp()
    return app.run(sys.argv)
