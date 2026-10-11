"""Pages: shortcuts, images, tools, launchers, lsfg."""

import json
import os
import re
import tempfile
from typing import Callable

import gi

gi.require_version("Gtk", "4.0")
gi.require_version("Adw", "1")
from gi.repository import Adw, GLib, Gtk  # noqa: E402

import backend
from i18n import t
from commandpage import CommandPage
from sgdb import SgdbPickerWindow, SgdbTitleResolverWindow
from util import _run_on_main, json_result
from widgets_rows import LauncherEntryRow, _wrapping_text_factory, add_shortcut_rows, pick_file, pick_folder
from widgets_select import GameMultiSelect, RunnerCombo, SingleChoiceSelect, SingleGameSelect


class MediaPages:
    def page_shortcut(self):
        page = CommandPage(t("gui.shortcut.page_title"))
        selector = GameMultiSelect()
        page.add_row(selector)

        # Same shortcut settings as the install page (see add_shortcut_rows): "no shortcut"
        # is a consistent state, the loading screen is then hidden.
        menu_shortcut_row, desktop_shortcut_row, desktop_path_row, loadingscreen_row = \
            add_shortcut_rows(page, self.window)

        # Lutris launch hooks (prelaunch_command/prelaunch_wait/postexit_command): act
        # directly on the game's config YAML, so fully independent of shortcut creation (the
        # hook applies however the game is launched) -- always visible. Unchecked by default,
        # for safety. Never deletes/overwrites the command itself, see zgu_apply_hook_policy
        # in zgu-desktop-utils.sh: neutralized (commented out) if unchecked, restored
        # (uncommented) if checked.
        allow_hooks_row = Adw.SwitchRow(title=t("gui.shortcut.allow_hooks_title"),
                                         subtitle=t("gui.shortcut.allow_hooks_subtitle"),
                                         active=False)
        page.add_row(allow_hooks_row)

        # Going back to the category menu, changing page, or a successful run resets
        # everything, see CommandPage.reset_selection.
        def reset_fields():
            selector.refresh()
            menu_shortcut_row.set_active(True)
            desktop_shortcut_row.set_active(False)
            loadingscreen_row.set_active(True)
            allow_hooks_row.set_active(False)
            desktop_path_row.reset()

        page.reset_selection = reset_fields

        def on_run(*_):
            slugs = selector.selected_slugs()
            if not slugs:
                page.toast(t("gui.shortcut.toast_choose_game"))
                return
            menu_on = menu_shortcut_row.get_active()
            desktop_on = desktop_shortcut_row.get_active()
            if menu_on and desktop_on:
                mode = "both"
            elif menu_on:
                mode = "menu"
            elif desktop_on:
                mode = "desktop"
            else:
                mode = "none"
            args = ["shortcut", f"--shortcut={mode}"]
            if (menu_on or desktop_on) and not loadingscreen_row.get_active():
                args.append("--no-loadingscreen")
            if allow_hooks_row.get_active():
                args.append("--allow-hooks")
            if desktop_on:
                desktop_path = desktop_path_row.value()
                if desktop_path:
                    args.append(f"--desktop-dir={desktop_path}")
            args.extend(slugs)
            page.run_command(args, t("gui.shortcut.done"))

        page.run_button.connect("clicked", on_run)
        return page

    def page_images(self):
        """Merges the former separate "Icon"/"Splash"/"Logo" pages (three PER-GAME settings
        like the other pages of the "Games" category, not a category of their own): one
        multi-game selector + three switches (checked by default: fetch everything) to choose
        which image types to fetch via SteamGridDB. "Run" chains one CLI call per checked type
        (never in parallel, see run_step) and reports a single aggregated result at the end.
        It continues with the remaining types even if one fails, since a missing type (e.g.
        a logo not found on SteamGridDB for a given game) should not prevent fetching the
        others."""
        page = CommandPage(t("gui.images.page_title"), t("gui.images.subtitle"))

        # SteamGridDB API key -- entered directly ON this page (never a separate window),
        # masked (asterisks) but still editable (Adw.PasswordEntryRow), persistent once filled
        # (see lib/zgl-sgdb-key.sh, same storage file as "lpm icon"/"splash"/"logo").
        # "show_apply_button" shows an explicit validation checkmark (in addition to Enter):
        # the key is (re)tested with a REAL API call and saved ONLY on this "apply" signal,
        # never on each keystroke.
        sgdb_key_row = Adw.PasswordEntryRow(title=t("gui.images.sgdb_key_title"), show_apply_button=True)
        page.add_row(sgdb_key_row)

        # Warning + direct link to the SteamGridDB key page.
        # Two triggers, and NEVER an API call outside them: verification must only happen
        # when a key is EDITED/ADDED, never on each page opening or reset.
        #   - no saved key (empty) -- known without any API call, simple read via
        #     "lpm sgdb-key get" (see refresh_sgdb_key_row);
        #   - an entry attempt was just rejected by "lpm sgdb-key set" (see
        #     on_sgdb_key_apply) -- that call tests the key against the API anyway in order
        #     to save it, so it is never an EXTRA check.
        # Hidden as soon as a saved key exists (whether it is still valid is no longer
        # rechecked until it is modified).
        sgdb_key_notice_row = Adw.ActionRow(title=t("gui.images.sgdb_key_invalid_notice"), visible=False)
        sgdb_key_link_btn = Gtk.LinkButton(
            uri="https://www.steamgriddb.com/profile/preferences/api",
            label=t("gui.images.sgdb_key_link_label"),
            valign=Gtk.Align.CENTER,
        )
        sgdb_key_notice_row.add_suffix(sgdb_key_link_btn)
        page.add_row(sgdb_key_notice_row)

        def refresh_sgdb_key_row(on_synced: Callable[[], None] | None = None):
            """Resync only the FIELD (simple read, "lpm sgdb-key get", never an API call) --
            NEVER touches "sgdb_key_notice_row" itself: its state is decided by the only two
            legitimate callers below (empty key found at opening, or failure of a "set" in
            on_sgdb_key_apply), never rebuilt from the key's presence/absence on each call --
            that would erase the warning shown after a failure as soon as the old (non-empty)
            key still in place is read back."""
            def on_done(result: backend.CommandResult):
                data = json_result(result)
                key = str(data.get("key") or "")

                def apply():
                    sgdb_key_row.set_text(key)
                    if on_synced is not None:
                        on_synced()

                _run_on_main(apply)

            backend.run_lpm_async(["sgdb-key", "get"], on_done=on_done)

        def on_sgdb_key_apply(*_):
            candidate = sgdb_key_row.get_text().strip()

            def on_done(result: backend.CommandResult):
                def apply():
                    if result.returncode != 0:
                        page.toast(t("gui.images.sgdb_key_set_failed"))
                        sgdb_key_notice_row.set_visible(True)
                        refresh_sgdb_key_row()  # back to the field with the key still in place
                    else:
                        sgdb_key_notice_row.set_visible(False)
                        refresh_sgdb_key_row()  # confirm the field with the accepted key

                _run_on_main(apply)

            backend.run_lpm_async(["sgdb-key", "set", candidate], on_done=on_done)

        sgdb_key_row.connect("apply", on_sgdb_key_apply)
        # On page opening (and on each reset): "sgdb_key_notice_row" reflects ONLY the
        # absence of a key (empty), found without any API call -- never a revalidation of
        # the saved key (see the comment above "sgdb_key_notice_row").
        refresh_sgdb_key_row(lambda: sgdb_key_notice_row.set_visible(not sgdb_key_row.get_text()))

        selector = GameMultiSelect()
        page.add_row(selector)

        icon_row = Adw.SwitchRow(title=t("gui.images.toggle_icon"), active=True)
        page.add_row(icon_row)
        splash_row = Adw.SwitchRow(title=t("gui.images.toggle_splash"), active=True)
        page.add_row(splash_row)
        logo_row = Adw.SwitchRow(title=t("gui.images.toggle_logo"), active=True)
        page.add_row(logo_row)

        # "Automatic download" checkbox -- UNCHECKED by default. Checked: the first
        # SteamGridDB result is taken without a window ("lpm icon"/"splash"/"logo" directly --
        # run_step below). Unchecked (default): opens SgdbPickerWindow, which goes game by
        # game then type by type and lets the user choose the image in a thumbnail grid (see
        # lib/zgl-sgdb-images.sh for candidate retrieval).
        auto_download_row = Adw.SwitchRow(title=t("gui.images.auto_download_toggle"), active=False)
        page.add_row(auto_download_row)

        def reset_fields():
            selector.refresh()
            icon_row.set_active(True)
            splash_row.set_active(True)
            logo_row.set_active(True)
            auto_download_row.set_active(False)
            refresh_sgdb_key_row(lambda: sgdb_key_notice_row.set_visible(not sgdb_key_row.get_text()))

        page.reset_selection = reset_fields

        def on_run(*_):
            entries = selector.selected_entries()
            if not entries:
                page.toast(t("gui.common.choose_one_game"))
                return

            types = []
            if icon_row.get_active():
                types.append(("icon", t("gui.images.toggle_icon")))
            if splash_row.get_active():
                types.append(("splash", t("gui.images.toggle_splash")))
            if logo_row.get_active():
                types.append(("logo", t("gui.images.toggle_logo")))
            if not types:
                page.toast(t("gui.images.toast_choose_type"))
                return

            self._run_images(page, entries, types, auto_download_row.get_active(), reset_fields)

        page.run_button.connect("clicked", on_run)
        return page

    def _run_images(self, page, entries, types, auto_pick, reset_fields):
        """Phase A (title resolution -- SgdbTitleResolverWindow) then Phase B (image
        choice/download -- SgdbPickerWindow), in that order, for BOTH page_images modes
        ("Automatic download" checked or not). Title disambiguation, when needed, must always
        happen first for all selected games, before any image choice or download, whether
        that is then automatic ("auto_pick=True" -- first image taken directly) or manual
        (thumbnail grid)."""
        page.run_button.set_sensitive(False)

        def on_titles_resolved(resolved: dict[str, tuple[str, str]], cancelled: bool):
            if cancelled:
                # Nothing was downloaded yet (Phase B never started) -- not one failure per
                # game/type, a single generic marker, same principle as cancellation in Phase B
                # (see SgdbPickerWindow._on_close_request).
                page.run_button.set_sensitive(True)
                page.toast(t("gui.images.toast_failed", t("gui.sgdb_picker.cancelled_marker")))
                reset_fields()
                return

            failed_labels = []
            image_queue = []
            for slug, name in entries:
                identity = resolved.get(slug)
                if identity is None:
                    for _command, label in types:
                        failed_labels.append(f"{name} — {label}")
                    continue
                game_id, game_name = identity
                for command, label in types:
                    image_queue.append({
                        "type": command, "type_label": label, "slug": slug, "name": name,
                        "game_id": game_id, "game_name": game_name,
                    })

            if not image_queue:
                page.run_button.set_sensitive(True)
                if failed_labels:
                    page.toast(t("gui.images.toast_failed", ", ".join(failed_labels)))
                else:
                    page.toast(t("gui.common.done"))
                reset_fields()
                return

            def on_finished(image_failed_labels: list[str]):
                page.run_button.set_sensitive(True)
                all_failed = failed_labels + image_failed_labels
                if not all_failed:
                    page.toast(t("gui.common.done"))
                else:
                    page.toast(t("gui.images.toast_failed", ", ".join(all_failed)))
                reset_fields()

            picker = SgdbPickerWindow(self.window, image_queue, auto_pick=auto_pick)
            picker.start(on_finished)

        resolver = SgdbTitleResolverWindow(self.window, entries)
        resolver.start(on_titles_resolved)

    def page_tools(self):
        page = CommandPage(t("gui.tools.page_title"))
        game_row = SingleGameSelect()
        page.add_row(game_row)

        # tool_ids: technical values passed as is as a CLI argument ("tools <slug>
        # <tool_id>", see lib/zgp-game-tools.sh) -- never translated. tool_labels: text shown
        # in the dropdown, in the same order -- the two lists are decoupled (as for
        # "flatpak"/"native"/"reset" in page_lutris_version), so translating the display never
        # touches the arguments sent to bin/lpm.
        tools = ["winetricks", "regedit", "winecfg", "console", "exe", "folder", "favorite", "env", "runner", "mangohud", "gamepad"]
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
        tool_row = SingleChoiceSelect(t("gui.tools.tool_title"), tool_labels)
        page.add_row(tool_row)

        # Executable path -- visible only for the "exe" tool (winetricks/registry
        # editor/Wine configuration/console/folder need no path). No default value is
        # possible (no "default" executable makes sense): just a button to pick one.
        self._tools_exe_path = ""
        exe_path_row = Adw.ActionRow(title=t("gui.tools.exe_path_title"),
                                      subtitle=t("gui.common.no_file_selected"))

        def choose_exe():
            def got(paths):
                if paths:
                    self._tools_exe_path = paths[0]
                    exe_path_row.set_subtitle(self._tools_exe_path)

            # Filter imposed on the native picker (not just indicative): a file of another
            # type must not be selectable. Same extensions as "install an .exe"
            # (gui.exe_install.filter_label) for consistency.
            pick_file(self.window, t("gui.common.choose_executable_title"), got,
                      [(t("gui.exe_install.filter_label"), ["*.exe", "*.msi", "*.bat", "*.cmd"])])

        exe_choose_btn = Gtk.Button(icon_name="document-open-symbolic", valign=Gtk.Align.CENTER)
        exe_choose_btn.connect("clicked", lambda *_: choose_exe())
        exe_path_row.add_suffix(exe_choose_btn)
        page.add_row(exe_path_row)

        # Favorite folder -- visible only for the "favorite" tool. Same principle as
        # DesktopPathRow (install page / "Launch settings"): pre-filled (here with the home
        # folder) and editable directly or via "Browse", rather than an empty field.
        favorite_path_row = Adw.EntryRow(title=t("gui.tools.favorite_path_title"))

        def _reset_favorite_path():
            favorite_path_row.set_text(GLib.get_home_dir())

        _reset_favorite_path()

        def _browse_favorite(*_):
            def got(path):
                if path:
                    favorite_path_row.set_text(path)

            pick_folder(self.window, t("gui.tools.choose_folder_dialog_title"), got)

        favorite_browse_btn = Gtk.Button(icon_name="folder-open-symbolic", valign=Gtk.Align.CENTER)
        favorite_browse_btn.connect("clicked", _browse_favorite)
        favorite_path_row.add_suffix(favorite_browse_btn)
        page.add_row(favorite_path_row)

        # New runner for the game -- visible only for the "runner" tool. No runner is applied
        # until the user picks one (see explicit_runner).
        runner_row = RunnerCombo(title=t("gui.tools.runner_title"), placeholder=t("gui.tools.runner_placeholder"))
        page.add_row(runner_row)

        # MangoHud switch -- visible only for the "mangohud" tool. One game at a time: the
        # position is read from the chosen game's Lutris config ("tools <slug> mangohud status"),
        # never carried over from another game; "Run" applies it ("mangohud on" / "mangohud off").
        mangohud_row = Adw.SwitchRow(title=t("gui.tools.mangohud_switch_title"))
        mangohud_row.set_sensitive(False)
        page.add_row(mangohud_row)
        mangohud_state = {"slug": None, "token": 0}

        def _load_mangohud():
            slug = game_row.selected_slug()
            mangohud_state["token"] += 1
            token = mangohud_state["token"]
            mangohud_state["slug"] = None
            mangohud_row.set_sensitive(False)
            mangohud_row.set_active(False)
            if not slug or tool_row.get_selected() != tools.index("mangohud"):
                return

            def done(result):
                def apply():
                    # Stale response (another game / tool chosen in the meantime): ignored.
                    if token != mangohud_state["token"]:
                        return
                    if result.returncode != 0:
                        page.toast(t("gui.common.command_failed", result.returncode))
                        return
                    mangohud_row.set_active(result.stdout.strip() == "on")
                    mangohud_state["slug"] = slug
                    mangohud_row.set_sensitive(True)

                _run_on_main(apply)

            backend.run_lpm_async(["tools", slug, "mangohud", "status"], on_done=done)

        # Gamepad profile (AntiMicroX) -- visible only for the "gamepad" tool. Same pattern as
        # MangoHud: the position ("on", "off" or "other" = a profile of the user's own) is read
        # per game ("tools <slug> gamepad status"); "Run" applies it. A separate row opens the
        # profile in AntiMicroX ("tools <slug> gamepad edit"), nothing is watched.
        gamepad_row = Adw.SwitchRow(title=t("gui.tools.gamepad_switch_title"))
        gamepad_row.set_sensitive(False)
        page.add_row(gamepad_row)
        gamepad_edit_row = Adw.ActionRow(title=t("gui.tools.gamepad_edit_title"))
        gamepad_edit_button = Gtk.Button(label=t("gui.tools.gamepad_edit_button"), valign=Gtk.Align.CENTER)
        gamepad_edit_row.add_suffix(gamepad_edit_button)
        page.add_row(gamepad_edit_row)
        gamepad_state = {"slug": None, "token": 0, "updating": False}

        def _load_gamepad():
            slug = game_row.selected_slug()
            gamepad_state["token"] += 1
            token = gamepad_state["token"]
            gamepad_state["slug"] = None
            gamepad_row.set_sensitive(False)
            gamepad_state["updating"] = True
            gamepad_row.set_active(False)
            gamepad_state["updating"] = False
            gamepad_edit_button.set_sensitive(False)
            if not slug or tool_row.get_selected() != tools.index("gamepad"):
                return

            def done(result):
                def apply():
                    # Stale response (another game / tool chosen in the meantime): ignored.
                    if token != gamepad_state["token"]:
                        return
                    if result.returncode != 0:
                        page.toast(t("gui.common.command_failed", result.returncode))
                        return
                    state = result.stdout.strip()
                    if state == "other":
                        page.toast(t("gui.tools.gamepad_other"))
                        return
                    gamepad_state["updating"] = True
                    gamepad_row.set_active(state == "on")
                    gamepad_state["updating"] = False
                    gamepad_state["slug"] = slug
                    gamepad_row.set_sensitive(True)
                    gamepad_edit_button.set_sensitive(state == "on")

                _run_on_main(apply)

            backend.run_lpm_async(["tools", slug, "gamepad", "status"], on_done=done)

        def _on_gamepad_edit(_btn):
            slug = gamepad_state["slug"]
            if not slug:
                return

            def done(result):
                def apply():
                    if result.returncode != 0:
                        page.toast(t("gui.common.command_failed", result.returncode))
                    else:
                        page.toast(t("gui.tools.gamepad_edit_started"))

                _run_on_main(apply)

            backend.run_lpm_async(["tools", slug, "gamepad", "edit"], on_done=done)

        gamepad_edit_button.connect("clicked", _on_gamepad_edit)

        # No "Run" button for this tool: ticking / unticking the switch applies at once
        # ("tools <slug> gamepad on|off"); on failure the switch goes back to its old position.
        def _on_gamepad_toggled(row, _pspec):
            slug = gamepad_state["slug"]
            if gamepad_state["updating"] or not slug:
                return
            want = row.get_active()
            token = gamepad_state["token"]
            row.set_sensitive(False)

            def done(result):
                def apply():
                    if token != gamepad_state["token"]:
                        return  # another game / tool chosen in the meantime
                    if result.returncode != 0:
                        page.toast(t("gui.common.command_failed", result.returncode))
                        gamepad_state["updating"] = True
                        row.set_active(not want)
                        gamepad_state["updating"] = False
                    else:
                        page.toast(t("gui.tools.gamepad_done"))
                        gamepad_edit_button.set_sensitive(want)
                    row.set_sensitive(True)

                _run_on_main(apply)

            backend.run_lpm_async(["tools", slug, "gamepad", "on" if want else "off"], on_done=done)

        gamepad_row.connect("notify::active", _on_gamepad_toggled)

        # Environment variables editor -- visible only for the "env" tool. One game at a
        # time: the content is re-read from the chosen game's Lutris config ("tools <slug> env
        # list"), never mixed between games.
        env_box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=8)
        env_title = Gtk.Label(label=t("gui.tools.env_warning_title"), xalign=0, wrap=True)
        env_title.add_css_class("heading")
        env_warning = Gtk.Label(label=t("gui.tools.env_warning"), xalign=0, wrap=True)
        env_warning.add_css_class("dim-label")
        env_view = Gtk.TextView(monospace=True, wrap_mode=Gtk.WrapMode.NONE,
                                top_margin=6, bottom_margin=6, left_margin=8, right_margin=8)
        env_scroll = Gtk.ScrolledWindow(min_content_height=160, hexpand=True)
        env_scroll.set_child(env_view)
        env_frame = Gtk.Frame()
        env_frame.set_child(env_scroll)
        env_box.append(env_title)
        env_box.append(env_warning)
        env_box.append(env_frame)
        page.add_row(env_box)
        env_state = {"slug": None, "token": 0}
        env_buffer = env_view.get_buffer()

        def _load_env():
            slug = game_row.selected_slug()
            env_state["token"] += 1
            token = env_state["token"]
            env_state["slug"] = None
            env_buffer.set_text("")
            env_view.set_sensitive(False)
            if not slug or tool_row.get_selected() != tools.index("env"):
                return

            def done(result):
                def apply():
                    # Stale response (another game / tool chosen in the meantime): ignored.
                    if token != env_state["token"]:
                        return
                    if result.returncode != 0:
                        page.toast(t("gui.tools.env_toast_load_failed"))
                        return
                    env_buffer.set_text(result.stdout)
                    env_state["slug"] = slug
                    env_view.set_sensitive(True)

                _run_on_main(apply)

            backend.run_lpm_async(["tools", slug, "env", "list"], on_done=done)

        def _update_path_rows_visibility(*_):
            idx = tool_row.get_selected()
            exe_path_row.set_visible(idx == 4)
            favorite_path_row.set_visible(idx == 6)
            env_box.set_visible(idx == tools.index("env"))
            runner_row.set_visible(idx == tools.index("runner"))
            mangohud_row.set_visible(idx == tools.index("mangohud"))
            gamepad_row.set_visible(idx == tools.index("gamepad"))
            gamepad_edit_row.set_visible(idx == tools.index("gamepad"))
            page.run_button.set_visible(idx != tools.index("gamepad"))
            _load_env()
            _load_mangohud()
            _load_gamepad()

        tool_row.connect("notify::selected", _update_path_rows_visibility)
        game_row.connect_changed(_update_path_rows_visibility)
        _update_path_rows_visibility()

        # Reset after a successful run and when leaving the page, like "install an .exe"
        # (see CommandPage.reset_selection).
        def reset_fields():
            # clear_selection() BEFORE refresh() -- same as page_launcher, see
            # SingleGameSelect.clear_selection (this selector is shared between both pages).
            game_row.clear_selection()
            game_row.refresh()
            tool_row.set_selected(0)
            runner_row.refresh()
            self._tools_exe_path = ""
            exe_path_row.set_subtitle(t("gui.common.no_file_selected"))
            _reset_favorite_path()
            _update_path_rows_visibility()
            env_buffer.set_text("")

        page.reset_selection = reset_fields

        # Accepted extensions for the "exe" tool (same as the native picker filter above, see
        # choose_exe()). Checked again here: a Gtk.FileDialog filter is only indicative and
        # usually also offers "All files", so it guarantees nothing on its own; the tool must
        # never run with anything other than a real .exe, .msi, .bat or .cmd.
        _EXE_TOOL_EXTENSIONS = (".exe", ".msi", ".bat", ".cmd")

        def on_run(*_):
            slug = game_row.selected_slug()
            if not slug:
                page.toast(t("gui.tools.toast_choose_game"))
                return
            idx = tool_row.get_selected()
            tool = tools[idx] if idx != Gtk.INVALID_LIST_POSITION else tools[0]
            args = ["tools", slug, tool]
            if tool == "exe":
                if not self._tools_exe_path or not self._tools_exe_path.lower().endswith(_EXE_TOOL_EXTENSIONS):
                    page.toast(t("gui.tools.toast_invalid_exe"))
                    return
                args.append(self._tools_exe_path)
            elif tool == "favorite":
                favorite_path = favorite_path_row.get_text().strip()
                if favorite_path:
                    args.append(favorite_path)
            elif tool == "runner":
                new_runner = runner_row.explicit_runner()
                if not new_runner:
                    page.toast(t("gui.tools.toast_choose_runner"))
                    return
                args.append(new_runner)
                page.run_command(args, t("gui.tools.runner_done"))
                return
            elif tool == "mangohud":
                # Not read yet (or read failed): never write a state that was not loaded.
                if mangohud_state["slug"] != slug:
                    page.toast(t("gui.common.command_failed", "?"))
                    return
                args.append("on" if mangohud_row.get_active() else "off")
                page.run_command(args, t("gui.tools.mangohud_done"))
                return
            elif tool == "env":
                # Not read yet (or read failed): never overwrite the config with an empty
                # field that was not loaded.
                if env_state["slug"] != slug:
                    page.toast(t("gui.tools.env_toast_load_failed"))
                    return
                start, end = env_buffer.get_bounds()
                env_lines = [ln.rstrip("\r") for ln in env_buffer.get_text(start, end, False).split("\n") if ln.strip()]
                for ln in env_lines:
                    name = ln.split("=", 1)[0].strip()
                    if "=" not in ln or not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", name):
                        page.toast(t("gui.tools.env_toast_invalid", ln))
                        return
                fd, env_tmp = tempfile.mkstemp(prefix="lpm-env-", suffix=".txt")
                with os.fdopen(fd, "w", encoding="utf-8") as fh:
                    fh.write("\n".join(env_lines) + ("\n" if env_lines else ""))
                args += ["apply", env_tmp]
                GLib.timeout_add_seconds(120, lambda: (os.path.exists(env_tmp) and os.unlink(env_tmp)) and False)
                page.run_command(args, t("gui.tools.env_done"))
                return
            page.run_command(args, t("gui.tools.done"))

        page.run_button.connect("clicked", on_run)
        return page

    def page_launcher(self):
        """"LPM Launcher": one game at a time (unlike most other "enable/disable" pages, see
        page_lsfg), since the picker entries (label, executable, working directory,
        arguments) are edited here too and only make sense for one specific game.

        NO "Enable/Disable" choice on this page: the active/inactive state is an automatic
        CONSEQUENCE of the form content, never a separate choice. Empty form -> "lpm launcher
        <slug> off" (disabled, nothing relevant in the YAML); at least one filled entry
        (label + executable) -> "lpm launcher-entries <slug> set" (writes the entries) THEN
        "lpm launcher <slug> on" (enables). In both cases the "on"/"off" call goes through
        "--if-needed" (see lib/zgl-launcher-manager.sh): a game already in the requested
        state must NEVER make "Run" fail (a forced "on" on each click used to refuse to
        re-enable an already active launcher, AFTER the entries were saved successfully)."""
        page = CommandPage(t("gui.launcher.page_title"))

        # Set (mutable, updated in place) of slugs that already have LPM Launcher active
        # (bolded in the game list), read via "lpm launcher status" (see
        # lib/zgl-launcher-manager.sh, point 7) and reapplied by game_row.repaint_titles() --
        # never hard-coded in the game list itself: display (bold) and data (game list) are
        # two separate refreshes, neither waits for the other.
        active_slugs: set = set()
        game_row = SingleGameSelect(highlighted_slugs=active_slugs)
        page.add_row(game_row)

        def _apply_active_status(result: backend.CommandResult):
            if result.returncode != 0:
                return
            active_slugs.clear()
            active_slugs.update(line.strip() for line in result.stdout.splitlines() if line.strip())
            game_row.repaint_titles()

        def refresh_active_status():
            backend.run_lpm_async(["launcher", "status"], on_done=lambda result: _run_on_main(_apply_active_status, result))

        refresh_active_status()

        # State tied to the currently selected game -- filled by _on_game_selected (after
        # "launcher-entries <slug> get"), read by the rows' native file pickers (get_drive_c)
        # and sent back as is to "set" (title/prompt are not edited here, see the docstring
        # above: this form only touches the entries) -- never frozen at row construction
        # since the chosen game may change afterwards. "generation": incremented on EACH
        # selection change -- a "get" response that returns after a more recent selection is
        # silently ignored (see _on_game_selected); otherwise, changing game WHILE a previous
        # request is still in flight could redisplay the OLD game's entries over the new one
        # once that late response arrives.
        fetched = {"title": "", "prompt": "", "drive_c": None, "generation": 0}

        rows_box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=2)
        page.add_row(rows_box)

        def iter_rows():
            child = rows_box.get_first_child()
            while child is not None:
                yield child
                child = child.get_next_sibling()

        def add_row(after_row=None):
            new_row = LauncherEntryRow(self.window, lambda: fetched["drive_c"], on_add=add_row, on_remove=remove_row)
            if after_row is None:
                rows_box.append(new_row)
            else:
                rows_box.insert_child_after(new_row, after_row)
            return new_row

        def remove_row(row):
            # If only one row remains, "Remove" no longer removes anything (at least one row
            # always stays visible) but CLEARS that row instead. A row's executable can only
            # be changed via the native picker (never typed, see LauncherEntryRow), so
            # otherwise an executable already chosen on the single remaining row could never
            # be erased, which also prevented reaching a truly empty form to disable LPM
            # Launcher from "Run". The button therefore stays ALWAYS active (see
            # LauncherEntryRow.__init__, remove_btn is never disabled).
            if len(list(iter_rows())) <= 1:
                row.reset()
                return
            rows_box.remove(row)

        def clear_to_one_empty_row():
            rows = list(iter_rows())
            for extra in rows[1:]:
                rows_box.remove(extra)
            if rows:
                rows[0].reset()
            else:
                add_row()

        add_row()

        def _apply_fetched_entries(entries: list):
            clear_to_one_empty_row()
            if not entries:
                return
            rows = list(iter_rows())
            first = rows[0]
            first.load_entry(entries[0])
            previous = first
            for entry in entries[1:]:
                new_row = add_row(after_row=previous)
                new_row.load_entry(entry)
                previous = new_row

        def _on_game_selected(*_):
            fetched["generation"] += 1
            my_generation = fetched["generation"]
            slug = game_row.selected_slug()
            if not slug:
                # Back to the "— Choose a game —" placeholder (or list not loaded yet): nothing
                # to show, never the state of a previous game left displayed for a game that is
                # no longer selected.
                fetched["title"] = ""
                fetched["prompt"] = ""
                fetched["drive_c"] = None
                clear_to_one_empty_row()
                return

            page.toast(t("gui.launcher_entries.loading"))

            def on_get_done(result: backend.CommandResult):
                data = json_result(result)

                def apply():
                    # Ignore a stale response (see the comment on "generation" above) -- a
                    # more recent selection already happened while this request was in flight.
                    if fetched["generation"] != my_generation:
                        return
                    fetched["title"] = str(data.get("title") or "")
                    fetched["prompt"] = str(data.get("prompt") or "")
                    fetched["drive_c"] = data.get("drive_c") or None
                    _apply_fetched_entries(data.get("entries") or [])

                _run_on_main(apply)

            backend.run_lpm_async(["launcher-entries", slug, "get"], on_done=on_get_done)

        game_row.connect_changed(_on_game_selected)

        # Reset (see CommandPage.reset_selection) -- the entry rows must never fall back to
        # the state of a previous session.
        def reset_fields():
            # clear_selection() BEFORE refresh() -- see SingleGameSelect.clear_selection:
            # otherwise the refresh() right after would restore the same selection.
            game_row.clear_selection()
            game_row.refresh()
            refresh_active_status()
            fetched["title"] = ""
            fetched["prompt"] = ""
            fetched["drive_c"] = None
            clear_to_one_empty_row()

        page.reset_selection = reset_fields

        def on_run(*_):
            slug = game_row.selected_slug()
            if not slug:
                page.toast(t("gui.launcher_entries.toast_choose_game"))
                return

            # "--if-needed": see lib/zgl-launcher-manager.sh -- a game already in the
            # requested state must never make "Run" fail (see this method's docstring).
            def run_toggle(desired_action: str):
                page.run_command(["launcher", slug, desired_action, "--if-needed"], t("gui.common.done"))

            entries_payload = [row.entry_payload() for row in iter_rows()]
            # Completely empty rows are ignored here (nothing to send) -- a partially filled
            # row is still sent, "lib/zgl-launcher-entries.sh" (action "set") ignores it on its
            # side if the label or executable is missing (same tolerance as on the read side,
            # see its header comment).
            has_content = any(e["label"] or e["exe_win"] or e["exe_linux"] for e in entries_payload)
            if not has_content:
                # Empty form -> disable (see this method's docstring) -- never a
                # "launcher-entries set" call here, nothing to write.
                run_toggle("off")
                return

            payload = {"title": fetched["title"], "prompt": fetched["prompt"], "entries": entries_payload}
            tmp_fd, tmp_path = tempfile.mkstemp(prefix="lpm-launcher-entries-", suffix=".json")
            try:
                with os.fdopen(tmp_fd, "w") as f:
                    json.dump(payload, f)
            except OSError:
                page.toast(t("gui.common.command_failed", "?"))
                return

            page.run_button.set_sensitive(False)

            def on_set_done(result: backend.CommandResult):
                def finish():
                    try:
                        os.unlink(tmp_path)
                    except OSError:
                        pass
                    if result.returncode != 0:
                        page.run_button.set_sensitive(True)
                        page.toast_failure(result.returncode)
                        return
                    run_toggle("on")

                _run_on_main(finish)

            backend.run_lpm_async(["launcher-entries", slug, "set", tmp_path], on_done=on_set_done)

        page.run_button.connect("clicked", on_run)
        return page

    def page_lsfg(self):
        """Frame generation (lsfg-vk). An extra row above the game selector shows the
        lsfg-vk.dll reference DLL already configured (or lets the user pick it if not yet):
        "lpm lsfg ... on" needed it via a terminal prompt ("read -p", see zgl-lsfg-manager.sh)
        that can neither display nor receive anything from the GUI (no TTY) and failed
        silently (zgl-lsfg-dll.sh, a dedicated CLI command, replaces that prompt for this
        case).

        "vk_notice_row", at the very top, is separate from the DLL choice (text too long and
        always shown otherwise): it shows NOTHING when lsfg-vk (the Vulkan layer itself, not
        the reference DLL below) is already installed, and only a short warning otherwise --
        never both at once. Relies on "lpm lsfg status" (see zgl-lsfg-manager.sh,
        non-interactive query, never the interactive install flow reserved for
        "lpm lsfg <slug> on").

        "vk_install_btn", suffix of "vk_notice_row", offers here the installation already
        available via "System > Check dependencies", without duplicating that logic (all
        detection/installation stays in zgu-lsfg-utils.sh, queried via the non-interactive
        commands "lsfg install-info"/"lsfg install-flatpak", see zgl-lsfg-manager.sh)."""
        page = CommandPage(t("gui.lsfg.page_title"), t("gui.lsfg.page_subtitle"))

        vk_notice_row = Adw.ActionRow(title=t("gui.lsfg.vk_required_notice"), visible=False)
        vk_install_btn = Gtk.Button(label=t("gui.lsfg.install_button"), valign=Gtk.Align.CENTER)
        vk_notice_row.add_suffix(vk_install_btn)
        page.add_row(vk_notice_row)

        def refresh_vk_notice_row():
            def on_done(result: backend.CommandResult):
                data = json_result(result)
                installed = bool(data.get("installed"))

                def apply():
                    vk_notice_row.set_visible(not installed)

                _run_on_main(apply)

            backend.run_lpm_async(["lsfg", "status"], on_done=on_done)

        # Optional "Install lsfg-vk" button, suffix of "vk_notice_row": visible only when
        # lsfg-vk is not installed (it disappears with its row, no separate "set_visible"
        # needed). On click, first queries "lpm lsfg install-info" (see zgl-lsfg-manager.sh) to
        # know whether Lutris runs as a Flatpak, WITHOUT installing anything before explicit
        # confirmation: Flatpak shows a confirmation window then really installs via "lsfg
        # install-flatpak" (reuses zgu_lsfg_install_flatpak_do on the bash side, no copy of
        # that logic); native shows the same link as "System > Check dependencies"
        # (zgu_lsfg_native_link_info), since no automatic install is possible then.
        def on_install_clicked(*_):
            def on_info_done(result: backend.CommandResult):
                data = json_result(result)
                if not data:
                    _run_on_main(lambda: page.toast(t("gui.lsfg.install_info_failed")))
                    return

                def apply():
                    if data.get("flatpak"):
                        runtime_version = str(data.get("runtime_version") or "")
                        if not runtime_version:
                            page.toast(t("gui.lsfg.install_runtime_unknown"))
                            return

                        def do_install():
                            def on_install_done(install_result: backend.CommandResult):
                                install_data = json_result(install_result)

                                def apply_install():
                                    if install_data.get("ok"):
                                        page.toast(t("gui.lsfg.install_success"))
                                        refresh_vk_notice_row()
                                    else:
                                        page.toast(t("gui.lsfg.install_failed"))

                                _run_on_main(apply_install)

                            backend.run_lpm_async(["lsfg", "install-flatpak", runtime_version], on_done=on_install_done)

                        dialog = Adw.AlertDialog(
                            heading=t("gui.lsfg.install_flatpak_heading"),
                            body=t("gui.lsfg.install_flatpak_body", runtime_version),
                        )
                        dialog.add_response("cancel", t("gui.lsfg.install_flatpak_cancel"))
                        dialog.add_response("confirm", t("gui.lsfg.install_flatpak_confirm"))
                        dialog.set_response_appearance("confirm", Adw.ResponseAppearance.SUGGESTED)

                        def on_response(_dlg, response):
                            if response == "confirm":
                                do_install()

                        dialog.connect("response", on_response)
                        dialog.present(self.window)
                    else:
                        link = str(data.get("link") or "")
                        link_label = str(data.get("link_label") or link)

                        dialog = Adw.AlertDialog(
                            heading=t("gui.lsfg.install_native_heading"),
                            body=t("gui.lsfg.install_native_body"),
                        )
                        if link:
                            link_btn = Gtk.LinkButton(uri=link, label=link_label,
                                                       valign=Gtk.Align.CENTER, halign=Gtk.Align.CENTER)
                            dialog.set_extra_child(link_btn)
                        dialog.add_response("close", t("gui.lsfg.install_native_close"))
                        dialog.present(self.window)

                _run_on_main(apply)

            backend.run_lpm_async(["lsfg", "install-info"], on_done=on_info_done)

        vk_install_btn.connect("clicked", on_install_clicked)

        dll_row = Adw.ActionRow(title=t("gui.lsfg.dll_title"))
        dll_browse_btn = Gtk.Button(icon_name="document-open-symbolic", valign=Gtk.Align.CENTER,
                                     tooltip_text=t("gui.lsfg.dll_browse_tooltip"))
        dll_row.add_suffix(dll_browse_btn)
        page.add_row(dll_row)

        # Tracks the current DLL path -- "Run" must NEVER be able to enable ("on" action) if
        # no reference DLL is configured, see on_run below. Otherwise "lpm lsfg ... on" hits
        # its own interactive prompt ("read -p" in zgp_lsfg_ensure_dll, see
        # zgl-lsfg-manager.sh), which fails silently from the GUI (no TTY). Not needed for
        # "off", which never touches the DLL.
        lsfg_dll_state = {"path": ""}

        def refresh_dll_row():
            def on_done(result: backend.CommandResult):
                data = json_result(result)
                path = str(data.get("path") or "")

                def apply():
                    lsfg_dll_state["path"] = path
                    dll_row.set_subtitle(path or t("gui.lsfg.dll_not_configured"))

                _run_on_main(apply)

            backend.run_lpm_async(["lsfg-dll", "get"], on_done=on_done)

        def browse_dll():
            def got(paths):
                if not paths:
                    return

                def on_done(result: backend.CommandResult):
                    def apply():
                        if result.returncode == 0:
                            refresh_dll_row()
                        else:
                            page.toast(t("gui.lsfg.dll_set_failed"))

                    _run_on_main(apply)

                backend.run_lpm_async(["lsfg-dll", "set", paths[0]], on_done=on_done)

            pick_file(self.window, t("gui.lsfg.dll_dialog_title"), got,
                      filters=[(t("gui.lsfg.dll_filter_label"), ["*.dll", "*.DLL"])])

        dll_browse_btn.connect("clicked", lambda *_: browse_dll())

        selector = GameMultiSelect()
        page.add_row(selector)
        state_row = Adw.ComboRow(title=t("gui.toggle_feature.action_title"))
        state_row.set_model(Gtk.StringList.new([
            t("gui.toggle_feature.action_enable"), t("gui.toggle_feature.action_disable"),
        ]))
        page.add_row(state_row)

        # The enable/disable choice is reset too, see CommandPage.reset_selection. The DLL
        # row and the lsfg-vk warning are also refreshed (e.g. modified by hand in the
        # meantime, or lsfg-vk installed since the page opened).
        def reset_fields():
            selector.refresh()
            state_row.set_selected(0)
            refresh_dll_row()
            refresh_vk_notice_row()

        page.reset_selection = reset_fields
        refresh_dll_row()
        refresh_vk_notice_row()

        def on_run(*_):
            slugs = selector.selected_slugs()
            if not slugs:
                page.toast(t("gui.common.choose_one_game"))
                return
            action = "on" if state_row.get_selected() in (0, Gtk.INVALID_LIST_POSITION) else "off"
            if action == "on" and not lsfg_dll_state["path"]:
                page.toast(t("gui.lsfg.toast_dll_required"))
                return
            page.run_command(["lsfg", *slugs, action], t("gui.common.done"))

        page.run_button.connect("clicked", on_run)
        return page
