"""Selectors (games, files, runners) used by the forms."""

import os

import gi

gi.require_version("Gtk", "4.0")
gi.require_version("Adw", "1")
from gi.repository import Adw, GLib, Gtk  # noqa: E402

import backend
from i18n import t
from refresh import _GAME_LIST_WIDGETS, _RUNNER_LIST_WIDGETS, _request_games_refresh, _request_runners_refresh
from util import _escape_markup, _run_on_main
from widgets_rows import _resolve_default_runner, _wrapping_text_factory


# Height (logical pixels) of the inner scroll area of every checklist (.zgp/.zgr files,
# games, runners). Without a cap, a folder with ~120 .zgp files forced scrolling the whole
# page back up just to collapse or re-check "all".
#
# set_min_content_height() alone (without vexpand, max_content_height or
# propagate_natural_height, which had no observable effect) is the setting that works here.
# 287 px ~ 5 visible rows (~57.4 px per row).
_LIST_HEIGHT = 287


def _wrap_scrollable_list(listbox: Gtk.ListBox) -> Gtk.ScrolledWindow:
    """Wrap a "listbox" in a Gtk.ScrolledWindow with a fixed minimum height (see
    _LIST_HEIGHT) -- never horizontal scrolling (NEVER), a checklist never spreads
    sideways. The header above (title, "check all" box, expand arrow if any) thus always
    stays visible, since this area scrolls, not the whole page."""
    scrolled = Gtk.ScrolledWindow()
    scrolled.set_policy(Gtk.PolicyType.NEVER, Gtk.PolicyType.AUTOMATIC)
    scrolled.set_min_content_height(_LIST_HEIGHT)
    scrolled.set_child(listbox)
    return scrolled


# ---------------------------------------------------------------------------------------
# --- Common base of the checklists (games, files, runners) ---
class _CheckListExpander(Adw.ExpanderRow):
    """Expandable row containing a checklist, with its "check/uncheck all" box in the header
    (add_suffix: visible even when collapsed) and a "selected/total" counter in the title.
    The list lives in an inner Gtk.ListBox with a capped height (see _wrap_scrollable_list),
    added ONCE as the ExpanderRow's only "row": only its content is cleared/rebuilt, so the
    header stays visible above a bounded list, even with hundreds of items.

    "Check all" syncs one way only (checking it checks/unchecks everything else) --
    deliberately no indeterminate state when the user checks items one by one."""

    def __init__(self, base_title: str):
        super().__init__(title=base_title)
        self._base_title = base_title
        self.checks: dict[str, Gtk.CheckButton] = {}
        self._rows: list[Adw.ActionRow] = []

        self.select_all_check = Gtk.CheckButton(tooltip_text=t("gui.common.select_all_tooltip"))
        self.select_all_check.connect("toggled", self._on_select_all_toggled)
        self.add_suffix(self.select_all_check)

        self._listbox = Gtk.ListBox(selection_mode=Gtk.SelectionMode.NONE)
        self.add_row(_wrap_scrollable_list(self._listbox))

    def _on_select_all_toggled(self, check: Gtk.CheckButton):
        active = check.get_active()
        for chk in self.checks.values():
            if chk.get_sensitive():  # greyed-out items (already installed) stay unchecked
                chk.set_active(active)

    def _clear_rows(self):
        for row in self._rows:
            self._listbox.remove(row)
        self._rows.clear()
        self.checks.clear()

    def _add_check_row(self, key: str, title: str, subtitle: str | None = None, active: bool = False):
        """Add a checkable row; returns (checkbox, row). The title counter is recomputed on
        each individual check/uncheck, not only via "check all" (which just triggers the same
        "toggled" signal on each box)."""
        check = Gtk.CheckButton(active=active)
        check.connect("toggled", lambda *_: self._update_title())
        action_row = Adw.ActionRow(title=_escape_markup(title))
        if subtitle is not None:
            action_row.set_subtitle(_escape_markup(subtitle))
        action_row.add_prefix(check)
        action_row.set_activatable_widget(check)
        self._listbox.append(action_row)
        self._rows.append(action_row)
        self.checks[key] = check
        return check, action_row

    def _empty_title(self) -> str:
        """Title shown when the list is empty."""
        return self._base_title

    def _update_title(self):
        if self.checks:
            available = [chk for chk in self.checks.values() if chk.get_sensitive()]
            selected = sum(1 for chk in available if chk.get_active())
            self.set_title(t("gui.common.selection_count", self._base_title, selected, len(available)))
        else:
            self.set_title(self._empty_title())

    def _checked_keys(self) -> list[str]:
        return [key for key, chk in self.checks.items() if chk.get_active() and chk.get_sensitive()]


