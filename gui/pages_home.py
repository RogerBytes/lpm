"""Pages: home and lpm update."""

import shutil
import subprocess

import gi

gi.require_version("Gtk", "4.0")
gi.require_version("Adw", "1")
from gi.repository import Adw, GLib, Gtk  # noqa: E402

import backend
import operations
from i18n import t
from commandpage import _PERCENT_LINE_RE, _STEP_LINE_RE
from guilog import _GUI_LOGGER, show_log_dialog
from updatecheck import _check_update_async, _version_key
from util import _run_on_main


class HomePage:
    """Page shown by default at launch until a category is chosen in the sidebar -- a
    neutral state (Adw.StatusPage, the standard GNOME/HIG widget: centered icon, title,
    description) rather than starting an action the user did not ask for.

    Two discreet secondary elements under the description (CSS class "dim-label"), built
    once (this page is cached by show_page, see MainWindow._built_pages):
    - the "LUDIS" backronym joke ("Ludis Usually Disregards the Imitation Shame"),
    deliberately always in English and never passed through t(): it is an
    English-language pun (like WINE/GNU) that does not translate.
    - the version number, read via "bin/lpm --version" (LPM_VERSION in bin/lpm is the
    single source of truth, see backend.get_lpm_version), shown as a clickable link
    to the GitHub repository.
    """

    def __init__(self, owner):
        self.owner = owner
        self.window = owner.window

    def build(self):
        self._build_status_page()
        self._add_tagline_and_version()
        self._add_update_button()
        self._finish()
        return self.status_page

    def _build_status_page(self):
        self.status_page = Adw.StatusPage(
            icon_name="lpm",
            title=t("gui.home.title"),
            description=t("gui.home.description"),
        )

    def _add_tagline_and_version(self):
        self.extra_box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=4)
        self.extra_box.set_halign(Gtk.Align.CENTER)
        self.extra_box.set_margin_top(12)

        tagline_label = Gtk.Label(label="Ludis Usually Disregards the Imitation Shame")
        tagline_label.add_css_class("dim-label")
        tagline_label.add_css_class("caption")
        self.extra_box.append(tagline_label)

        # Same size as the StatusPage description ("Ludis Prefix Manager", just above), so
        # no "caption" class (it would shrink the font), only "dim-label".
        self.version_button = Gtk.LinkButton(
            uri="https://github.com/RogerBytes/lpm",
            label=backend.get_lpm_version(),
        )
        self.version_button.set_halign(Gtk.Align.CENTER)
        self.version_button.add_css_class("dim-label")
        self.extra_box.append(self.version_button)

    def _add_update_button(self):
        # Update button under the version number: hidden until a newer version is known
        # (background check, cached 24 h, silent when offline). Accent-colored so it stands out
        # without taking over the page like a full-width banner would.
        self.update_button = Gtk.Button()
        self.update_button.add_css_class("suggested-action")
        self.update_button.add_css_class("pill")
        self.update_button.set_halign(Gtk.Align.CENTER)
        self.update_button.set_margin_top(8)
        self.update_button.set_visible(False)
        self.extra_box.append(self.update_button)

        self.installed_version = backend.get_lpm_version()
        self.update_state = {"info": None}

        self.update_button.connect("clicked", lambda *_: self.owner._start_self_update(self.update_state["info"]))
        _check_update_async(self.on_update_info)

    def _finish(self):
        self.status_page.set_child(self.extra_box)
        self.status_page.set_vexpand(True)

    def on_update_info(self, info):
        if not info or _version_key(info["latest"]) <= _version_key(self.installed_version):
            return
        self.update_state["info"] = info
        self.update_button.set_label(t("gui.update.available", "v" + info["latest"]))
        self.update_button.set_tooltip_text(
            t("gui.update.button_release" if info["method"] == "manual" else "gui.update.button_install")
        )
        self.update_button.set_visible(True)



class HomePages:
    # --- Home ---
    def page_home(self):
        return HomePage(self).build()

    def _start_self_update(self, info):
        """Update button on the home page: manual/unknown install -> opens the release page; package
        install -> confirmation, then "lpm self-update install" (download, SHA-256
        verification, install via pkexec) and restart."""
        if not info:
            return
        if info["method"] == "manual":
            Gtk.UriLauncher(uri=info["url"] or "https://github.com/RogerBytes/lpm/releases").launch(
                self.window, None, lambda *_: None
            )
            return

        confirm = Adw.AlertDialog(
            heading=t("gui.update.confirm_heading", "v" + info["latest"]),
            body=t("gui.update.confirm_body"),
        )
        confirm.add_response("cancel", t("gui.common.cancel"))
        confirm.add_response("go", t("gui.update.confirm_button"))
        confirm.set_response_appearance("go", Adw.ResponseAppearance.SUGGESTED)
        confirm.set_default_response("cancel")
        confirm.set_close_response("cancel")
        confirm.connect("response", lambda _d, r: self._run_self_update(info) if r == "go" else None)
        confirm.present(self.window)

    def _run_self_update(self, info):
        _SelfUpdateRun(self.window).start()


