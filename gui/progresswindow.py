"""Small progress window of an operation, independent of the main window.

It stays open (and keeps lpm running) even when the main window is closed. A normal end closes
it by itself; a failure turns it into an error window brought in front of the others.
"""

import gi

gi.require_version("Gtk", "4.0")
gi.require_version("Adw", "1")
from gi.repository import Adw, Gio, GLib, Gtk, Pango  # noqa: E402

from i18n import t
from guilog import show_log_dialog

ERROR_DETAIL_MAX_LINES = 12


class ProgressWindow(Adw.Window):
    def __init__(self, title: str, cancellable: bool, on_cancel):
        super().__init__(application=Gio.Application.get_default(), title=title,
                         default_width=460, resizable=True)
        self._cancellable = cancellable
        self._on_cancel = on_cancel
        self._state = "running"  # running -> finished
        self._pulse_id: int | None = None
        self._step_text = ""
        self._build(title)
        self.connect("close-request", self._on_close_request)

    # --- Layout ---
    def _build(self, title: str):
        self.title_text = title
        self.box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=8, margin_top=10,
                           margin_bottom=12, margin_start=14, margin_end=14)
        # Bar and (small) cancel button on ONE row: the window stays low.
        row = Gtk.Box(spacing=10, valign=Gtk.Align.CENTER)
        self.bar = Gtk.ProgressBar(show_text=True, hexpand=True, valign=Gtk.Align.CENTER)
        self.bar.set_ellipsize(Pango.EllipsizeMode.MIDDLE)
        row.append(self.bar)
        self.cancel_button = Gtk.Button(label=t("gui.install.cancel_button"), visible=self._cancellable)
        self.cancel_button.add_css_class("destructive-action")
        self.cancel_button.connect("clicked", lambda *_: self._confirm_cancel())
        row.append(self.cancel_button)
        self.box.append(row)
        toolbar = Adw.ToolbarView()
        toolbar.add_top_bar(Adw.HeaderBar(title_widget=Adw.WindowTitle(title=title, subtitle="")))
        toolbar.set_content(self.box)
        self.set_content(toolbar)

    # --- Progress (same behaviour as the former in-page bar) ---
    def start(self):
        self.bar.set_fraction(0.0)
        self.bar.set_text(None)
        self._start_pulse()

    def _start_pulse(self):
        self._stop_pulse()
        self._pulse_id = GLib.timeout_add(150, lambda: (self.bar.pulse(), True)[1])

    def _stop_pulse(self):
        if self._pulse_id is not None:
            GLib.source_remove(self._pulse_id)
            self._pulse_id = None

    def set_step(self, text: str):
        self._step_text = text
        self.bar.set_text(text)
        self.bar.set_fraction(0.0)
        self._start_pulse()

    def set_item(self, current: int, total: int, name: str = ""):
        item_text = f"{current} / {total} – {name}" if name else f"{current} / {total}"
        self.bar.set_text(f"{self._step_text} : {item_text}" if self._step_text else item_text)
        self.bar.set_fraction(0.0)
        self._start_pulse()

    def set_percent(self, pct: int):
        self._stop_pulse()
        self.bar.set_fraction(max(0.0, min(1.0, pct / 100.0)))

    # --- Cancel / close ---
    def _confirm_cancel(self):
        """Always asks first (no mis-click): the button and the close button share this."""
        dialog = Adw.AlertDialog(heading=t("gui.op.cancel_heading"),
                                 body=t("gui.op.cancel_body", self.title_text))
        dialog.add_response("keep", t("gui.op.cancel_keep"))
        dialog.add_response("confirm", t("gui.op.cancel_confirm"))
        dialog.set_response_appearance("confirm", Adw.ResponseAppearance.DESTRUCTIVE)
        dialog.set_default_response("keep")
        dialog.set_close_response("keep")
        dialog.connect("response", lambda _d, r: self._do_cancel() if r == "confirm" else None)
        dialog.present(self)

    def _do_cancel(self):
        self.cancel_button.set_sensitive(False)
        self._on_cancel()

    def _on_close_request(self, _win) -> bool:
        if self._state != "running":
            return False
        if not self._cancellable:
            dialog = Adw.AlertDialog(heading=t("gui.op.busy_heading"), body=t("gui.op.cannot_cancel"))
            dialog.add_response("ok", t("gui.op.error_close"))
            dialog.present(self)
            return True
        self._confirm_cancel()
        return True

    # --- End of the operation ---
    def finish(self):
        """Normal end (or cancelled by the user): the window just goes away."""
        self._state = "finished"
        self._stop_pulse()
        self.close()

    def show_error(self, heading: str, details: str):
        """Failure or crash: the window becomes an error window, brought in front."""
        self._state = "finished"
        self._stop_pulse()
        self.set_title(heading)
        child = self.box.get_first_child()
        while child is not None:
            following = child.get_next_sibling()
            self.box.remove(child)
            child = following
        title = Gtk.Label(label=heading, xalign=0, wrap=True)
        title.add_css_class("title-3")
        self.box.append(title)
        lines = [ln.strip() for ln in details.splitlines() if ln.strip()][-ERROR_DETAIL_MAX_LINES:]
        detail_label = Gtk.Label(label="\n".join(lines), xalign=0, wrap=True, selectable=True)
        detail_label.add_css_class("monospace")
        self.box.append(detail_label)
        buttons = Gtk.Box(spacing=6, halign=Gtk.Align.END)
        log_button = Gtk.Button(label=t("gui.common.view_log"))
        log_button.connect("clicked", lambda *_: show_log_dialog(self))
        close_button = Gtk.Button(label=t("gui.op.error_close"))
        close_button.add_css_class("suggested-action")
        close_button.connect("clicked", lambda *_: self.close())
        buttons.append(log_button)
        buttons.append(close_button)
        self.box.append(buttons)
        self.present()
        close_button.grab_focus()  # no text left selected, Enter closes
