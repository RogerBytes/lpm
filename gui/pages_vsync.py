"""Page: disable a game's VSync (environment variables, immediate effect)."""

import gi

gi.require_version("Gtk", "4.0")
gi.require_version("Adw", "1")
from gi.repository import Adw, Gtk  # noqa: E402

import backend
from i18n import t
from commandpage import CommandPage
from util import _run_on_main
from widgets_select import SingleGameSelect

# Identifiers passed as is to "lpm vsync <slug> on|off <id>" (never translated); the
# displayed texts come from the gui.vsync.<id>_title / _sub keys (CLI hyphens -> "_").
VSYNC_SETTINGS = ("d3d9", "d3d11", "d3d12", "gl-nvidia", "gl-mesa")


def _lang_key(setting):
    return setting.replace("-", "_")


class VsyncPage:
    def __init__(self, owner):
        self.owner = owner
        self.window = owner.window

    def build(self):
        self._add_header()
        self._add_game_row()
        self._add_settings_group()
        self._add_all_button()
        self._wire_game_row()
        self._wire_reset()
        return self.page

    def _add_header(self):
        self.page = CommandPage(t("gui.vsync.page_title"))
        # Immediate effect: checking or unchecking writes right away, there is nothing to "run".
        self.page.run_button.set_visible(False)
        self.page.action_group.set_visible(False)

        intro = Gtk.Label(label=t("gui.vsync.intro"), xalign=0, wrap=True)
        warning = Gtk.Label(label=t("gui.vsync.lutris_warning"), xalign=0, wrap=True)
        warning.add_css_class("dim-label")
        intro_box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=8)
        intro_box.append(intro)
        intro_box.append(warning)
        self.page.add_row(intro_box)

    def _add_game_row(self):
        # Games that already have at least one active setting: shown in bold in the list
        # (same mechanism as page_launcher), re-read via "lpm vsync status".
        self.active_slugs: set = set()
        self.game_row = SingleGameSelect(highlighted_slugs=self.active_slugs)
        self.page.add_row(self.game_row)

    def _add_settings_group(self):
        self.group = Adw.PreferencesGroup(title=t("gui.vsync.group_title"))
        self.page.page.add(self.group)

        self.checks = {}
        self.titles = {}
        self.state = {"slug": None, "token": 0, "loading": False, "busy": False}

        for setting in VSYNC_SETTINGS:
            key = _lang_key(setting)
            self.titles[setting] = t("gui.vsync." + key + "_title")
            check = Gtk.CheckButton(valign=Gtk.Align.CENTER)
            row = Adw.ActionRow(title=self.titles[setting], subtitle=t("gui.vsync." + key + "_sub"))
            row.add_prefix(check)
            row.set_activatable_widget(check)
            check.connect("toggled", lambda c, s=setting: self.on_toggled(s, c))
            self.group.add(row)
            self.checks[setting] = check

    def _add_all_button(self):
        self.all_button = Gtk.Button(label=t("gui.vsync.check_all"), halign=Gtk.Align.END, valign=Gtk.Align.CENTER)
        self.all_button.add_css_class("pill")

        self.all_button.connect("clicked", self.on_all_clicked)
        button_box = Gtk.Box(halign=Gtk.Align.END, margin_top=6)
        button_box.append(self.all_button)
        self.page.page.add(CommandPage._wrap_action_group(button_box))

    def _wire_game_row(self):
        self.game_row.connect_changed(self.load_status)
        self.refresh_active_status()
        self.refresh_sensitivity()

    def _wire_reset(self):
        self.page.reset_selection = self.reset_fields

    def set_checks(self, values):
        self.state["loading"] = True
        for setting, check in self.checks.items():
            check.set_active(bool(values.get(setting)))
        self.state["loading"] = False

    def refresh_sensitivity(self):
        enabled = self.state["slug"] is not None and not self.state["busy"]
        for check in self.checks.values():
            check.set_sensitive(enabled)
        self.all_button.set_sensitive(enabled)
        all_on = all(check.get_active() for check in self.checks.values())
        self.all_button.set_label(t("gui.vsync.uncheck_all") if all_on else t("gui.vsync.check_all"))

    def apply_active_status(self, result):
        if result.returncode != 0:
            return
        self.active_slugs.clear()
        self.active_slugs.update(line.strip() for line in result.stdout.splitlines() if line.strip())
        self.game_row.repaint_titles()

    def refresh_active_status(self):
        backend.run_lpm_async(["vsync", "status"], on_done=lambda r: _run_on_main(self.apply_active_status, r))

    def load_status(self):
        slug = self.game_row.selected_slug()
        self.state["token"] += 1
        token = self.state["token"]
        self.state["slug"] = None
        self.state["busy"] = False
        self.set_checks({})
        self.refresh_sensitivity()
        if not slug:
            return

        def done(result):
            def apply():
                if token != self.state["token"]:  # another game was chosen in the meantime
                    return
                if result.returncode != 0:
                    self.page.toast(t("gui.vsync.toast_load_failed"))
                    return
                values = {}
                for line in result.stdout.splitlines():
                    key, _, value = line.strip().partition("=")
                    values[key] = value == "on"
                self.state["slug"] = slug
                self.set_checks(values)
                self.refresh_sensitivity()

            _run_on_main(apply)

        backend.run_lpm_async(["vsync", slug, "status"], on_done=done)

    def write(self, args, ok_toast):
        """Write via the CLI; the checkboxes are blocked during the write (never two
        parallel writes on the same YAML), then re-read from the file."""
        slug = self.state["slug"]
        if slug is None or self.state["busy"]:
            return
        self.state["busy"] = True
        self.refresh_sensitivity()

        def done(result):
            def apply():
                if slug != self.game_row.selected_slug():
                    return
                if result.returncode != 0:
                    self.page.toast(t("gui.vsync.toast_failed"))
                else:
                    self.page.toast(ok_toast)
                self.load_status()
                self.refresh_active_status()

            _run_on_main(apply)

        backend.run_lpm_async(["vsync", slug] + args, on_done=done)

    def on_toggled(self, setting, check):
        if self.state["loading"]:
            return
        if check.get_active():
            self.write(["on", setting], t("gui.vsync.toast_on", self.titles[setting]))
        else:
            self.write(["off", setting], t("gui.vsync.toast_off", self.titles[setting]))

    def on_all_clicked(self, *_):
        if all(check.get_active() for check in self.checks.values()):
            self.write(["off"], t("gui.vsync.toast_all_off"))
        else:
            self.write(["on"], t("gui.vsync.toast_all_on"))

    def reset_fields(self):
        self.game_row.clear_selection()
        self.game_row.refresh()
        self.load_status()
        self.refresh_active_status()



class VsyncPages:
    def page_vsync(self):
        return VsyncPage(self).build()
