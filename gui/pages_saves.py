"""Page: back up, restore, export and import the saves of a game (and the automatic mode)."""

import os
import subprocess

import gi

gi.require_version("Gtk", "4.0")
gi.require_version("Adw", "1")
from gi.repository import Adw, Gio, GLib, Gtk  # noqa: E402

import backend
from i18n import t
from commandpage import CommandPage
from util import _run_on_main
from widgets_rows import pick_file, pick_folder
from widgets_select import SingleGameSelect

AUTO_CHOICES = ("follow", "on", "off")


class SavesPage:
    def __init__(self, owner):
        self.owner = owner
        self.window = owner.window
        self.state = {"slug": None, "token": 0, "loading": False, "busy": False}

    def build(self):
        self.page = CommandPage(t("gui.saves.page_title"))
        # Every button acts at once: nothing to "run" at the bottom of the page.
        self.page.run_button.set_visible(False)
        self.page.action_group.set_visible(False)

        self.page.group.set_description(t("gui.saves.intro"))
        # The group of the page holds the game list (a row); the other sections are groups of their
        # own: plain widgets added to a group are shown BELOW its rows, so each group is built in
        # the order it is meant to be read.
        self.game_row = SingleGameSelect()
        self.page.add_row(self.game_row)

        self.game_group = Adw.PreferencesGroup(title=t("gui.saves.game_title"))
        self.page.page.add(self.game_group)
        self.global_group = Adw.PreferencesGroup(title=t("gui.saves.global_title"))
        self.dir_row = Adw.ActionRow(title=t("gui.saves.dir_title"), subtitle=t("gui.saves.dir_none"))
        default_button = Gtk.Button(label=t("gui.saves.dir_default"), valign=Gtk.Align.CENTER)
        default_button.connect("clicked", self.on_default_dir)
        self.dir_row.add_suffix(default_button)
        choose = Gtk.Button(label=t("gui.saves.dir_choose"), valign=Gtk.Align.CENTER)
        choose.connect("clicked", self.on_choose_dir)
        self.dir_row.add_suffix(choose)
        self.global_group.add(self.dir_row)
        self.auto_row = Adw.SwitchRow(title=t("gui.saves.auto_title"), subtitle=t("gui.saves.auto_sub"))
        self.auto_row.connect("notify::active", self.on_auto_toggled)
        self.global_group.add(self.auto_row)
        self.interval_row = Adw.SpinRow.new_with_range(0, 60, 1)
        self.interval_row.set_title(t("gui.saves.interval_title"))
        self.interval_row.set_subtitle(t("gui.saves.interval_sub"))
        self.interval_row.connect("notify::value", self.on_interval_changed)
        self.global_group.add(self.interval_row)

        self.game_auto_row = Adw.ComboRow(title=t("gui.saves.game_auto_title"))
        self.game_auto_row.set_model(Gtk.StringList.new([
            t("gui.saves.game_auto_follow"), t("gui.saves.game_auto_on"), t("gui.saves.game_auto_off")]))
        self.game_auto_row.connect("notify::selected", self.on_game_auto_changed)
        self.game_group.add(self.game_auto_row)

        self.folders_buffer = Gtk.TextBuffer()
        view = Gtk.TextView(buffer=self.folders_buffer, monospace=True, wrap_mode=Gtk.WrapMode.NONE,
                            top_margin=6, bottom_margin=6, left_margin=8, right_margin=8)
        scroller = Gtk.ScrolledWindow(min_content_height=90, max_content_height=160, child=view)
        scroller.add_css_class("card")
        self.folders_label = Gtk.Label(label=t("gui.saves.folders_title"), xalign=0)
        self.folders_label.add_css_class("heading")
        self.folders_hint = Gtk.Label(label=t("gui.saves.folders_hint"), xalign=0, wrap=True)
        self.folders_hint.add_css_class("dim-label")
        self.folders_add = Gtk.Button(label=t("gui.saves.folders_add"))
        self.folders_add.add_css_class("suggested-action")
        self.folders_add.connect("clicked", self.on_folders_add)
        self.folders_save = Gtk.Button(label=t("gui.saves.folders_save"))
        self.folders_default = Gtk.Button(label=t("gui.saves.folders_default"))
        self.folders_save.connect("clicked", self.on_folders_save)
        self.folders_default.connect("clicked", self.on_folders_default)
        folders_buttons = Gtk.Box(spacing=8, halign=Gtk.Align.END)
        folders_buttons.append(self.folders_add)
        folders_buttons.append(self.folders_default)
        folders_buttons.append(self.folders_save)
        folders_box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=6, margin_top=8)
        for w in (self.folders_label, self.folders_hint, scroller, folders_buttons):
            folders_box.append(w)
        self.game_group.add(folders_box)

        # Extra exclusions of this game (on top of the built-in ones): one pattern per line.
        self.exclude_buffer = Gtk.TextBuffer()
        xview = Gtk.TextView(buffer=self.exclude_buffer, monospace=True, wrap_mode=Gtk.WrapMode.NONE,
                             top_margin=6, bottom_margin=6, left_margin=8, right_margin=8)
        xscroller = Gtk.ScrolledWindow(min_content_height=70, max_content_height=140, child=xview)
        xscroller.add_css_class("card")
        xlabel = Gtk.Label(label=t("gui.saves.exclude_title"), xalign=0)
        xlabel.add_css_class("heading")
        xhint = Gtk.Label(label=t("gui.saves.exclude_hint"), xalign=0, wrap=True)
        xhint.add_css_class("dim-label")
        self.exclude_save = Gtk.Button(label=t("gui.saves.exclude_save"))
        self.exclude_save.connect("clicked", self.on_exclude_save)
        xbuttons = Gtk.Box(halign=Gtk.Align.END)
        xbuttons.append(self.exclude_save)
        exclude_box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=6, margin_top=8)
        for w in (xlabel, xhint, xscroller, xbuttons):
            exclude_box.append(w)
        self.game_group.add(exclude_box)

        self.buttons = []
        action_box = Gtk.FlowBox(selection_mode=Gtk.SelectionMode.NONE, max_children_per_line=2,
                                 column_spacing=8, row_spacing=8, homogeneous=True, margin_top=8)
        for label, handler in (("backup", self.on_backup), ("restore", self.on_restore),
                               ("export", self.on_export), ("import", self.on_import),
                               ("reset", self.on_reset)):
            button = Gtk.Button(label=t("gui.saves.btn_" + label))
            button.add_css_class("pill")
            button.connect("clicked", handler)
            action_box.append(button)
            self.buttons.append(button)
        self.game_group.add(action_box)
        self.status_label = Gtk.Label(label="", xalign=0, wrap=True)
        self.status_label.add_css_class("dim-label")
        self.game_group.add(self.status_label)
        self.page.page.add(self.global_group)

        self.game_row.connect_changed(self.load_game)
        self.page.reset_selection = self.reset_fields
        self.page.offer_import = self.offer_import  # called by MainWindow for a .zgs opened from the file manager
        self.load_global()
        self.refresh_sensitivity()
        return self.page

    # --- helpers ---
    def run(self, args, on_ok=None, ok_toast=None, fail_toast=None):
        """Runs "ludis saves <args>" off the main thread, then a toast and optional callback."""
        def done(result):
            def apply():
                if result.returncode == 0:
                    if ok_toast:
                        self.page.toast(ok_toast)
                    if on_ok:
                        on_ok(result)
                else:
                    detail = (result.stdout + result.stderr).strip().splitlines()
                    self.page.toast((detail[-1] if detail else "") or fail_toast or t("gui.common.command_failed", result.returncode))
            _run_on_main(apply)
        backend.run_ludis_async(["saves"] + args, on_done=done)

    def refresh_sensitivity(self):
        game = self.state["slug"] is not None and not self.state["busy"]
        has_dir = self.dir_row.get_subtitle() != t("gui.saves.dir_none")
        for index, button in enumerate(self.buttons):
            # backup / restore / reset need the sync folder; export / import do not
            button.set_sensitive(game and (has_dir if index in (0, 1, 4) else True))
        self.game_auto_row.set_sensitive(game)
        self.folders_save.set_sensitive(game)
        self.folders_add.set_sensitive(game)
        self.folders_default.set_sensitive(game)
        self.exclude_save.set_sensitive(game)

    # --- global ---
    def load_global(self):
        self.state["loading"] = True

        def got_dir(result):
            def apply():
                path = result.stdout.strip() if result.returncode == 0 else ""
                self.dir_row.set_subtitle(path or t("gui.saves.dir_none"))
                self.refresh_sensitivity()
            _run_on_main(apply)

        def got_auto(result):
            def apply():
                self.auto_row.set_active(result.stdout.strip() == "on")
            _run_on_main(apply)

        def got_interval(result):
            def apply():
                try:
                    self.interval_row.set_value(int(result.stdout.strip()))
                except ValueError:
                    self.interval_row.set_value(10)
                self.state["loading"] = False
            _run_on_main(apply)

        backend.run_ludis_async(["saves", "dir"], on_done=got_dir)
        backend.run_ludis_async(["saves", "auto"], on_done=got_auto)
        backend.run_ludis_async(["saves", "interval"], on_done=got_interval)

    def on_default_dir(self, *_):
        self.run(["dir", "default"], ok_toast=t("gui.saves.toast_dir"), on_ok=lambda _r: self.load_global())

    def on_choose_dir(self, *_):
        current = self.dir_row.get_subtitle()
        if not os.path.isdir(current):
            current = GLib.get_user_special_dir(GLib.UserDirectory.DIRECTORY_DOCUMENTS) or os.path.expanduser("~")

        def chosen(path):
            if path:
                self.run(["dir", path], ok_toast=t("gui.saves.toast_dir"), on_ok=lambda _r: self.load_global())
        pick_folder(self.window, t("gui.saves.dir_choose_title"), chosen,
                    initial_folder=current if os.path.isdir(current) else None)

    def on_auto_toggled(self, row, _pspec):
        if not self.state["loading"]:
            self.run(["auto", "on" if row.get_active() else "off"])

    def on_interval_changed(self, row, _pspec):
        if not self.state["loading"]:
            self.run(["interval", str(int(row.get_value()))])

    # --- one game ---
    def load_game(self):
        slug = self.game_row.selected_slug()
        self.state["token"] += 1
        token = self.state["token"]
        self.state["slug"] = None
        self.status_label.set_label("")
        self.refresh_sensitivity()
        if not slug:
            return

        def apply_all(results):
            def apply():
                if token != self.state["token"]:
                    return
                auto, folders, status, excludes = results
                if auto.returncode != 0:
                    self.page.toast(t("gui.saves.toast_load_failed"))
                    return
                self.state["loading"] = True
                value = dict(p.split("=", 1) for p in auto.stdout.split() if "=" in p).get("game", "follow")
                self.game_auto_row.set_selected(AUTO_CHOICES.index(value) if value in AUTO_CHOICES else 0)
                self.folders_buffer.set_text(folders.stdout.strip())
                self.exclude_buffer.set_text(excludes.stdout.strip())
                self.state["loading"] = False
                self.status_label.set_label(self.describe(status.stdout))
                self.state["slug"] = slug
                self.refresh_sensitivity()
            _run_on_main(apply)

        results = []

        def collect(result):
            results.append(result)
            if len(results) == 4:
                apply_all(results)

        # run in order so that results[0..2] are auto, folders, status
        def chain(commands):
            if not commands:
                return
            args, rest = commands[0], commands[1:]
            backend.run_ludis_async(args, on_done=lambda r: (collect(r), chain(rest)))
        chain([["saves", slug, "auto"], ["saves", slug, "folders", "list"], ["saves", slug, "status"],
               ["saves", slug, "exclude", "list"]])

    @staticmethod
    def describe(status_out):
        values = {}
        for line in status_out.splitlines():
            for token in line.split(" "):
                if "=" in token:
                    k, _, v = token.partition("=")
                    values[k] = v
        backup = [ln for ln in status_out.splitlines() if ln.startswith("backup=")]
        text = backup[0][len("backup="):].split(" previous=")[0] if backup else "none"
        if text == "none":
            return t("gui.saves.status_nobackup")
        return t("gui.saves.status_backup", text)

    def busy(self, flag):
        self.state["busy"] = flag
        self.refresh_sensitivity()

    def after(self, result):
        self.busy(False)
        self.load_game()

    def game_run(self, args, ok_toast):
        slug = self.state["slug"]
        if not slug or self.state["busy"]:
            return
        self.busy(True)

        def done(result):
            def apply():
                self.busy(False)
                if result.returncode == 0:
                    self.page.toast(ok_toast)
                else:
                    detail = (result.stdout + result.stderr).strip().splitlines()
                    self.page.toast((detail[-1] if detail else "") or t("gui.common.command_failed", result.returncode))
                self.load_game()
            _run_on_main(apply)
        backend.run_ludis_async(["saves", slug] + args, on_done=done)

    def on_game_auto_changed(self, row, _pspec):
        if self.state["loading"] or not self.state["slug"]:
            return
        self.game_run(["auto", AUTO_CHOICES[row.get_selected()]], t("gui.saves.toast_game_auto"))

    def on_backup(self, *_):
        self.game_run(["backup"], t("gui.saves.toast_backup"))

    def on_restore(self, *_):
        slug = self.state["slug"]
        if not slug:
            return
        dialog = Adw.AlertDialog(heading=t("gui.saves.restore_confirm_title"), body=t("gui.saves.restore_confirm_body"))
        dialog.add_response("cancel", t("gui.common.cancel"))
        dialog.add_response("restore", t("gui.saves.btn_restore"))
        dialog.set_response_appearance("restore", Adw.ResponseAppearance.SUGGESTED)
        dialog.connect("response", lambda _d, r: r == "restore" and self.game_run(["restore"], t("gui.saves.toast_restore")))
        dialog.present(self.window)

    def on_reset(self, *_):
        if not self.state["slug"]:
            return
        dialog = Adw.AlertDialog(heading=t("gui.saves.reset_confirm_title"), body=t("gui.saves.reset_confirm_body"))
        dialog.add_response("cancel", t("gui.common.cancel"))
        dialog.add_response("reset", t("gui.saves.btn_reset"))
        dialog.set_response_appearance("reset", Adw.ResponseAppearance.DESTRUCTIVE)
        dialog.connect("response", lambda _d, r: r == "reset" and self.game_run(["reset", "--yes"], t("gui.saves.toast_reset")))
        dialog.present(self.window)

    def on_export(self, *_):
        slug = self.state["slug"]
        if not slug:
            return
        dialog = Gtk.FileDialog(title=t("gui.saves.export_title"))
        dialog.set_initial_name(slug + "-saves.zgs")

        def on_result(dlg, res):
            try:
                f = dlg.save_finish(res)
            except GLib.Error:
                return
            if f and f.get_path():
                self.game_run(["export", f.get_path()], t("gui.saves.toast_export"))
        dialog.save(self.window, None, on_result)

    def offer_import(self, path):
        """A .zgs opened from the file manager: select the game named in the archive and ask
        before importing (the saves of the game are replaced, the current ones are kept)."""
        info = {}
        try:
            proc = subprocess.run(["bash", "-c", 'zstd -dcq -- "$1" 2>/dev/null | tar -xOf - ./.ludis-saves 2>/dev/null', "_", path],
                                  capture_output=True, text=True, timeout=60)
            for line in proc.stdout.splitlines():
                if "=" in line:
                    k, _, v = line.partition("=")
                    info.setdefault(k, v)
        except (OSError, subprocess.SubprocessError):
            pass
        slug, name = info.get("slug", ""), info.get("name", "")
        if info.get("ludis-saves") != "1" or not slug:
            self.page.toast(t("gui.saves.open_invalid"))
            return
        self.game_row.select_slug(slug)
        dialog = Adw.AlertDialog(heading=t("gui.saves.open_title", name or slug),
                                 body=t("gui.saves.open_body", os.path.basename(path)))
        dialog.add_response("cancel", t("gui.common.cancel"))
        dialog.add_response("import", t("gui.saves.btn_import"))
        dialog.set_response_appearance("import", Adw.ResponseAppearance.SUGGESTED)

        def answered(_d, response):
            if response != "import":
                return
            # The game list may still be loading: wait for the selection to be effective.
            def go(tries=0):
                if self.game_row.selected_slug() == slug and self.state["slug"] == slug and not self.state["busy"]:
                    self.import_file(path)
                elif tries < 50:
                    GLib.timeout_add(200, lambda: go(tries + 1) and False)
                else:
                    self.page.toast(t("gui.saves.open_missing", slug))
                return False
            go()
        dialog.connect("response", answered)
        dialog.present(self.window)

    def import_file(self, path):
        """Import a .zgs. If the folders to save written in it differ from those of the game, ask
        which ones win (the archive's, the game's, or both) before importing."""
        slug = self.state["slug"]
        if not slug or self.state["busy"]:
            return
        self.busy(True)

        def checked(result):
            def apply():
                self.busy(False)
                if result.returncode != 0 or "differs" not in result.stdout:
                    self.game_run(["import", path], t("gui.saves.toast_import"))
                    return
                dialog = Adw.AlertDialog(heading=t("gui.saves.conflict_title"), body=t("gui.saves.conflict_body"))
                dialog.add_response("cancel", t("gui.common.cancel"))
                for rid in ("keep", "merge", "zgs"):
                    dialog.add_response(rid, t("gui.saves.conflict_" + rid))
                dialog.set_response_appearance("zgs", Adw.ResponseAppearance.SUGGESTED)
                dialog.set_default_response("zgs")
                dialog.set_close_response("cancel")

                def answered(_d, response):
                    if response in ("zgs", "keep", "merge"):
                        self.game_run(["import", path, "--folders", response], t("gui.saves.toast_import"))
                dialog.connect("response", answered)
                dialog.present(self.window)
            _run_on_main(apply)
        backend.run_ludis_async(["saves", slug, "import", path, "--check"], on_done=checked)

    def on_import(self, *_):
        slug = self.state["slug"]
        if not slug:
            return

        def chosen(paths):
            if paths:
                self.import_file(paths[0])
        pick_file(self.window, t("gui.saves.import_title"), chosen, filters=[(t("gui.saves.filter"), ["*.zgs"])])

    def on_folders_save(self, *_):
        slug = self.state["slug"]
        if not slug or self.state["busy"]:
            return
        start, end = self.folders_buffer.get_bounds()
        lines = [ln.strip() for ln in self.folders_buffer.get_text(start, end, False).splitlines() if ln.strip()]
        if not lines:
            self.page.toast(t("gui.saves.folders_empty"))
            return
        self.busy(True)
        commands = [["saves", slug, "folders", "reset"], ["saves", slug, "folders", "add", lines[0]]] \
            + [["saves", slug, "folders", "add", ln] for ln in lines[1:]]
        # "add" starts from the defaults the first time: drop them so that the list is exactly the one typed
        commands += [["saves", slug, "folders", "remove", d] for d in ("AppData", "Documents", "Saved Games") if d not in lines]
        failed = []

        def chain(rest):
            if not rest:
                def finish():
                    self.busy(False)
                    self.page.toast(t("gui.saves.folders_invalid") if failed else t("gui.saves.toast_folders"))
                    self.load_game()
                _run_on_main(finish)
                return

            def done(result):
                if result.returncode != 0:
                    failed.append(rest[0])
                chain(rest[1:])
            backend.run_ludis_async(rest[0], on_done=done)
        chain(commands)

    def on_exclude_save(self, *_):
        slug = self.state["slug"]
        if not slug or self.state["busy"]:
            return
        start, end = self.exclude_buffer.get_bounds()
        lines = [ln.strip() for ln in self.exclude_buffer.get_text(start, end, False).splitlines() if ln.strip()]
        self.busy(True)
        commands = [["saves", slug, "exclude", "reset"]] + [["saves", slug, "exclude", "add", ln] for ln in lines]
        failed = []

        def chain(rest):
            if not rest:
                def finish():
                    self.busy(False)
                    self.page.toast(t("gui.saves.folders_invalid") if failed else t("gui.saves.toast_exclude"))
                    self.load_game()
                _run_on_main(finish)
                return

            def done(result):
                if result.returncode != 0:
                    failed.append(rest[0])
                chain(rest[1:])
            backend.run_ludis_async(rest[0], on_done=done)
        chain(commands)

    def on_folders_add(self, *_):
        """Pick a folder INSIDE the prefix (the picker opens in the game's Windows user folder);
        the CLI turns the chosen path into the right entry (user folder, or elsewhere in drive_c)."""
        slug = self.state["slug"]
        if not slug or self.state["busy"]:
            return

        def got_path(result):
            def open_picker():
                start = result.stdout.strip() if result.returncode == 0 else None

                def chosen(path):
                    if path:
                        self.game_run(["folders", "add", path], t("gui.saves.toast_folders"))
                pick_folder(self.window, t("gui.saves.folders_add_title"), chosen, initial_folder=start)
            _run_on_main(open_picker)
        backend.run_ludis_async(["saves", slug, "path"], on_done=got_path)

    def on_folders_default(self, *_):
        self.game_run(["folders", "reset"], t("gui.saves.toast_folders_default"))

    def reset_fields(self):
        self.game_row.clear_selection()
        self.game_row.refresh()
        self.load_game()


class SavesPages:
    def page_saves(self):
        return SavesPage(self).build()