# ---------------------------------------------------------------------------------------
# --- Multi-game selector (checked/unchecked), filled from "lpm list" ---
class GameMultiSelect(_CheckListExpander):
    def __init__(self, title: str | None = None):
        super().__init__(title or t("gui.game_select.default_title"))
        self._name_by_slug: dict[str, str] = {}

        self.refresh()
        # Registration for global refresh (see _refresh_game_lists and
        # CommandPage.run_command, "refresh" parameter) -- AFTER the first refresh() above,
        # to avoid calling itself a second time needlessly at construction.
        _GAME_LIST_WIDGETS.append(self)

    def refresh(self):
        # backend.list_games() launches a subprocess ("bin/lpm list") -- never called
        # directly here, see _make_coalesced_refresher: several close refresh() calls (e.g.
        # the "back" button, which triggers one per built page) share ONE subprocess, the
        # result being applied asynchronously via _apply_entries below, always on the main
        # thread.
        _request_games_refresh(self._apply_entries)

    def _apply_entries(self, entries):
        self._clear_rows()
        self._name_by_slug.clear()
        self.select_all_check.set_active(False)

        for entry in entries:
            self._add_check_row(entry.slug, entry.name, entry.slug)
            self._name_by_slug[entry.slug] = entry.name

        self._update_title()

    def selected_slugs(self) -> list[str]:
        return self._checked_keys()

    def selected_entries(self) -> list[tuple[str, str]]:
        """Like selected_slugs(), but with each game's display name (Lutris) -- used by the
        SteamGridDB visual picker (gui.SgdbPickerWindow) to show "Game X/Y -- <name>"
        without rerunning "bin/lpm list" itself."""
        return [(slug, self._name_by_slug.get(slug, slug)) for slug in self.selected_slugs()]


class FileMultiSelect(_CheckListExpander):
    """Multi-file selector (checked/unchecked), filled from a list of paths given explicitly
    via set_paths() -- not from the backend, unlike GameMultiSelect. Used to refine the
    (de)selection after a file choice in the native picker (see pick_file), with the same
    check/uncheck all box."""

    def __init__(self, title: str | None = None):
        super().__init__(title or t("gui.file_select.default_title"))

        # No automatic expansion when the list is filled (see set_paths) -- focus on the
        # single checked file must only happen when THE USER expands the list (click on the
        # ExpanderRow). "notify::expanded" fires for a manual expansion as well as a future
        # programmatic set_expanded(), so no other hook is needed.
        self.connect("notify::expanded", self._on_expanded_changed)

        self.set_paths([])

    def _on_expanded_changed(self, *_):
        if not self.get_expanded():
            return
        # Default behavior: only when THE LIST OPENS (never before, see set_paths), if
        # EXACTLY one file is checked at that moment, it gets the focus (and thus the
        # automatic scrolling, see below) -- never if several or none are checked, since we
        # could not guess which to show.
        checked = [chk for chk in self.checks.values() if chk.get_active()]
        if len(checked) != 1:
            return
        focus_target = checked[0]
        # Focusing a widget scrolls to it automatically -- GTK4 wraps a Gtk.ScrolledWindow's
        # content in a Gtk.Viewport, which handles that scrolling when a descendant gets
        # focus, with no manual scrolling code. Deferred via GLib.idle_add: when this signal
        # fires, the content may not be "mapped" yet (expansion just started) and an
        # immediate grab_focus() would silently fail.
        GLib.idle_add(lambda: (focus_target.grab_focus(), False)[1])

    def set_paths(self, paths: list[str], checked_paths: list[str] | None = None):
        """paths: everything shown in the list (e.g. all .zgp found in the chosen file's
        folder). checked_paths: subset checked by default (e.g. only the file(s) the user
        actually chose in the native picker) -- if omitted, everything is checked."""
        self._clear_rows()

        checked_set = set(paths if checked_paths is None else checked_paths)

        # Do not auto-expand here, whatever the number of pre-checked files -- the list stays
        # collapsed by default (including right after a .zgp/.zgr double-click); focus on the
        # single checked file only happens when the user expands it (see _on_expanded_changed).
        #
        # Reflects the real checked/unchecked state rather than assuming "all checked",
        # since only a subset can be pre-checked.
        self.select_all_check.set_active(bool(paths) and checked_set == set(paths))

        for path in paths:
            self._add_check_row(path, os.path.basename(path), path, active=path in checked_set)

        self._update_title()

    def _empty_title(self) -> str:
        # While files are listed, the "selected/total" counter is shown even at 0 selected
        # (it must update as the user clicks); otherwise, base title followed by a
        # "no file" mention.
        return t("gui.file_select.title_empty", self._base_title)

    def selected_paths(self) -> list[str]:
        return self._checked_keys()


