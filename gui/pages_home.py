"""Pages: home and lpm update."""

import shutil
import subprocess

import gi

gi.require_version("Gtk", "4.0")
gi.require_version("Adw", "1")
from gi.repository import Adw, GLib, Gtk  # noqa: E402

import backend
from i18n import t
from commandpage import _PERCENT_LINE_RE, _STEP_LINE_RE
from guilog import _GUI_LOGGER, show_log_dialog
from updatecheck import _check_update_async, _version_key
from util import _run_on_main


class HomePages:
    # --- Home ---
    def page_home(self):
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
        status_page = Adw.StatusPage(
            icon_name="lpm",
            title=t("gui.home.title"),
            description=t("gui.home.description"),
        )

        extra_box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=4)
        extra_box.set_halign(Gtk.Align.CENTER)
        extra_box.set_margin_top(12)

        tagline_label = Gtk.Label(label="Ludis Usually Disregards the Imitation Shame")
        tagline_label.add_css_class("dim-label")
        tagline_label.add_css_class("caption")
        extra_box.append(tagline_label)

        # Same size as the StatusPage description ("Ludis Prefix Manager", just above), so
        # no "caption" class (it would shrink the font), only "dim-label".
        version_button = Gtk.LinkButton(
            uri="https://github.com/RogerBytes/lpm",
            label=backend.get_lpm_version(),
        )
        version_button.set_halign(Gtk.Align.CENTER)
        version_button.add_css_class("dim-label")
        extra_box.append(version_button)

        # Update button under the version number: hidden until a newer version is known
        # (background check, cached 24 h, silent when offline). Accent-colored so it stands out
        # without taking over the page like a full-width banner would.
        update_button = Gtk.Button()
        update_button.add_css_class("suggested-action")
        update_button.add_css_class("pill")
        update_button.set_halign(Gtk.Align.CENTER)
        update_button.set_margin_top(8)
        update_button.set_visible(False)
        extra_box.append(update_button)

        installed_version = backend.get_lpm_version()
        update_state = {"info": None}

        def on_update_info(info):
            if not info or _version_key(info["latest"]) <= _version_key(installed_version):
                return
            update_state["info"] = info
            update_button.set_label(t("gui.update.available", "v" + info["latest"]))
            update_button.set_tooltip_text(
                t("gui.update.button_release" if info["method"] == "manual" else "gui.update.button_install")
            )
            update_button.set_visible(True)

        update_button.connect("clicked", lambda *_: self._start_self_update(update_state["info"]))
        _check_update_async(on_update_info)

        status_page.set_child(extra_box)
        status_page.set_vexpand(True)
        return status_page

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
        dialog = Adw.Dialog()
        dialog.set_title(t("gui.update.progress_title"))
        dialog.set_content_width(420)
        dialog.set_can_close(False)
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=12, margin_top=18, margin_bottom=18,
                      margin_start=18, margin_end=18)
        bar = Gtk.ProgressBar(show_text=True)
        bar.set_text(t("gui.update.progress_title"))
        box.append(bar)
        dialog.set_child(box)
        pulse_id = {"id": GLib.timeout_add(150, lambda: (bar.pulse(), True)[1])}
        state = {"updated": False}

        def stop_pulse():
            if pulse_id["id"] is not None:
                GLib.source_remove(pulse_id["id"])
                pulse_id["id"] = None

        def set_step(text):
            bar.set_text(text)
            bar.set_fraction(0.0)
            if pulse_id["id"] is None:
                pulse_id["id"] = GLib.timeout_add(150, lambda: (bar.pulse(), True)[1])

        def set_percent(pct):
            stop_pulse()
            bar.set_fraction(max(0.0, min(1.0, pct / 100.0)))

        _GUI_LOGGER.info("$ bin/lpm self-update install")

        def on_line(line):
            _GUI_LOGGER.info(line)
            stripped = line.strip()
            m = _STEP_LINE_RE.match(stripped)
            if m:
                _run_on_main(set_step, t("gui.check.step_format", m.group(1), m.group(2), m.group(3)))
                return
            m = _PERCENT_LINE_RE.match(stripped)
            if m:
                _run_on_main(set_percent, int(m.group(1)))
                return
            if stripped.startswith("[UPDATED] "):
                state["updated"] = True

        def on_done(result):
            for err_line in result.stderr.strip().splitlines():
                _GUI_LOGGER.info("! " + err_line)

            def finish():
                stop_pulse()
                if result.returncode == 0 and state["updated"]:
                    bar.set_fraction(1.0)
                    launcher = shutil.which("lpm-gui")
                    if launcher:
                        bar.set_text(t("gui.update.restarting"))
                        # New copy launched AFTER this one closes: lpm is a single-instance
                        # application, so the new one must wait for the old one to release
                        # its application id.
                        subprocess.Popen(["sh", "-c", 'sleep 1.5; exec "$0"', launcher],
                                         start_new_session=True, stdout=subprocess.DEVNULL,
                                         stderr=subprocess.DEVNULL)
                        GLib.timeout_add(600, lambda: (self.window.get_application().quit(), False)[1])
                    else:
                        dialog.set_can_close(True)
                        dialog.force_close()
                        done = Adw.AlertDialog(heading=t("gui.update.progress_title"),
                                               body=t("gui.update.restart_manual"))
                        done.add_response("ok", t("gui.update.failed_close"))
                        done.present(self.window)
                    return
                dialog.set_can_close(True)
                dialog.force_close()
                details = result.stderr.strip().splitlines()[-1] if result.stderr.strip() else ""
                failed = Adw.AlertDialog(heading=t("gui.update.failed_heading"), body=details)
                failed.add_response("close", t("gui.update.failed_close"))
                failed.add_response("log", t("gui.common.view_log"))
                failed.set_default_response("close")
                failed.set_close_response("close")
                failed.connect("response", lambda _d, r: show_log_dialog(self.window) if r == "log" else None)
                failed.present(self.window)

            _run_on_main(finish)

        dialog.present(self.window)
        backend.run_lpm_async(["self-update", "install"], on_line=on_line, on_done=on_done)
