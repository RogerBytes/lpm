"""Page 'LPM Launcher': enables the launcher and edits its picker entries for ONE game."""

import json
import os
import tempfile

import gi

gi.require_version("Gtk", "4.0")
gi.require_version("Adw", "1")
from gi.repository import Gtk  # noqa: E402

import backend
from i18n import t
from commandpage import CommandPage
from util import _run_on_main, json_result
from widgets_rows import LauncherEntryRow
from widgets_select import SingleGameSelect


class LauncherPage:
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

    def __init__(self, window):
        self.window = window

    def build(self):
        self._add_game_row()
        self._add_entry_rows()
        self._wire_selection()
        self._wire_reset_and_run()
        return self.page

    def _add_game_row(self):
        self.page = CommandPage(t("gui.launcher.page_title"))

        # Set (mutable, updated in place) of slugs that already have LPM Launcher active
        # (bolded in the game list), read via "lpm launcher status" (see
        # lib/zgl-launcher-manager.sh, point 7) and reapplied by game_row.repaint_titles() --
        # never hard-coded in the game list itself: display (bold) and data (game list) are
        # two separate refreshes, neither waits for the other.
        self.active_slugs: set = set()
        self.game_row = SingleGameSelect(highlighted_slugs=self.active_slugs)
        self.page.add_row(self.game_row)

        self.refresh_active_status()

    def _add_entry_rows(self):
        # State tied to the currently selected game -- filled by _on_game_selected (after
        # "launcher-entries <slug> get"), read by the rows' native file pickers (get_drive_c)
        # and sent back as is to "set" (title/prompt are not edited here, see the docstring
        # above: this form only touches the entries) -- never frozen at row construction
        # since the chosen game may change afterwards. "generation": incremented on EACH
        # selection change -- a "get" response that returns after a more recent selection is
        # silently ignored (see _on_game_selected); otherwise, changing game WHILE a previous
        # request is still in flight could redisplay the OLD game's entries over the new one
        # once that late response arrives.
        self.fetched = {"title": "", "prompt": "", "drive_c": None, "generation": 0}

        self.rows_box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=2)
        self.page.add_row(self.rows_box)

        self.add_row()

    def _wire_selection(self):
        self.game_row.connect_changed(self._on_game_selected)

    def _wire_reset_and_run(self):
        self.page.reset_selection = self.reset_fields

        self.page.run_button.connect("clicked", self.on_run)

    def _apply_active_status(self, result: backend.CommandResult):
        if result.returncode != 0:
            return
        self.active_slugs.clear()
        self.active_slugs.update(line.strip() for line in result.stdout.splitlines() if line.strip())
        self.game_row.repaint_titles()

    def refresh_active_status(self):
        backend.run_lpm_async(["launcher", "status"], on_done=lambda result: _run_on_main(self._apply_active_status, result))

    def iter_rows(self):
        child = self.rows_box.get_first_child()
        while child is not None:
            yield child
            child = child.get_next_sibling()

    def add_row(self, after_row=None):
        new_row = LauncherEntryRow(self.window, lambda: self.fetched["drive_c"], on_add=self.add_row, on_remove=self.remove_row)
        if after_row is None:
            self.rows_box.append(new_row)
        else:
            self.rows_box.insert_child_after(new_row, after_row)
        return new_row

    def remove_row(self, row):
        # If only one row remains, "Remove" no longer removes anything (at least one row
        # always stays visible) but CLEARS that row instead. A row's executable can only
        # be changed via the native picker (never typed, see LauncherEntryRow), so
        # otherwise an executable already chosen on the single remaining row could never
        # be erased, which also prevented reaching a truly empty form to disable LPM
        # Launcher from "Run". The button therefore stays ALWAYS active (see
        # LauncherEntryRow.__init__, remove_btn is never disabled).
        if len(list(self.iter_rows())) <= 1:
            row.reset()
            return
        self.rows_box.remove(row)

    def clear_to_one_empty_row(self):
        rows = list(self.iter_rows())
        for extra in rows[1:]:
            self.rows_box.remove(extra)
        if rows:
            rows[0].reset()
        else:
            self.add_row()

    def _apply_fetched_entries(self, entries: list):
        self.clear_to_one_empty_row()
        if not entries:
            return
        rows = list(self.iter_rows())
        first = rows[0]
        first.load_entry(entries[0])
        previous = first
        for entry in entries[1:]:
            new_row = self.add_row(after_row=previous)
            new_row.load_entry(entry)
            previous = new_row

    def _on_game_selected(self, *_):
        self.fetched["generation"] += 1
        my_generation = self.fetched["generation"]
        slug = self.game_row.selected_slug()
        if not slug:
            # Back to the "— Choose a game —" placeholder (or list not loaded yet): nothing
            # to show, never the state of a previous game left displayed for a game that is
            # no longer selected.
            self.fetched["title"] = ""
            self.fetched["prompt"] = ""
            self.fetched["drive_c"] = None
            self.clear_to_one_empty_row()
            return

        self.page.toast(t("gui.launcher_entries.loading"))

        def on_get_done(result: backend.CommandResult):
            data = json_result(result)

            def apply():
                # Ignore a stale response (see the comment on "generation" above) -- a
                # more recent selection already happened while this request was in flight.
                if self.fetched["generation"] != my_generation:
                    return
                self.fetched["title"] = str(data.get("title") or "")
                self.fetched["prompt"] = str(data.get("prompt") or "")
                self.fetched["drive_c"] = data.get("drive_c") or None
                self._apply_fetched_entries(data.get("entries") or [])

            _run_on_main(apply)

        backend.run_lpm_async(["launcher-entries", slug, "get"], on_done=on_get_done)

    # Reset (see CommandPage.reset_selection) -- the entry rows must never fall back to
    # the state of a previous session.
    def reset_fields(self):
        # clear_selection() BEFORE refresh() -- see SingleGameSelect.clear_selection:
        # otherwise the refresh() right after would restore the same selection.
        self.game_row.clear_selection()
        self.game_row.refresh()
        self.refresh_active_status()
        self.fetched["title"] = ""
        self.fetched["prompt"] = ""
        self.fetched["drive_c"] = None
        self.clear_to_one_empty_row()

    def on_run(self, *_):
        slug = self.game_row.selected_slug()
        if not slug:
            self.page.toast(t("gui.launcher_entries.toast_choose_game"))
            return

        entries_payload = [row.entry_payload() for row in self.iter_rows()]
        # Completely empty rows are ignored here (nothing to send) -- a partially filled
        # row is still sent, "lib/zgl-launcher-entries.sh" (action "set") ignores it on its
        # side if the label or executable is missing (same tolerance as on the read side,
        # see its header comment).
        has_content = any(e["label"] or e["exe_win"] or e["exe_linux"] for e in entries_payload)
        if not has_content:
            # Empty form -> disable (see the class docstring) -- never a
            # "launcher-entries set" call here, nothing to write.
            self._run_toggle(slug, "off")
            return
        self._save_entries_then_enable(slug, entries_payload)

    def _run_toggle(self, slug, desired_action: str):
        # "--if-needed": see lib/zgl-launcher-manager.sh -- a game already in the
        # requested state must never make "Run" fail (see the class docstring).
        self.page.run_command(["launcher", slug, desired_action, "--if-needed"], t("gui.common.done"))

    def _save_entries_then_enable(self, slug, entries_payload):
        payload = {"title": self.fetched["title"], "prompt": self.fetched["prompt"], "entries": entries_payload}
        tmp_fd, tmp_path = tempfile.mkstemp(prefix="lpm-launcher-entries-", suffix=".json")
        try:
            with os.fdopen(tmp_fd, "w") as f:
                json.dump(payload, f)
        except OSError:
            self.page.toast(t("gui.common.command_failed", "?"))
            return

        self.page.run_button.set_sensitive(False)

        def on_set_done(result: backend.CommandResult):
            def finish():
                try:
                    os.unlink(tmp_path)
                except OSError:
                    pass
                if result.returncode != 0:
                    self.page.run_button.set_sensitive(True)
                    self.page.toast_failure(result.returncode)
                    return
                self._run_toggle(slug, "on")

            _run_on_main(finish)

        backend.run_lpm_async(["launcher-entries", slug, "set", tmp_path], on_done=on_set_done)