class RunnerMultiSelect(_CheckListExpander):
    """Multi-selector of INSTALLED runners (local list), same presentation as
    GameMultiSelect: expandable row, "selected/total" counter in the title, check-all box in
    the header. Refreshed via the global runner-list registry."""

    def __init__(self, title: str | None = None):
        super().__init__(title or t("gui.common.runners_installed_label"))
        self.refresh()
        _RUNNER_LIST_WIDGETS.append(self)

    def refresh(self):
        # See GameMultiSelect.refresh: never a subprocess on the main thread.
        _request_runners_refresh(self._apply_runners)

    def _apply_runners(self, runners):
        self._clear_rows()
        self.select_all_check.set_active(False)
        for runner in runners:
            self._add_check_row(runner, runner)
        self._update_title()

    def selected_names(self) -> list[str]:
        return self._checked_keys()


class RemoteRunnerMultiSelect(_CheckListExpander):
    """Multi-selector of remote runners (GitHub release list), same presentation as
    GameMultiSelect/FileMultiSelect: expandable row collapsed by default, "selected/total"
    counter in the title, check-all box in the header. Already installed runners are greyed
    out (not checkable). The list is loaded when the page opens (and on each refresh()),
    never on the main thread -- no refresh button."""

    def __init__(self):
        super().__init__(t("gui.download_runner.list_label"))
        self._gen = 0
        self.refresh()

    def refresh(self):
        # Generation counter: a result arriving after a more recent request is discarded
        # (e.g. back to the menu then reopening while a load is in progress).
        self._gen += 1
        gen = self._gen
        self._clear()
        self.set_subtitle(t("gui.download_runner.loading"))
        backend.run_lpm_async(
            ["list-remote-runners"],
            on_done=lambda result: _run_on_main(self._apply_result, gen, result),
        )

    def _clear(self):
        self._clear_rows()
        self.select_all_check.set_active(False)
        self._update_title()

    def _apply_result(self, gen, result):
        if gen != self._gen:
            return
        if result.returncode != 0:
            self.set_subtitle(t("gui.download_runner.fetch_failed"))
            return
        names = [ln.strip() for ln in result.stdout.splitlines() if ln.strip()]
        if not names:
            self.set_subtitle(t("gui.download_runner.none_available"))
            return
        self.set_subtitle("")
        suffix = t("list_remote.already_installed_suffix").strip()
        for line in names:
            installed = bool(suffix) and line.endswith(suffix)
            name = line[: -len(suffix)].rstrip() if installed else line
            check, action_row = self._add_check_row(name, name)
            if installed:
                action_row.set_subtitle(t("gui.download_runner.already_installed"))
                check.set_sensitive(False)
                action_row.set_sensitive(False)
        self._update_title()

    def selected_names(self) -> list[str]:
        return self._checked_keys()


