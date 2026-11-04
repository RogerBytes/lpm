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
    def __init__(self, title: str, cancellable: bool, on_cancel, has_finished_items=None, parent=None):
        super().__init__(application=Gio.Application.get_default(), title=title,
                         default_width=560, resizable=True)
        # Attached to the main window (same request on X11 and Wayland): it stays in front of it,
        # usually centered on it, and can still be minimized. Not modal: the main window stays
        # usable. Without a parent (main window closed) it is a normal window.
        if parent is not None:
            self.set_transient_for(parent)
        self._cancellable = cancellable
        self._on_cancel = on_cancel  # called with None, "stop" or "undo"
        self._has_finished_items = has_finished_items  # None: nothing to undo for this operation
        self._state = "running"  # running -> finished
        self._pulse_id: int | None = None
        self._step_text = ""
        self._build(title)
        self.connect("close-request", self._on_close_request)

    # --- Layout ---
    def _build(self, title: str):
        self.box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=8, margin_top=10,
                           margin_bottom=12, margin_start=14, margin_end=14)
        # Two views in the SAME place (a homogeneous stack is as big as the biggest one, so the
        # window never changes size): the progress, and the "cancel?" question.
        self.stack = Gtk.Stack(hhomogeneous=True, vhomogeneous=True)
        self.stack.add_named(self._build_progress_row(), "progress")
        self.stack.add_named(self._build_confirm_row(), "confirm")
        self.stack.add_named(self._build_choice_row(), "choice")
        self.box.append(self.stack)
        toolbar = Adw.ToolbarView()
        header = Adw.HeaderBar(title_widget=Adw.WindowTitle(title=title, subtitle=""))
        # GTK never shows its own minimize button on a window attached to another one
        # (set_transient_for), so this small one is added, on the side OPPOSITE to the close
        # button, wherever the system layout (gtk-decoration-layout) puts that one.
        minimize = Gtk.Button(icon_name="window-minimize-symbolic", valign=Gtk.Align.CENTER)
        minimize.add_css_class("flat")
        minimize.connect("clicked", lambda _b: self.minimize())
        layout = Gtk.Settings.get_default().get_property("gtk-decoration-layout") or ""
        if "close" in layout.split(":")[0]:
            header.pack_end(minimize)
        else:
            header.pack_start(minimize)
        toolbar.add_top_bar(header)
        toolbar.set_content(self.box)
        self.set_content(toolbar)

    def _build_progress_row(self) -> Gtk.Box:
        row = Gtk.Box(spacing=10, valign=Gtk.Align.CENTER)
        self.bar = Gtk.ProgressBar(show_text=True, hexpand=True, valign=Gtk.Align.CENTER)
        self.bar.set_ellipsize(Pango.EllipsizeMode.MIDDLE)
        row.append(self.bar)
        self.cancel_button = Gtk.Button(label=t("gui.install.cancel_button"), visible=self._cancellable)
        self.cancel_button.add_css_class("destructive-action")
        self.cancel_button.connect("clicked", lambda *_: self._confirm_cancel())
        row.append(self.cancel_button)
        return row

    def _build_confirm_row(self) -> Gtk.Box:
        """Just two buttons, half the width each: blue "Continue", red "Cancel the operation"
        (the same for every operation). For an operation that cannot be cancelled, the same
        row holds a sentence and one button instead (see _on_close_request)."""
        row = Gtk.Box(spacing=10, valign=Gtk.Align.CENTER, homogeneous=True)  # equal widths
        self.confirm_row = row
        self.notice = Gtk.Label(xalign=0, hexpand=True, ellipsize=Pango.EllipsizeMode.END, visible=False)
        row.append(self.notice)
        self.keep_button = Gtk.Button(label=t("gui.op.cancel_keep"), hexpand=True)
        self.keep_button.add_css_class("suggested-action")
        self.keep_button.connect("clicked", lambda *_: self._show_progress())
        self.confirm_button = Gtk.Button(label=t("gui.op.cancel_confirm"), hexpand=True)
        self.confirm_button.add_css_class("destructive-action")
        self.confirm_button.connect("clicked", lambda *_: self._after_confirm())
        row.append(self.keep_button)
        row.append(self.confirm_button)
        return row

    def _build_choice_row(self) -> Gtk.Box:
        """Second step, same look: what to do with what is ALREADY finished (installed games,
        exported archives). The tooltips say it without making the window bigger."""
        row = Gtk.Box(spacing=10, valign=Gtk.Align.CENTER, homogeneous=True)
        self.stop_button = Gtk.Button(label=t("gui.op.cancel_stop"), hexpand=True,
                                      tooltip_text=t("gui.op.cancel_stop_tip"))
        self.stop_button.add_css_class("suggested-action")
        self.stop_button.connect("clicked", lambda *_: self._do_cancel("stop"))
        self.undo_button = Gtk.Button(label=t("gui.op.cancel_undo"), hexpand=True,
                                      tooltip_text=t("gui.op.cancel_undo_tip"))
        self.undo_button.add_css_class("destructive-action")
        self.undo_button.connect("clicked", lambda *_: self._do_cancel("undo"))
        row.append(self.stop_button)
        row.append(self.undo_button)
        return row

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
        """Always asks first (no mis-click), in the window itself: the button and the close
        button share this. "Continue" simply goes back to the progress."""
        self.notice.set_visible(False)
        self.confirm_button.set_visible(True)
        self.confirm_row.set_homogeneous(True)
        self.stack.set_visible_child_name("confirm")
        self.keep_button.grab_focus()

    def _show_progress(self):
        self.stack.set_visible_child_name("progress")

    def _after_confirm(self):
        """Cancel confirmed: if something is already finished and can be undone, ask what to do
        with it (second step); else cancel at once."""
        if self._has_finished_items is not None and self._has_finished_items():
            self.stack.set_visible_child_name("choice")
            self.stop_button.grab_focus()
        else:
            self._do_cancel(None)

    def _do_cancel(self, choice):
        self._show_progress()
        self.cancel_button.set_sensitive(False)
        self._on_cancel(choice)

    def _on_close_request(self, _win) -> bool:
        if self._state != "running":
            return False
        if self.stack.get_visible_child_name() == "choice":
            return True  # the second question must be answered
        if self._cancellable:
            self._confirm_cancel()
        else:
            # Nothing to cancel: the same line says so, with a single button.
            self.notice.set_label(t("gui.op.cannot_cancel"))
            self.notice.set_visible(True)
            self.confirm_row.set_homogeneous(False)
            self.keep_button.set_hexpand(False)
            self.confirm_button.set_visible(False)
            self.stack.set_visible_child_name("confirm")
            self.keep_button.grab_focus()
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
