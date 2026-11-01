"""Page "Game tools": winetricks, regedit, wine configuration, console, executable, favorite
folder, environment variables, runner, MangoHud and gamepad profile for ONE game."""

import os
import re
import tempfile

import gi

gi.require_version("Gtk", "4.0")
gi.require_version("Adw", "1")
from gi.repository import Adw, GLib, Gtk  # noqa: E402

import backend
from i18n import t
from commandpage import CommandPage
from util import _run_on_main
from widgets_rows import pick_file, pick_folder
from widgets_select import RunnerCombo, SingleChoiceSelect, SingleGameSelect

# Accepted extensions for the "exe" tool (same as the native picker filter, see _add_exe_row).
# Checked again when running: a Gtk.FileDialog filter is only indicative and usually also
# offers "All files", so it guarantees nothing on its own; the tool must never run with
# anything other than a real .exe, .msi, .bat or .cmd.
_EXE_TOOL_EXTENSIONS = (".exe", ".msi", ".bat", ".cmd")


class ToolsPage:
    def __init__(self, window):
        self.window = window
        self.exe_path = ""

    def build(self):
        self._add_game_and_tool_rows()
        self._add_exe_row()
        self._add_favorite_row()
        self._add_runner_row()
        self._add_mangohud_row()
        self._add_gamepad_rows()
        self._add_env_row()
        self._wire_visibility()
        self._wire_reset_and_run()
        return self.page

    def _add_game_and_tool_rows(self):
        self.page = CommandPage(t("gui.tools.page_title"))
        self.game_row = SingleGameSelect()
        self.page.add_row(self.game_row)

        # tool_ids: technical values passed as is as a CLI argument ("tools <slug>
        # <tool_id>", see lib/zgp-game-tools.sh) -- never translated. tool_labels: text shown
        # in the dropdown, in the same order -- the two lists are decoupled (as for
        # "flatpak"/"native"/"reset" in page_lutris_version), so translating the display never
        # touches the arguments sent to bin/lpm.
        self.tools = ["winetricks", "regedit", "winecfg", "console", "exe", "folder", "favorite", "env", "runner", "mangohud", "gamepad"]
        tool_labels = [
            t("gui.tools.tool_winetricks"),
            t("gui.tools.tool_regedit"),
            t("gui.tools.tool_winecfg"),
            t("gui.tools.tool_console"),
            t("gui.tools.tool_exe"),
            t("gui.tools.tool_folder"),
            t("gui.tools.tool_favorite"),
            t("gui.tools.tool_env"),
            t("gui.tools.tool_runner"),
            t("gui.tools.tool_mangohud"),
            t("gui.tools.tool_gamepad"),
        ]
        # Same list style as the game selector (scrolls inside the page): a classic dropdown
        # hid the last tools when the window was not tall enough.
        self.tool_row = SingleChoiceSelect(t("gui.tools.tool_title"), tool_labels)
        self.page.add_row(self.tool_row)

    def _add_exe_row(self):
        # Executable path -- visible only for the "exe" tool (winetricks/registry
        # editor/Wine configuration/console/folder need no path). No default value is
        # possible (no "default" executable makes sense): just a button to pick one.
        self.exe_path = ""
        self.exe_path_row = Adw.ActionRow(title=t("gui.tools.exe_path_title"),
                                      subtitle=t("gui.common.no_file_selected"))

        def choose_exe():
            def got(paths):
                if paths:
                    self.exe_path = paths[0]
                    self.exe_path_row.set_subtitle(self.exe_path)

            # Filter imposed on the native picker (not just indicative): a file of another
            # type must not be selectable. Same extensions as "install an .exe"
            # (gui.exe_install.filter_label) for consistency.
            pick_file(self.window, t("gui.common.choose_executable_title"), got,
                      [(t("gui.exe_install.filter_label"), ["*.exe", "*.msi", "*.bat", "*.cmd"])])

        exe_choose_btn = Gtk.Button(icon_name="document-open-symbolic", valign=Gtk.Align.CENTER)
        exe_choose_btn.connect("clicked", lambda *_: choose_exe())
        self.exe_path_row.add_suffix(exe_choose_btn)
        self.page.add_row(self.exe_path_row)

    def _add_favorite_row(self):
        # Favorite folder -- visible only for the "favorite" tool. Same principle as
        # DesktopPathRow (install page / "Launch settings"): pre-filled (here with the home
        # folder) and editable directly or via "Browse", rather than an empty field.
        self.favorite_path_row = Adw.EntryRow(title=t("gui.tools.favorite_path_title"))

        self._reset_favorite_path()

        def _browse_favorite(*_):
            def got(path):
                if path:
                    self.favorite_path_row.set_text(path)

            pick_folder(self.window, t("gui.tools.choose_folder_dialog_title"), got)

        favorite_browse_btn = Gtk.Button(icon_name="folder-open-symbolic", valign=Gtk.Align.CENTER)
        favorite_browse_btn.connect("clicked", _browse_favorite)
        self.favorite_path_row.add_suffix(favorite_browse_btn)
        self.page.add_row(self.favorite_path_row)

    def _add_runner_row(self):
        # New runner for the game -- visible only for the "runner" tool. No runner is applied
        # until the user picks one (see explicit_runner).
        self.runner_row = RunnerCombo(title=t("gui.tools.runner_title"), placeholder=t("gui.tools.runner_placeholder"))
        self.page.add_row(self.runner_row)

    def _add_mangohud_row(self):
        # MangoHud switch -- visible only for the "mangohud" tool. One game at a time: the
        # position is read from the chosen game's Lutris config ("tools <slug> mangohud status"),
        # never carried over from another game; "Run" applies it ("mangohud on" / "mangohud off").
        self.mangohud_row = Adw.SwitchRow(title=t("gui.tools.mangohud_switch_title"))
        self.mangohud_row.set_sensitive(False)
        self.page.add_row(self.mangohud_row)
        self.mangohud_state = {"slug": None, "token": 0}

    def _add_gamepad_rows(self):
        # Gamepad profile (AntiMicroX) -- visible only for the "gamepad" tool. Same pattern as
        # MangoHud: the position ("on", "off" or "other" = a profile of the user's own) is read
        # per game ("tools <slug> gamepad status"); "Run" applies it. A separate row opens the
        # profile in AntiMicroX ("tools <slug> gamepad edit"), nothing is watched.
        self.gamepad_row = Adw.SwitchRow(title=t("gui.tools.gamepad_switch_title"))
        self.gamepad_row.set_sensitive(False)
        self.page.add_row(self.gamepad_row)
        self.gamepad_edit_row = Adw.ActionRow(title=t("gui.tools.gamepad_edit_title"))
        self.gamepad_edit_button = Gtk.Button(label=t("gui.tools.gamepad_edit_button"), valign=Gtk.Align.CENTER)
        self.gamepad_edit_row.add_suffix(self.gamepad_edit_button)
        self.page.add_row(self.gamepad_edit_row)
        self.gamepad_state = {"slug": None, "token": 0, "updating": False}

        self.gamepad_edit_button.connect("clicked", self._on_gamepad_edit)

        self.gamepad_row.connect("notify::active", self._on_gamepad_toggled)

    def _add_env_row(self):
        # Environment variables editor -- visible only for the "env" tool. One game at a
        # time: the content is re-read from the chosen game's Lutris config ("tools <slug> env
        # list"), never mixed between games.
        self.env_box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=8)
        env_title = Gtk.Label(label=t("gui.tools.env_warning_title"), xalign=0, wrap=True)
        env_title.add_css_class("heading")
        env_warning = Gtk.Label(label=t("gui.tools.env_warning"), xalign=0, wrap=True)
        env_warning.add_css_class("dim-label")
        self.env_view = Gtk.TextView(monospace=True, wrap_mode=Gtk.WrapMode.NONE,
                                top_margin=6, bottom_margin=6, left_margin=8, right_margin=8)
        env_scroll = Gtk.ScrolledWindow(min_content_height=160, hexpand=True)
        env_scroll.set_child(self.env_view)
        env_frame = Gtk.Frame()
        env_frame.set_child(env_scroll)
        self.env_box.append(env_title)
        self.env_box.append(env_warning)
        self.env_box.append(env_frame)
        self.page.add_row(self.env_box)
        self.env_state = {"slug": None, "token": 0}
        self.env_buffer = self.env_view.get_buffer()

    def _wire_visibility(self):
        self.tool_row.connect("notify::selected", self._update_path_rows_visibility)
        self.game_row.connect_changed(self._update_path_rows_visibility)
        self._update_path_rows_visibility()

    def _wire_reset_and_run(self):
        self.page.reset_selection = self.reset_fields

        self.page.run_button.connect("clicked", self.on_run)

    def _reset_favorite_path(self):
        self.favorite_path_row.set_text(GLib.get_home_dir())

    def _load_mangohud(self):
        slug = self.game_row.selected_slug()
        self.mangohud_state["token"] += 1
        token = self.mangohud_state["token"]
        self.mangohud_state["slug"] = None
        self.mangohud_row.set_sensitive(False)
        self.mangohud_row.set_active(False)
        if not slug or self.tool_row.get_selected() != self.tools.index("mangohud"):
            return

        def done(result):
            def apply():
                # Stale response (another game / tool chosen in the meantime): ignored.
                if token != self.mangohud_state["token"]:
                    return
                if result.returncode != 0:
                    self.page.toast(t("gui.common.command_failed", result.returncode))
                    return
                self.mangohud_row.set_active(result.stdout.strip() == "on")
                self.mangohud_state["slug"] = slug
                self.mangohud_row.set_sensitive(True)

            _run_on_main(apply)

        backend.run_lpm_async(["tools", slug, "mangohud", "status"], on_done=done)

    def _load_gamepad(self):
        slug = self.game_row.selected_slug()
        self.gamepad_state["token"] += 1
        token = self.gamepad_state["token"]
        self.gamepad_state["slug"] = None
        self.gamepad_row.set_sensitive(False)
        self.gamepad_state["updating"] = True
        self.gamepad_row.set_active(False)
        self.gamepad_state["updating"] = False
        self.gamepad_edit_button.set_sensitive(False)
        if not slug or self.tool_row.get_selected() != self.tools.index("gamepad"):
            return

        def done(result):
            def apply():
                # Stale response (another game / tool chosen in the meantime): ignored.
                if token != self.gamepad_state["token"]:
                    return
                if result.returncode != 0:
                    self.page.toast(t("gui.common.command_failed", result.returncode))
                    return
                state = result.stdout.strip()
                if state == "other":
                    self.page.toast(t("gui.tools.gamepad_other"))
                    return
                self.gamepad_state["updating"] = True
                self.gamepad_row.set_active(state == "on")
                self.gamepad_state["updating"] = False
                self.gamepad_state["slug"] = slug
                self.gamepad_row.set_sensitive(True)
                self.gamepad_edit_button.set_sensitive(state == "on")

            _run_on_main(apply)

        backend.run_lpm_async(["tools", slug, "gamepad", "status"], on_done=done)

    def _on_gamepad_edit(self, _btn):
        slug = self.gamepad_state["slug"]
        if not slug:
            return

        def done(result):
            def apply():
                if result.returncode != 0:
                    self.page.toast(t("gui.common.command_failed", result.returncode))
                else:
                    self.page.toast(t("gui.tools.gamepad_edit_started"))

            _run_on_main(apply)

        backend.run_lpm_async(["tools", slug, "gamepad", "edit"], on_done=done)

    # No "Run" button for this tool: ticking / unticking the switch applies at once
    # ("tools <slug> gamepad on|off"); on failure the switch goes back to its old position.
    def _on_gamepad_toggled(self, row, _pspec):
        slug = self.gamepad_state["slug"]
        if self.gamepad_state["updating"] or not slug:
            return
        want = row.get_active()
        token = self.gamepad_state["token"]
        row.set_sensitive(False)

        def done(result):
            def apply():
                if token != self.gamepad_state["token"]:
                    return  # another game / tool chosen in the meantime
                if result.returncode != 0:
                    self.page.toast(t("gui.common.command_failed", result.returncode))
                    self.gamepad_state["updating"] = True
                    row.set_active(not want)
                    self.gamepad_state["updating"] = False
                else:
                    self.page.toast(t("gui.tools.gamepad_done"))
                    self.gamepad_edit_button.set_sensitive(want)
                row.set_sensitive(True)

            _run_on_main(apply)

        backend.run_lpm_async(["tools", slug, "gamepad", "on" if want else "off"], on_done=done)

    def _load_env(self):
        slug = self.game_row.selected_slug()
        self.env_state["token"] += 1
        token = self.env_state["token"]
        self.env_state["slug"] = None
        self.env_buffer.set_text("")
        self.env_view.set_sensitive(False)
        if not slug or self.tool_row.get_selected() != self.tools.index("env"):
            return

        def done(result):
            def apply():
                # Stale response (another game / tool chosen in the meantime): ignored.
                if token != self.env_state["token"]:
                    return
                if result.returncode != 0:
                    self.page.toast(t("gui.tools.env_toast_load_failed"))
                    return
                self.env_buffer.set_text(result.stdout)
                self.env_state["slug"] = slug
                self.env_view.set_sensitive(True)

            _run_on_main(apply)

        backend.run_lpm_async(["tools", slug, "env", "list"], on_done=done)

    def _update_path_rows_visibility(self, *_):
        idx = self.tool_row.get_selected()
        self.exe_path_row.set_visible(idx == 4)
        self.favorite_path_row.set_visible(idx == 6)
        self.env_box.set_visible(idx == self.tools.index("env"))
        self.runner_row.set_visible(idx == self.tools.index("runner"))
        self.mangohud_row.set_visible(idx == self.tools.index("mangohud"))
        self.gamepad_row.set_visible(idx == self.tools.index("gamepad"))
        self.gamepad_edit_row.set_visible(idx == self.tools.index("gamepad"))
        self.page.run_button.set_visible(idx != self.tools.index("gamepad"))
        self._load_env()
        self._load_mangohud()
        self._load_gamepad()

    # Reset after a successful run and when leaving the page, like "install an .exe"
    # (see CommandPage.reset_selection).
    def reset_fields(self):
        # clear_selection() BEFORE refresh() -- same as page_launcher, see
        # SingleGameSelect.clear_selection (this selector is shared between both pages).
        self.game_row.clear_selection()
        self.game_row.refresh()
        self.tool_row.set_selected(0)
        self.runner_row.refresh()
        self.exe_path = ""
        self.exe_path_row.set_subtitle(t("gui.common.no_file_selected"))
        self._reset_favorite_path()
        self._update_path_rows_visibility()
        self.env_buffer.set_text("")

    def on_run(self, *_):
        slug = self.game_row.selected_slug()
        if not slug:
            self.page.toast(t("gui.tools.toast_choose_game"))
            return
        idx = self.tool_row.get_selected()
        tool = self.tools[idx] if idx != Gtk.INVALID_LIST_POSITION else self.tools[0]
        extra_args = self._tool_arguments(tool, slug)
        if extra_args is None:  # invalid input: the reason was already shown
            return
        self.page.run_command(["tools", slug, tool] + extra_args, t(self._DONE_MESSAGES.get(tool, "gui.tools.done")))

    # Message shown after a successful run, for the tools that have their own.
    _DONE_MESSAGES = {"runner": "gui.tools.runner_done", "mangohud": "gui.tools.mangohud_done",
                      "env": "gui.tools.env_done"}

    def _tool_arguments(self, tool, slug):
        """Arguments added after "tools <slug> <tool>", or None when the input is invalid."""
        if tool == "exe":
            return self._exe_arguments()
        if tool == "favorite":
            favorite_path = self.favorite_path_row.get_text().strip()
            return [favorite_path] if favorite_path else []
        if tool == "runner":
            new_runner = self.runner_row.explicit_runner()
            if not new_runner:
                self.page.toast(t("gui.tools.toast_choose_runner"))
                return None
            return [new_runner]
        if tool == "mangohud":
            # Not read yet (or read failed): never write a state that was not loaded.
            if self.mangohud_state["slug"] != slug:
                self.page.toast(t("gui.common.command_failed", "?"))
                return None
            return ["on" if self.mangohud_row.get_active() else "off"]
        if tool == "env":
            return self._env_arguments(slug)
        return []

    def _exe_arguments(self):
        if not self.exe_path or not self.exe_path.lower().endswith(_EXE_TOOL_EXTENSIONS):
            self.page.toast(t("gui.tools.toast_invalid_exe"))
            return None
        return [self.exe_path]

    def _env_arguments(self, slug):
        # Not read yet (or read failed): never overwrite the config with an empty
        # field that was not loaded.
        if self.env_state["slug"] != slug:
            self.page.toast(t("gui.tools.env_toast_load_failed"))
            return None
        start, end = self.env_buffer.get_bounds()
        env_lines = [ln.rstrip("\r") for ln in self.env_buffer.get_text(start, end, False).split("\n") if ln.strip()]
        for ln in env_lines:
            name = ln.split("=", 1)[0].strip()
            if "=" not in ln or not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", name):
                self.page.toast(t("gui.tools.env_toast_invalid", ln))
                return None
        fd, env_tmp = tempfile.mkstemp(prefix="lpm-env-", suffix=".txt")
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            fh.write("\n".join(env_lines) + ("\n" if env_lines else ""))
        GLib.timeout_add_seconds(120, lambda: (os.path.exists(env_tmp) and os.unlink(env_tmp)) and False)
        return ["apply", env_tmp]
