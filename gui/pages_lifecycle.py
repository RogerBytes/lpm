"""Pages: install, uninstall, prefixes, packing, isolation."""


import gi

gi.require_version("Gtk", "4.0")
gi.require_version("Adw", "1")
from gi.repository import Adw, Gtk  # noqa: E402

import backend
from i18n import t
from util import _run_on_main
from commandpage import CommandPage
from widgets_rows import (PrefixEntryRow, add_compression_rows, add_shortcut_rows, ask_keep_or_delete,
                          pick_file, sibling_files)
from widgets_select import FileMultiSelect, GameMultiSelect, RunnerCombo


class CreatePrefixPage:
    def __init__(self, owner):
        self.owner = owner
        self.window = owner.window

    def build(self):
        self._add_rows_box()
        self._add_runner_rows()
        self._wire_reset_and_run()
        return self.page

    def _add_rows_box(self):
        self.page = CommandPage(t("gui.create_prefix.page_title"))

        # Repeatable list of PrefixEntryRow (name + slug, see that class): one row at the
        # start, "+" on a row adds one right after it (Gtk.Box.insert_child_after), the trash
        # button removes it (never the last remaining one, see update_remove_sensitivity).
        # Each row is already a separate entry, with a live slug preview like Lutris.
        self.rows_box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=2)
        self.page.add_row(self.rows_box)

        self.add_row()

    def _add_runner_rows(self):
        self.runner_row = RunnerCombo()
        self.page.add_row(self.runner_row)
        self.arch_row = Adw.ComboRow(title=t("gui.common.arch_title"))
        self.arch_row.set_model(Gtk.StringList.new(["win64", "win32"]))
        self.page.add_row(self.arch_row)

    def _wire_reset_and_run(self):
        self.page.reset_selection = self.reset_fields

        self.page.run_button.connect("clicked", self.on_run)

    def iter_rows(self):
        child = self.rows_box.get_first_child()
        while child is not None:
            yield child
            child = child.get_next_sibling()

    def update_remove_sensitivity(self):
        rows = list(self.iter_rows())
        only_one = len(rows) <= 1
        for row in rows:
            row.remove_btn.set_sensitive(not only_one)

    def add_row(self, after_row=None):
        new_row = PrefixEntryRow(on_add=self.add_row, on_remove=self.remove_row)
        if after_row is None:
            self.rows_box.append(new_row)
        else:
            self.rows_box.insert_child_after(new_row, after_row)
        self.update_remove_sensitivity()

    def remove_row(self, row):
        if len(list(self.iter_rows())) <= 1:
            return
        self.rows_box.remove(row)
        self.update_remove_sensitivity()

    def reset_rows(self):
        rows = list(self.iter_rows())
        for extra in rows[1:]:
            self.rows_box.remove(extra)
        if rows:
            rows[0].reset()
        self.update_remove_sensitivity()

    # Runner and architecture are reset too, see CommandPage.reset_selection.
    def reset_fields(self):
        self.reset_rows()
        self.runner_row.refresh()
        self.arch_row.set_selected(0)

    def on_run(self, *_):
        targets = [spec for row in self.iter_rows() if (spec := row.target_spec())]
        if not targets:
            self.page.toast(t("gui.create_prefix.toast_need_name"))
            return
        runner = self.runner_row.selected_runner()
        arch_idx = self.arch_row.get_selected()
        arch = "win64" if arch_idx in (0, Gtk.INVALID_LIST_POSITION) else "win32"
        args = ["create-prefix", "-y"]
        if runner:
            args.extend(["-r", runner])
        args.extend(["-a", arch, *targets])
        self.page.run_command(args, t("gui.create_prefix.done"), refresh="games")