class SingleGameSelect(Adw.ExpanderRow):
    """Selector for a SINGLE game -- same style as GameMultiSelect (Adw.ExpanderRow +
    bounded dropdown list, see _wrap_scrollable_list) but WITHOUT checkboxes: clicking a
    row selects it (Gtk.ListBox in SINGLE mode). The classic dropdown menu was unreadable
    for choosing a game, unlike checklists.

    Unlike Gtk.SingleSelection (used internally by Adw.ComboRow), Gtk.ListBox.SINGLE never
    forces a default selection, so no game is ever chosen on its own when a page opens (no
    "placeholder" hack needed)."""

    def __init__(self, title: str | None = None, highlighted_slugs: set | None = None):
        self._base_title = title or t("gui.game_combo.default_title")
        super().__init__(title=self._base_title)
        self._slugs: list[str] = []
        self._names: list[str] = []
        self._rows: list[Adw.ActionRow] = []
        self._selected_slug: str | None = None
        self._on_change = None  # see connect_changed()
        # Shared set (mutable, updated by the caller) of slugs to show in bold -- e.g.
        # page_launcher uses it to highlight games that already have LPM Launcher active (see
        # repaint_titles()). Empty by default (page_tools does not need this highlighting).
        self._highlighted_slugs = highlighted_slugs if highlighted_slugs is not None else set()

        self._listbox = Gtk.ListBox(selection_mode=Gtk.SelectionMode.SINGLE)
        self._listbox.connect("row-selected", self._on_row_selected)
        self.add_row(_wrap_scrollable_list(self._listbox))

        self.refresh()
        _GAME_LIST_WIDGETS.append(self)  # see GameMultiSelect.__init__

    def refresh(self):
        # See GameMultiSelect.refresh: shared subprocess, never called directly from the
        # main thread.
        _request_games_refresh(self._apply_entries)

    def _apply_entries(self, entries):
        # Restore the SAME selection as before the refresh if that game still exists (e.g.
        # another game was just installed/uninstalled elsewhere, see _refresh_game_lists) --
        # never a new selection, never lost without reason.
        previous_slug = self._selected_slug

        for row in self._rows:
            self._listbox.remove(row)
        self._rows.clear()
        self._slugs.clear()
        self._names.clear()
        self._selected_slug = None

        restored_row = None
        for entry in entries:
            action_row = Adw.ActionRow(title=self._row_title(entry.name, entry.slug), subtitle=_escape_markup(entry.slug))
            action_row.set_activatable(True)
            self._listbox.append(action_row)
            self._rows.append(action_row)
            self._slugs.append(entry.slug)
            self._names.append(entry.name)
            if entry.slug == previous_slug:
                restored_row = action_row

        if restored_row is not None:
            self._listbox.select_row(restored_row)  # triggers _on_row_selected
        else:
            self._update_title()

    def _on_row_selected(self, _listbox, row):
        if row is None:
            self._selected_slug = None
        else:
            self._selected_slug = self._slugs[self._rows.index(row)]
            # A SINGLE choice (no checkbox, one game only) has no reason to stay open once
            # the game is clicked -- close the dropdown right away. Never done on
            # GameMultiSelect (several games to check one after another, the menu must stay open).
            self.set_expanded(False)
        self._update_title()
        if self._on_change:
            self._on_change()

    def _update_title(self):
        if self._selected_slug is None:
            self.set_title(self._base_title)
            return
        idx = self._slugs.index(self._selected_slug)
        self.set_title(_escape_markup(t("gui.game_combo.selected_title", self._base_title, self._names[idx])))

    def selected_slug(self) -> str | None:
        return self._selected_slug

    def connect_changed(self, callback):
        """callback() with no argument, called on each selection change -- substitute for
        "notify::selected" (Adw.ComboRow), which this widget lacks (Gtk.ListBox exposes
        "row-selected", already wired internally to _on_row_selected)."""
        self._on_change = callback

    def clear_selection(self):
        """Go back to "no game chosen" RIGHT AWAY (synchronous) -- call BEFORE refresh() to
        truly reset (e.g. CommandPage.reset_selection when leaving the page). Otherwise a
        refresh() launched just after would restore the same selection via _apply_entries
        (see its comment): that mechanism only looks at self._selected_slug when the refresh
        response arrives, so clearing it here before calling refresh() prevents restoration.
        unselect_all() fires "row-selected" (with row=None) even when nothing is selected
        (no-op then): _on_row_selected already does all the work (self._selected_slug, title,
        callback), no need to duplicate it here."""
        self._listbox.unselect_all()

    def _row_title(self, name: str, slug: str) -> str:
        escaped = _escape_markup(name)
        if slug in self._highlighted_slugs:
            return f"<b>{escaped}</b>"
        return escaped

    def repaint_titles(self):
        """Reapply the title (bold or not) of each already-built row from the current
        self._highlighted_slugs -- without any CLI/subprocess call or rebuilding the rows
        (unlike refresh()). See page_launcher: called after each update of the "LPM Launcher
        active" status."""
        for slug, name, row in zip(self._slugs, self._names, self._rows):
            row.set_title(self._row_title(name, slug))


