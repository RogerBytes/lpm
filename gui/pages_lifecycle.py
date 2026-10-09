"""Pages: install, uninstall, prefixes, packing, isolation."""


import gi

gi.require_version("Gtk", "4.0")
gi.require_version("Adw", "1")
from gi.repository import Adw, Gtk  # noqa: E402

import backend
from i18n import t
from commandpage import CommandPage
from widgets_rows import (PrefixEntryRow, add_compression_rows, add_shortcut_rows, ask_keep_or_delete,
                          pick_file, sibling_files)
from widgets_select import FileMultiSelect, GameMultiSelect, RunnerCombo


class LifecyclePages:
    # --- Games ---
    def page_install(self, initial_files: list[str] | None = None):
        page = CommandPage(t("gui.install.page_title"), t("gui.install.page_subtitle"))

        file_selector = FileMultiSelect(t("gui.install.file_selector_title"))

        def _scan_and_set(chosen_paths: list[str]):
            # Not limited to the files chosen in the native picker: the other .zgp files in the
            # same folder are listed too, so they can be added at once with "check all"
            # without going back to the file picker.
            all_in_dir = sibling_files(chosen_paths, ".zgp")
            file_selector.set_paths(all_in_dir, checked_paths=chosen_paths)

        def choose():
            def got(paths):
                if paths:
                    _scan_and_set(paths)

            pick_file(self.window, t("gui.install.choose_dialog_title"), got, [(".zgp", ["*.zgp"])], multiple=True)

        choose_btn = Gtk.Button(icon_name="document-open-symbolic", valign=Gtk.Align.CENTER,
                                 tooltip_text=t("gui.install.choose_tooltip"))
        choose_btn.connect("clicked", lambda *_: choose())
        file_selector.add_suffix(choose_btn)
        page.add_row(file_selector)
        if initial_files:
            _scan_and_set(list(initial_files))
        else:
            file_selector.set_paths([])

        allow_scripts_row = Adw.SwitchRow(title=t("gui.install.allow_scripts_title"),
                                           subtitle=t("gui.install.allow_scripts_subtitle"))
        page.add_row(allow_scripts_row)

        ignore_hash_row = Adw.SwitchRow(title=t("gui.common.ignore_hash_title"))
        page.add_row(ignore_hash_row)

        # Install shortcut: menu on by default, file off (see add_shortcut_rows); the file
        # list may hold several .zgp, and an on-by-default file shortcut would create several
        # at once.
        menu_shortcut_row, desktop_shortcut_row, desktop_path_row, loadingscreen_row = \
            add_shortcut_rows(page, self.window)

        # Going back to the category menu, changing page, or a successful run resets
        # everything: the file list AND the switches.
        def reset_fields():
            file_selector.set_paths([])
            allow_scripts_row.set_active(False)
            ignore_hash_row.set_active(False)
            menu_shortcut_row.set_active(True)
            desktop_shortcut_row.set_active(False)
            desktop_path_row.reset()
            loadingscreen_row.set_active(True)

        page.reset_selection = reset_fields

        def on_run(*_):
            selected = file_selector.selected_paths()
            if not selected:
                page.toast(t("gui.install.toast_choose_file"))
                return
            args = ["install", "-y"]
            if allow_scripts_row.get_active():
                args.append("--allow-scripts")
            if ignore_hash_row.get_active():
                args.append("--ignore-hash")
            menu_on = menu_shortcut_row.get_active()
            desktop_on = desktop_shortcut_row.get_active()
            if menu_on and desktop_on:
                shortcut_mode = "both"
            elif menu_on:
                shortcut_mode = "menu"
            elif desktop_on:
                shortcut_mode = "desktop"
            else:
                shortcut_mode = "none"
            args.append(f"--shortcut={shortcut_mode}")
            if (menu_on or desktop_on) and not loadingscreen_row.get_active():
                args.append("--no-loadingscreen")
            if desktop_on:
                desktop_path = desktop_path_row.value()
                if desktop_path:
                    args.append(f"--desktop-dir={desktop_path}")
            args.extend(selected)
            batch_desktop_dir = desktop_path_row.value() if desktop_on else ""

            # Cancellation: the current game is cleaned up by the script; if games from this
            # batch are already finished, offer to uninstall them too (ONLY those, never other
            # existing games). Default: keep them (avoids a misclick, deletion is irreversible).
            def on_cancelled(installed_slugs):
                if not installed_slugs:
                    return
                def delete_installed():
                    uninstall_args = ["uninstall", "-y"]
                    if batch_desktop_dir:
                        uninstall_args.append(f"--desktop-dir={batch_desktop_dir}")
                    uninstall_args.extend(installed_slugs)
                    page.run_command(uninstall_args, t("gui.install.toast_cancel_deleted"), refresh="games")

                ask_keep_or_delete(
                    self.window,
                    t("gui.install.cancel_dialog_heading"),
                    t("gui.install.cancel_dialog_body", len(installed_slugs),
                      "\n".join(f"• {slug}" for slug in installed_slugs)),
                    delete_installed,
                )

            page.run_command(args, t("gui.common.install_done"), refresh="games",
                             cancellable=True, on_cancelled=on_cancelled)

        page.run_button.connect("clicked", on_run)
        return page

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
        page = CommandPage(t("gui.create_prefix.page_title"))

        # Repeatable list of PrefixEntryRow (name + slug, see that class): one row at the
        # start, "+" on a row adds one right after it (Gtk.Box.insert_child_after), the trash
        # button removes it (never the last remaining one, see update_remove_sensitivity).
        # Each row is already a separate entry, with a live slug preview like Lutris.
        rows_box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=2)
        page.add_row(rows_box)

        def iter_rows():
            child = rows_box.get_first_child()
            while child is not None:
                yield child
                child = child.get_next_sibling()

        def update_remove_sensitivity():
            rows = list(iter_rows())
            only_one = len(rows) <= 1
            for row in rows:
                row.remove_btn.set_sensitive(not only_one)

        def add_row(after_row=None):
            new_row = PrefixEntryRow(on_add=add_row, on_remove=remove_row)
            if after_row is None:
                rows_box.append(new_row)
            else:
                rows_box.insert_child_after(new_row, after_row)
            update_remove_sensitivity()

        def remove_row(row):
            if len(list(iter_rows())) <= 1:
                return
            rows_box.remove(row)
            update_remove_sensitivity()

        def reset_rows():
            rows = list(iter_rows())
            for extra in rows[1:]:
                rows_box.remove(extra)
            if rows:
                rows[0].reset()
            update_remove_sensitivity()

        add_row()

        runner_row = RunnerCombo()
        page.add_row(runner_row)
        arch_row = Adw.ComboRow(title=t("gui.common.arch_title"))
        arch_row.set_model(Gtk.StringList.new(["win64", "win32"]))
        page.add_row(arch_row)

        # Runner and architecture are reset too, see CommandPage.reset_selection.
        def reset_fields():
            reset_rows()
            runner_row.refresh()
            arch_row.set_selected(0)

        page.reset_selection = reset_fields

        def on_run(*_):
            targets = [spec for row in iter_rows() if (spec := row.target_spec())]
            if not targets:
                page.toast(t("gui.create_prefix.toast_need_name"))
                return
            runner = runner_row.selected_runner()
            arch_idx = arch_row.get_selected()
            arch = "win64" if arch_idx in (0, Gtk.INVALID_LIST_POSITION) else "win32"
            args = ["create-prefix", "-y"]
            if runner:
                args.extend(["-r", runner])
            args.extend(["-a", arch, *targets])
            page.run_command(args, t("gui.create_prefix.done"), refresh="games")

        page.run_button.connect("clicked", on_run)
        return page

    def page_exe_install(self):
        page = CommandPage(t("gui.exe_install.page_title"))
        self._exe_path = ""
        path_row = Adw.ActionRow(title=t("gui.exe_install.exe_title"), subtitle=t("gui.common.no_file_selected"))

        def choose():
            def got(paths):
                if paths:
                    self._exe_path = paths[0]
                    path_row.set_subtitle(self._exe_path)

            # zgp-exe-installer.sh natively handles .exe/.msi/.bat/.cmd (it just runs
            # "wine <file>", which dispatches to msiexec/cmd.exe by extension -- see the
            # header comment of that script); only this dialog's filter restricted the choice
            # to .exe.
            pick_file(self.window, t("gui.exe_install.choose_dialog_title"), got,
                      [(t("gui.exe_install.filter_label"), ["*.exe", "*.msi", "*.bat", "*.cmd"])])

        choose_btn = Gtk.Button(icon_name="document-open-symbolic", valign=Gtk.Align.CENTER)
        choose_btn.connect("clicked", lambda *_: choose())
        path_row.add_suffix(choose_btn)
        page.add_row(path_row)

        name_row = Adw.EntryRow(title=t("gui.exe_install.name_title"))
        page.add_row(name_row)
        slug_row = Adw.EntryRow(title=t("gui.exe_install.slug_title"))
        page.add_row(slug_row)

        # Live slug preview from the name, same behavior as "create an empty prefix" (see
        # PrefixEntryRow): filled automatically until the user edits the slug field, after
        # which tracking is PERMANENTLY detached.
        slug_follows_name = True
        updating_slug = False

        def _on_name_changed(*_):
            nonlocal updating_slug
            if not slug_follows_name:
                return
            name = name_row.get_text()
            updating_slug = True
            slug_row.set_text(backend.slugify_preview(name) if name.strip() else "")
            updating_slug = False

        def _on_slug_changed(*_):
            nonlocal slug_follows_name
            if updating_slug:
                return
            slug_follows_name = False

        name_row.connect("changed", _on_name_changed)
        slug_row.connect("changed", _on_slug_changed)

        runner_row = RunnerCombo()
        page.add_row(runner_row)
        arch_row = Adw.ComboRow(title=t("gui.common.arch_title"))
        arch_row.set_model(Gtk.StringList.new(["win64", "win32"]))
        page.add_row(arch_row)
        final_exe_row = Adw.EntryRow(title=t("gui.exe_install.final_exe_title"))
        page.add_row(final_exe_row)

        # Reset after a successful run and when leaving the page (see
        # CommandPage.reset_selection).
        def reset_fields():
            nonlocal slug_follows_name, updating_slug
            self._exe_path = ""
            path_row.set_subtitle(t("gui.common.no_file_selected"))
            updating_slug = True
            name_row.set_text("")
            slug_row.set_text("")
            updating_slug = False
            slug_follows_name = True
            runner_row.refresh()
            arch_row.set_selected(0)
            final_exe_row.set_text("")

        page.reset_selection = reset_fields

        def on_run(*_):
            name = name_row.get_text().strip()
            if not self._exe_path or not name:
                page.toast(t("gui.exe_install.toast_need_exe_and_name"))
                return
            target = f"{self._exe_path}|{name}"
            # Explicit slug passed only if edited by hand AND different from the automatic
            # preview -- same principle as PrefixEntryRow.target_spec(): otherwise let the
            # backend (zgp_slugify, identical to backend.slugify_preview) derive it from the name.
            if not slug_follows_name:
                slug = slug_row.get_text().strip()
                if slug and slug != backend.slugify_preview(name):
                    target += f"|{slug}"
            runner = runner_row.selected_runner()
            arch = "win64" if arch_row.get_selected() in (0, Gtk.INVALID_LIST_POSITION) else "win32"
            args = ["exe-install", "-y", target]
            if runner:
                args.extend(["-r", runner])
            args.extend(["-a", arch])
            if final_exe_row.get_text().strip():
                args.extend(["-f", final_exe_row.get_text().strip()])
            page.run_command(args, t("gui.common.install_done"), refresh="games")

        page.run_button.connect("clicked", on_run)
        return page

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