class ExeInstallPage:
    def __init__(self, owner):
        self.owner = owner
        self.window = owner.window

    def build(self):
        self._add_exe_row()
        self._add_name_rows()
        self._add_runner_rows()
        self._wire_reset_and_run()
        return self.page

    def _add_exe_row(self):
        self.page = CommandPage(t("gui.exe_install.page_title"))
        self.exe_path = ""
        self.path_row = Adw.ActionRow(title=t("gui.exe_install.exe_title"), subtitle=t("gui.common.no_file_selected"))

        choose_btn = Gtk.Button(icon_name="document-open-symbolic", valign=Gtk.Align.CENTER)
        choose_btn.connect("clicked", lambda *_: self.choose())
        self.path_row.add_suffix(choose_btn)
        self.page.add_row(self.path_row)

    def _add_name_rows(self):
        self.name_row = Adw.EntryRow(title=t("gui.exe_install.name_title"))
        self.page.add_row(self.name_row)
        self.slug_row = Adw.EntryRow(title=t("gui.exe_install.slug_title"))
        self.page.add_row(self.slug_row)

        # Live slug preview from the name, same behavior as "create an empty prefix" (see
        # PrefixEntryRow): filled automatically until the user edits the slug field, after
        # which tracking is PERMANENTLY detached.
        self.slug_follows_name = True
        self.updating_slug = False

        self.name_row.connect("changed", self._on_name_changed)
        self.slug_row.connect("changed", self._on_slug_changed)

    def _add_runner_rows(self):
        self.runner_row = RunnerCombo()
        self.page.add_row(self.runner_row)
        self.arch_row = Adw.ComboRow(title=t("gui.common.arch_title"))
        self.arch_row.set_model(Gtk.StringList.new(["win64", "win32"]))
        self.page.add_row(self.arch_row)
        self.final_exe_row = Adw.EntryRow(title=t("gui.exe_install.final_exe_title"))
        self.page.add_row(self.final_exe_row)

    def _wire_reset_and_run(self):
        self.page.reset_selection = self.reset_fields

        self.page.run_button.connect("clicked", self.on_run)

    def choose(self):
        def got(paths):
            if paths:
                self.exe_path = paths[0]
                self.path_row.set_subtitle(self.exe_path)

        # zgp-exe-installer.sh natively handles .exe/.msi/.bat/.cmd (it just runs
        # "wine <file>", which dispatches to msiexec/cmd.exe by extension -- see the
        # header comment of that script); only this dialog's filter restricted the choice
        # to .exe.
        pick_file(self.window, t("gui.exe_install.choose_dialog_title"), got,
                  [(t("gui.exe_install.filter_label"), ["*.exe", "*.msi", "*.bat", "*.cmd"])])

    def _on_name_changed(self, *_):
        if not self.slug_follows_name:
            return
        name = self.name_row.get_text()
        self.updating_slug = True
        self.slug_row.set_text(backend.slugify_preview(name) if name.strip() else "")
        self.updating_slug = False

    def _on_slug_changed(self, *_):
        if self.updating_slug:
            return
        self.slug_follows_name = False

    # Reset after a successful run and when leaving the page (see
    # CommandPage.reset_selection).
    def reset_fields(self):
        self.exe_path = ""
        self.path_row.set_subtitle(t("gui.common.no_file_selected"))
        self.updating_slug = True
        self.name_row.set_text("")
        self.slug_row.set_text("")
        self.updating_slug = False
        self.slug_follows_name = True
        self.runner_row.refresh()
        self.arch_row.set_selected(0)
        self.final_exe_row.set_text("")

    def on_run(self, *_):
        name = self.name_row.get_text().strip()
        if not self.exe_path or not name:
            self.page.toast(t("gui.exe_install.toast_need_exe_and_name"))
            return
        target = f"{self.exe_path}|{name}"
        # Explicit slug passed only if edited by hand AND different from the automatic
        # preview -- same principle as PrefixEntryRow.target_spec(): otherwise let the
        # backend (zgp_slugify, identical to backend.slugify_preview) derive it from the name.
        if not self.slug_follows_name:
            slug = self.slug_row.get_text().strip()
            if slug and slug != backend.slugify_preview(name):
                target += f"|{slug}"
        runner = self.runner_row.selected_runner()
        arch = "win64" if self.arch_row.get_selected() in (0, Gtk.INVALID_LIST_POSITION) else "win32"
        args = ["exe-install", "-y", target]
        if runner:
            args.extend(["-r", runner])
        args.extend(["-a", arch])
        if self.final_exe_row.get_text().strip():
            args.extend(["-f", self.final_exe_row.get_text().strip()])
        self.page.run_command(args, t("gui.common.install_done"), refresh="games")