class RunnerCombo(Adw.ComboRow):
    def __init__(self, title: str | None = None, placeholder: str | None = None):
        super().__init__(title=title or t("gui.runner_combo.default_title"))
        # With a placeholder, the first row is that prompt (never a runner): nothing is chosen
        # until the user picks a real runner, even the default one -- for an action that
        # modifies an existing game (see explicit_runner()).
        self._placeholder = placeholder
        self._runners: list[str] = []
        self._default_runner_missing = False
        self._user_touched = False
        self._programmatic_select = False
        # Show full runner names (wrapped) instead of truncated with "...", see
        # _wrapping_text_factory.
        self.set_factory(_wrapping_text_factory())
        self.connect("notify::selected", self._on_selected_changed)
        self.refresh()
        _RUNNER_LIST_WIDGETS.append(self)  # see GameMultiSelect.__init__

    def _on_selected_changed(self, *_):
        # Tells a user selection apart from an internal set_selected() (_apply_entries, during
        # a refresh) -- see its use in selected_runner().
        if not self._programmatic_select:
            self._user_touched = True

    def refresh(self):
        # See GameMultiSelect.refresh: shared subprocess, never called directly from the
        # main thread.
        _request_runners_refresh(self._apply_entries)

    def _apply_entries(self, runners):
        self._runners = runners
        self._user_touched = False
        self._programmatic_select = True
        try:
            if not self._runners:
                self.set_model(Gtk.StringList.new([t("gui.runner_combo.none_installed")]))
                self.set_selected(0)
                return

            # A single list (the actually installed runners, no separate "default" entry).
            # The one matching the real default runner (see _resolve_default_runner, which
            # reads wine.yml exactly like zgu_get_default_runner in lib/zgu-lutris-utils.sh)
            # is pre-selected when installed.
            #
            # If it is NOT installed (absent from "runners"), the selection is NOT forced onto
            # the first runner of the (alphabetically sorted) list: that value has nothing to
            # do with the real default. "_default_runner_missing" stays true in that case, and
            # selected_runner() lets bin/lpm resolve the default itself (as on the CLI when
            # "-r" is omitted), UNLESS the user explicitly selects that first displayed runner
            # (see "_user_touched" in selected_runner()).
            if self._placeholder:
                self.set_model(Gtk.StringList.new([self._placeholder] + self._runners))
                self.set_selected(0)
                return
            default_runner = _resolve_default_runner()
            self._default_runner_missing = default_runner not in self._runners
            idx = self._runners.index(default_runner) if not self._default_runner_missing else 0
            self.set_model(Gtk.StringList.new(self._runners))
            self.set_selected(idx)
        finally:
            self._programmatic_select = False

    def explicit_runner(self) -> str | None:
        """Runner actually chosen in the list (placeholder mode), None while the prompt is
        shown -- never a runner pre-selected by default."""
        idx = self.get_selected()
        if not self._placeholder or idx == Gtk.INVALID_LIST_POSITION or idx < 1 or idx > len(self._runners):
            return None
        return self._runners[idx - 1]

    def selected_runner(self) -> str | None:
        idx = self.get_selected()
        if idx is None or idx == Gtk.INVALID_LIST_POSITION or not self._runners or idx >= len(self._runners):
            return None
        if self._default_runner_missing and not self._user_touched:
            return None
        return self._runners[idx]
