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


class VsyncPages:
    def page_vsync(self):
        page = CommandPage(t("gui.vsync.page_title"))
        # Immediate effect: checking or unchecking writes right away, there is nothing to "run".
        page.run_button.set_visible(False)
        page.action_group.set_visible(False)

        intro = Gtk.Label(label=t("gui.vsync.intro"), xalign=0, wrap=True)
        warning = Gtk.Label(label=t("gui.vsync.lutris_warning"), xalign=0, wrap=True)
        warning.add_css_class("dim-label")
        intro_box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=8)
        intro_box.append(intro)
        intro_box.append(warning)
        page.add_row(intro_box)

        # Games that already have at least one active setting: shown in bold in the list
        # (same mechanism as page_launcher), re-read via "lpm vsync status".
        active_slugs: set = set()
        game_row = SingleGameSelect(highlighted_slugs=active_slugs)
        page.add_row(game_row)

        group = Adw.PreferencesGroup(title=t("gui.vsync.group_title"))
        page.page.add(group)

        checks = {}
        titles = {}
        state = {"slug": None, "token": 0, "loading": False, "busy": False}

        def set_checks(values):
            state["loading"] = True
            for setting, check in checks.items():
                check.set_active(bool(values.get(setting)))
            state["loading"] = False

        def refresh_sensitivity():
            enabled = state["slug"] is not None and not state["busy"]
            for check in checks.values():
                check.set_sensitive(enabled)
            all_button.set_sensitive(enabled)
            all_on = all(check.get_active() for check in checks.values())
            all_button.set_label(t("gui.vsync.uncheck_all") if all_on else t("gui.vsync.check_all"))

        def apply_active_status(result):
            if result.returncode != 0:
                return
            active_slugs.clear()
            active_slugs.update(line.strip() for line in result.stdout.splitlines() if line.strip())
            game_row.repaint_titles()

        def refresh_active_status():
            backend.run_lpm_async(["vsync", "status"], on_done=lambda r: _run_on_main(apply_active_status, r))

        def load_status():
            slug = game_row.selected_slug()
            state["token"] += 1
            token = state["token"]
            state["slug"] = None
            state["busy"] = False
            set_checks({})
            refresh_sensitivity()
            if not slug:
                return

            def done(result):
                def apply():
                    if token != state["token"]:  # another game was chosen in the meantime
                        return
                    if result.returncode != 0:
                        page.toast(t("gui.vsync.toast_load_failed"))
                        return
                    values = {}
                    for line in result.stdout.splitlines():
                        key, _, value = line.strip().partition("=")
                        values[key] = value == "on"
                    state["slug"] = slug
                    set_checks(values)
                    refresh_sensitivity()

                _run_on_main(apply)

            backend.run_lpm_async(["vsync", slug, "status"], on_done=done)

        def write(args, ok_toast):
            """Write via the CLI; the checkboxes are blocked during the write (never two
            parallel writes on the same YAML), then re-read from the file."""
            slug = state["slug"]
            if slug is None or state["busy"]:
                return
            state["busy"] = True
            refresh_sensitivity()

            def done(result):
                def apply():
                    if slug != game_row.selected_slug():
                        return
                    if result.returncode != 0:
                        page.toast(t("gui.vsync.toast_failed"))
                    else:
                        page.toast(ok_toast)
                    load_status()
                    refresh_active_status()

                _run_on_main(apply)

            backend.run_lpm_async(["vsync", slug] + args, on_done=done)

        def on_toggled(setting, check):
            if state["loading"]:
                return
            if check.get_active():
                write(["on", setting], t("gui.vsync.toast_on", titles[setting]))
            else:
                write(["off", setting], t("gui.vsync.toast_off", titles[setting]))

        for setting in VSYNC_SETTINGS:
            key = _lang_key(setting)
            titles[setting] = t("gui.vsync." + key + "_title")
            check = Gtk.CheckButton(valign=Gtk.Align.CENTER)
            row = Adw.ActionRow(title=titles[setting], subtitle=t("gui.vsync." + key + "_sub"))
            row.add_prefix(check)
            row.set_activatable_widget(check)
            check.connect("toggled", lambda c, s=setting: on_toggled(s, c))
            group.add(row)
            checks[setting] = check

        all_button = Gtk.Button(label=t("gui.vsync.check_all"), halign=Gtk.Align.END, valign=Gtk.Align.CENTER)
        all_button.add_css_class("pill")

        def on_all_clicked(*_):
            if all(check.get_active() for check in checks.values()):
                write(["off"], t("gui.vsync.toast_all_off"))
            else:
                write(["on"], t("gui.vsync.toast_all_on"))

        all_button.connect("clicked", on_all_clicked)
        button_box = Gtk.Box(halign=Gtk.Align.END, margin_top=6)
        button_box.append(all_button)
        page.page.add(CommandPage._wrap_action_group(button_box))

        game_row.connect_changed(load_status)
        refresh_active_status()
        refresh_sensitivity()

        def reset_fields():
            game_row.clear_selection()
            game_row.refresh()
            load_status()
            refresh_active_status()

        page.reset_selection = reset_fields
        return page