class _SelfUpdateRun:
    """Progress dialog + "lpm self-update install" run, then restart of the GUI."""

    def __init__(self, window):
        self.window = window
        self.updated = False
        self.pulse_id: int | None = None

    def _build_dialog(self):
        self.dialog = Adw.Dialog()
        self.dialog.set_title(t("gui.update.progress_title"))
        self.dialog.set_content_width(420)
        self.dialog.set_can_close(False)
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=12, margin_top=18, margin_bottom=18,
                      margin_start=18, margin_end=18)
        self.bar = Gtk.ProgressBar(show_text=True)
        self.bar.set_text(t("gui.update.progress_title"))
        box.append(self.bar)
        self.dialog.set_child(box)

    def _start_pulse(self):
        self.pulse_id = GLib.timeout_add(150, lambda: (self.bar.pulse(), True)[1])

    def _stop_pulse(self):
        if self.pulse_id is not None:
            GLib.source_remove(self.pulse_id)
            self.pulse_id = None

    def _set_step(self, text):
        self.bar.set_text(text)
        self.bar.set_fraction(0.0)
        if self.pulse_id is None:
            self._start_pulse()

    def _set_percent(self, pct):
        self._stop_pulse()
        self.bar.set_fraction(max(0.0, min(1.0, pct / 100.0)))

    def start(self):
        if operations.is_busy():
            operations.show_busy_dialog(self.window)
            return
        operations.begin(self)
        self._build_dialog()
        self._start_pulse()
        _GUI_LOGGER.info("$ bin/lpm self-update install")
        self.dialog.present(self.window)
        backend.run_lpm_async(["self-update", "install"], on_line=self._on_line, on_done=self._on_done)

    def _on_line(self, line):
        _GUI_LOGGER.info(line)
        stripped = line.strip()
        m = _STEP_LINE_RE.match(stripped)
        if m:
            _run_on_main(self._set_step, t("gui.check.step_format", m.group(1), m.group(2), m.group(3)))
            return
        m = _PERCENT_LINE_RE.match(stripped)
        if m:
            _run_on_main(self._set_percent, int(m.group(1)))
            return
        if stripped.startswith("[UPDATED] "):
            self.updated = True

    def _on_done(self, result):
        for err_line in result.stderr.strip().splitlines():
            _GUI_LOGGER.info("! " + err_line)
        _run_on_main(self._finish, result)

    def _close_dialog(self):
        self.dialog.set_can_close(True)
        self.dialog.force_close()

    def _finish(self, result):
        operations.end(self)
        self._stop_pulse()
        if result.returncode == 0 and self.updated:
            self.bar.set_fraction(1.0)
            self._restart()
            return
        self._close_dialog()
        details = result.stderr.strip().splitlines()[-1] if result.stderr.strip() else ""
        failed = Adw.AlertDialog(heading=t("gui.update.failed_heading"), body=details)
        failed.add_response("close", t("gui.update.failed_close"))
        failed.add_response("log", t("gui.common.view_log"))
        failed.set_default_response("close")
        failed.set_close_response("close")
        failed.connect("response", lambda _d, r: show_log_dialog(self.window) if r == "log" else None)
        failed.present(self.window)

    def _restart(self):
        launcher = shutil.which("lpm-gui")
        if launcher:
            self.bar.set_text(t("gui.update.restarting"))
            # New copy launched AFTER this one closes: lpm is single-instance, so the new
            # one must wait for the old one to release its application id.
            subprocess.Popen(["sh", "-c", 'sleep 1.5; exec "$0"', launcher],
                             start_new_session=True, stdout=subprocess.DEVNULL,
                             stderr=subprocess.DEVNULL)
            GLib.timeout_add(600, lambda: (self.window.get_application().quit(), False)[1])
            return
        self._close_dialog()
        done = Adw.AlertDialog(heading=t("gui.update.progress_title"),
                               body=t("gui.update.restart_manual"))
        done.add_response("ok", t("gui.update.failed_close"))
        done.present(self.window)