HOOKS_DIALOG_MAX_GAMES = 6  # longer lists are cut ("… and N more")


class InstallPage:
    def __init__(self, owner, initial_files):
        self.owner = owner
        self.window = owner.window
        self.initial_files = initial_files

    def build(self):
        self._add_file_selector()
        self._add_option_rows()
        self._wire_reset_and_run()
        return self.page

    def _add_file_selector(self):
        self.page = CommandPage(t("gui.install.page_title"), t("gui.install.page_subtitle"))

        self.file_selector = FileMultiSelect(t("gui.install.file_selector_title"))

        choose_btn = Gtk.Button(icon_name="document-open-symbolic", valign=Gtk.Align.CENTER,
                                 tooltip_text=t("gui.install.choose_tooltip"))
        choose_btn.connect("clicked", lambda *_: self.choose())
        self.file_selector.add_suffix(choose_btn)
        self.page.add_row(self.file_selector)
        if self.initial_files:
            self._scan_and_set(list(self.initial_files))
        else:
            self.file_selector.set_paths([])

    def _add_option_rows(self):
        self.ignore_hash_row = Adw.SwitchRow(title=t("gui.common.ignore_hash_title"))
        self.page.add_row(self.ignore_hash_row)

        # Install shortcut: menu on by default, file off (see add_shortcut_rows); the file
        # list may hold several .zgp, and an on-by-default file shortcut would create several
        # at once.
        self.menu_shortcut_row, self.desktop_shortcut_row, self.desktop_path_row, self.loadingscreen_row = \
            add_shortcut_rows(self.page, self.window)

    def _wire_reset_and_run(self):
        self.page.reset_selection = self.reset_fields

        self.page.run_button.connect("clicked", self.on_run)

    def _scan_and_set(self, chosen_paths: list[str]):
        # Not limited to the files chosen in the native picker: the other .zgp files in the
        # same folder are listed too, so they can be added at once with "check all"
        # without going back to the file picker.
        all_in_dir = sibling_files(chosen_paths, ".zgp")
        self.file_selector.set_paths(all_in_dir, checked_paths=chosen_paths)

    def choose(self):
        def got(paths):
            if paths:
                self._scan_and_set(paths)

        pick_file(self.window, t("gui.install.choose_dialog_title"), got, [(".zgp", ["*.zgp"])], multiple=True)

    # Going back to the category menu, changing page, or a successful run resets
    # everything: the file list AND the switches.
    def reset_fields(self):
        self.file_selector.set_paths([])
        self.ignore_hash_row.set_active(False)
        self.menu_shortcut_row.set_active(True)
        self.desktop_shortcut_row.set_active(False)
        self.desktop_path_row.reset()
        self.loadingscreen_row.set_active(True)

    def _shortcut_mode(self) -> str:
        menu_on = self.menu_shortcut_row.get_active()
        desktop_on = self.desktop_shortcut_row.get_active()
        if menu_on and desktop_on:
            return "both"
        if menu_on:
            return "menu"
        if desktop_on:
            return "desktop"
        return "none"

    def _install_args(self, selected: list[str], allow_scripts: bool) -> list[str]:
        args = ["install", "-y"]
        if allow_scripts:
            args.append("--allow-scripts")
        if self.ignore_hash_row.get_active():
            args.append("--ignore-hash")
        menu_on = self.menu_shortcut_row.get_active()
        desktop_on = self.desktop_shortcut_row.get_active()
        args.append(f"--shortcut={self._shortcut_mode()}")
        if (menu_on or desktop_on) and not self.loadingscreen_row.get_active():
            args.append("--no-loadingscreen")
        if desktop_on:
            desktop_path = self.desktop_path_row.value()
            if desktop_path:
                args.append(f"--desktop-dir={desktop_path}")
        args.extend(selected)
        return args

    def _on_cancelled(self, installed_slugs, batch_desktop_dir):
        """Cancellation: the current game is cleaned up by the script; if games from this
        batch are already finished, offer to uninstall them too (ONLY those). Default: keep
        them (deletion is irreversible)."""
        if not installed_slugs:
            return

        def delete_installed():
            uninstall_args = ["uninstall", "-y"]
            if batch_desktop_dir:
                uninstall_args.append(f"--desktop-dir={batch_desktop_dir}")
            uninstall_args.extend(installed_slugs)
            self.page.run_command(uninstall_args, t("gui.install.toast_cancel_deleted"), refresh="games")

        ask_keep_or_delete(
            self.window,
            t("gui.install.cancel_dialog_heading"),
            t("gui.install.cancel_dialog_body", len(installed_slugs),
              "\n".join(f"\u2022 {slug}" for slug in installed_slugs)),
            delete_installed,
        )

    @staticmethod
    def _parse_hooks(stdout: str) -> list[tuple[str, str, list[tuple[str, str]]]]:
        """Output of "lpm install --list-hooks": [(game name, file name, [(key, value)])]."""
        games = []
        for line in stdout.splitlines():
            kind, _, rest = line.partition("\x1f")
            fields = rest.split("\x1f")
            if kind == "GAME" and len(fields) >= 2:
                games.append((fields[0], fields[1], []))
            elif kind == "HOOK" and games and len(fields) >= 2:
                value = fields[1] if len(fields[1]) <= 70 else fields[1][:67] + "..."
                games[-1][2].append((fields[0], value))
        return games

    @staticmethod
    def _hook_line(name: str, hooks) -> str:
        """One short line: the game, then the script(s) it runs (just the path or command)."""
        scripts = ", ".join(dict.fromkeys(value for _key, value in hooks))
        return f"\u2022 {name}: {scripts}"

    def _ask_hooks(self, games, total: int, on_choice):
        """One confirmation for the whole batch, listing every package that embeds scripts.
        on_choice(None) = cancel, on_choice(False) = install without them, on_choice(True) = allow."""
        listing = "\n".join(InstallPage._hook_line(name, hooks) for name, _filename, hooks in games[:HOOKS_DIALOG_MAX_GAMES])
        if len(games) > HOOKS_DIALOG_MAX_GAMES:
            listing += "\n" + t("gui.install.hooks_dialog_more", len(games) - HOOKS_DIALOG_MAX_GAMES)
        dialog = Adw.AlertDialog(
            heading=t("gui.install.hooks_dialog_heading"),
            body=t("gui.install.hooks_dialog_body", listing))
        dialog.add_response("cancel", t("gui.common.cancel"))
        dialog.add_response("without", t("gui.install.hooks_dialog_without"))
        dialog.add_response("allow", t("gui.install.hooks_dialog_allow"))
        dialog.set_response_appearance("allow", Adw.ResponseAppearance.DESTRUCTIVE)
        dialog.set_default_response("without")
        dialog.set_close_response("cancel")
        dialog.connect("response", lambda _d, r: on_choice({"without": False, "allow": True}.get(r)))
        dialog.present(self.window)

    def _start_install(self, selected: list[str], allow_scripts: bool):
        batch_desktop_dir = self.desktop_path_row.value() if self.desktop_shortcut_row.get_active() else ""
        self.page.run_command(
            self._install_args(selected, allow_scripts), t("gui.common.install_done"), refresh="games",
            cancellable=True,
            on_cancelled=lambda slugs: self._on_cancelled(slugs, batch_desktop_dir))

    def _on_hooks_scanned(self, selected: list[str], result):
        self.page.run_button.set_sensitive(True)
        games = self._parse_hooks(result.stdout) if result.returncode == 0 else []
        if not games:
            self._start_install(selected, False)
            return

        def on_choice(allow):
            if allow is not None:
                self._start_install(selected, allow)

        self._ask_hooks(games, len(selected), on_choice)

    def on_run(self, *_):
        selected = self.file_selector.selected_paths()
        if not selected:
            self.page.toast(t("gui.install.toast_choose_file"))
            return
        # Scripts embedded in the archives are listed first (read-only), so that ONE
        # confirmation can name every package that has some, as the CLI does.
        self.page.run_button.set_sensitive(False)
        backend.run_lpm_async(
            ["install", "-y", "--list-hooks", *selected],
            on_done=lambda result: _run_on_main(self._on_hooks_scanned, selected, result))


class LifecyclePages:
    # --- Games ---
    def page_install(self, initial_files: list[str] | None = None):
        return InstallPage(self, initial_files).build()

    def _confirm_destructive(self, heading: str, body: str, confirm_label: str, on_confirm):
        """Confirmation alert before a destructive action (same style as page_killwine):
        "Cancel" by default, red confirm button."""
        dialog = Adw.AlertDialog(heading=heading, body=body)
        dialog.add_response("cancel", t("gui.common.cancel"))
        dialog.add_response("confirm", confirm_label)
        dialog.set_response_appearance("confirm", Adw.ResponseAppearance.DESTRUCTIVE)
        dialog.set_default_response("cancel")
        dialog.set_close_response("cancel")
        dialog.connect("response", lambda _d, r: on_confirm() if r == "confirm" else None)
        dialog.present(self.window)

    def page_uninstall(self):
        page = CommandPage(t("gui.uninstall.page_title"))
        selector = GameMultiSelect()
        page.add_row(selector)
        page.reset_selection = selector.refresh

        def on_run(*_):
            slugs = selector.selected_slugs()
            if not slugs:
                page.toast(t("gui.common.choose_one_game"))
                return
            self._confirm_destructive(
                t("gui.uninstall.confirm_heading", len(slugs)),
                t("gui.uninstall.confirm_body"),
                t("gui.uninstall.confirm_button"),
                lambda: page.run_command(
                    ["uninstall", "-y", *slugs], t("gui.uninstall.done"), refresh="games",
                    cancellable=True, cancel_group=False, cancel_toast="",
                    on_cancelled=lambda removed: page.toast(t("gui.uninstall.toast_cancelled", len(removed))),
                ),
            )

        page.run_button.connect("clicked", on_run)
        return page

    def page_create_prefix(self):
        return CreatePrefixPage(self).build()

    def page_exe_install(self):
        return ExeInstallPage(self).build()

    def page_pack(self):
        page = CommandPage(t("gui.pack.page_title"))
        # Same selector as install/uninstall (dropdown, "check all", counter in the title).
        selector = GameMultiSelect(t("gui.pack.games_installed_label"))
        page.add_row(selector)

        level_row, hash_row = add_compression_rows(page)

        def reset_fields():
            selector.refresh()
            level_row.set_value(3)
            hash_row.set_active(False)

        page.reset_selection = reset_fields

        on_cancelled = self._export_cancel_handler(page)

        def on_run(*_):
            selected = selector.selected_slugs()
            if not selected:
                page.toast(t("gui.pack.toast_choose_item"))
                return
            args = ["pack", f"-{int(level_row.get_value())}"]
            if hash_row.get_active():
                args.append("--hash")
            args.extend(selected)
            page.run_command(args, t("gui.pack.done"), cancellable=True, on_cancelled=on_cancelled,
                             cancel_toast=t("gui.pack.toast_cancelled"))

        page.run_button.connect("clicked", on_run)
        return page

    def page_isolate(self):
        page = CommandPage(t("gui.isolate.page_title"), t("gui.isolate.page_subtitle"))
        entries = backend.list_isolable()
        by_store: dict[str, list[backend.IsolableEntry]] = {}
        for e in entries:
            by_store.setdefault(e.store_label, []).append(e)

        store_row = Adw.ComboRow(title=t("gui.isolate.store_title"))
        store_labels = list(by_store.keys())
        store_row.set_model(Gtk.StringList.new(store_labels or [t("gui.isolate.none_detected")]))
        page.add_row(store_row)

        # The selected store is reset too, see CommandPage.reset_selection.
        page.reset_selection = lambda: store_row.set_selected(0)

        def on_run(*_):
            idx = store_row.get_selected()
            if not store_labels or idx == Gtk.INVALID_LIST_POSITION or idx >= len(store_labels):
                page.toast(t("gui.isolate.toast_no_store"))
                return
            label = store_labels[idx]
            representative_slug = by_store[label][0].slug
            page.run_command(["isolate", "-y", representative_slug], t("gui.isolate.done", label))

        page.run_button.connect("clicked", on_run)
        return page
