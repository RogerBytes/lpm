"""Specialized form rows and native file/folder pickers."""

import os
import re
import subprocess

import gi

gi.require_version("Gtk", "4.0")
gi.require_version("Adw", "1")
from gi.repository import Adw, GLib, Gio, Gtk, Pango  # noqa: E402

import backend
from i18n import t


class PrefixEntryRow(Gtk.Box):
    """One input row for "create an empty prefix": display name + slug, used in a repeatable
    list (see page_create_prefix) -- one row at the start, "+" adds a row right after this
    one, the trash button removes this one. The slug fills in live from the name (via
    backend.slugify_preview, the same algorithm as Lutris) until the user edits it by hand;
    from then on automatic tracking is PERMANENTLY detached for this row, like Lutris'
    game editor."""

    def __init__(self, on_add, on_remove):
        super().__init__(orientation=Gtk.Orientation.HORIZONTAL, spacing=6)
        self.set_margin_top(3)
        self.set_margin_bottom(3)
        self._slug_follows_name = True
        self._updating_slug = False

        self.name_entry = Gtk.Entry(
            placeholder_text=t("gui.create_prefix.name_placeholder"), hexpand=True, valign=Gtk.Align.CENTER
        )
        self.name_entry.connect("changed", self._on_name_changed)
        self.slug_entry = Gtk.Entry(
            placeholder_text=t("gui.create_prefix.slug_placeholder"), hexpand=True, valign=Gtk.Align.CENTER
        )
        self.slug_entry.connect("changed", self._on_slug_changed)

        add_btn = Gtk.Button(icon_name="list-add-symbolic", valign=Gtk.Align.CENTER,
                              tooltip_text=t("gui.create_prefix.add_row_tooltip"))
        add_btn.connect("clicked", lambda *_: on_add(self))
        self.remove_btn = Gtk.Button(icon_name="user-trash-symbolic", valign=Gtk.Align.CENTER,
                                      tooltip_text=t("gui.create_prefix.remove_row_tooltip"))
        self.remove_btn.connect("clicked", lambda *_: on_remove(self))

        self.append(self.name_entry)
        self.append(self.slug_entry)
        self.append(add_btn)
        self.append(self.remove_btn)

    def _on_name_changed(self, *_):
        if not self._slug_follows_name:
            return
        # PROGRAMMATIC slug update -- _updating_slug stops _on_slug_changed from treating it
        # as a manual edit, which would immediately break the automatic tracking just
        # applied. Empty name -> empty slug (no slugify_preview call: its UUID fallback on an
        # empty string would be meaningless to display).
        name = self.name_entry.get_text()
        self._updating_slug = True
        self.slug_entry.set_text(backend.slugify_preview(name) if name.strip() else "")
        self._updating_slug = False

    def _on_slug_changed(self, *_):
        if self._updating_slug:
            return
        self._slug_follows_name = False

    def target_spec(self) -> str | None:
        """"Name" or "Name|slug" (if the slug was edited by hand AND differs from the
        automatic preview), in the format expected by "bin/lpm create-prefix" -- None if the
        name is empty (row to ignore at creation)."""
        name = self.name_entry.get_text().strip()
        if not name:
            return None
        if self._slug_follows_name:
            return name
        slug = self.slug_entry.get_text().strip()
        if not slug or slug == backend.slugify_preview(name):
            return name
        return f"{name}|{slug}"

    def reset(self):
        # "_slug_follows_name = True" at the very end, AFTER both set_text() calls:
        # _on_name_changed (triggered by set_text on name_entry) resets "_updating_slug" to
        # False on exit, which would break the guard if the set_text on slug_entry came next
        # without an active guard.
        self._updating_slug = True
        self.name_entry.set_text("")
        self.slug_entry.set_text("")
        self._updating_slug = False
        self._slug_follows_name = True


class LauncherEntryRow(Gtk.Box):
    """One input row for an entry of the "LPM Launcher" picker: label, executable (native
    picker restricted to the chosen game's "drive_c" -- never typed by hand, see
    self.exe_entry.set_editable(False) below), working directory (pre-filled from the
    executable's folder, editable by hand or via its own picker -- same "until manually
    edited" tracking as PrefixEntryRow.slug_entry) and launch arguments (text appended after
    the executable on the command line). Used in a repeatable list (see page_launcher), one
    game at a time, same pattern as "Create an empty prefix" (PrefixEntryRow).

    Windows ("_win") vs Linux ("_linux") paths: an entry already in the YAML must be
    redisplayed EXACTLY as stored ("C:\\Games\\..."), never its Linux resolution (which
    may go through an unreadable "dosdevices/x:/..." symlink). So each field keeps its "_win"
    value (displayed text; the source of truth for workdir since it is hand-editable) AND its
    "_linux" value (known only when loaded from the YAML or chosen via a native picker, which
    always returns Linux paths). entry_payload() sends BOTH (see lib/zgl-launcher-entries.sh,
    action "set", which prefers the literal "_win" form when provided and falls back to the
    "winepath -w" conversion of the "_linux" form only if "_win" is empty, e.g. after a new
    pick via the picker).

    "get_drive_c": callable with no argument returning the "drive_c" (Linux path) of the game
    currently selected on the page, or None -- read each time a picker opens (never frozen
    at row construction), since the chosen game may change afterwards."""

    def __init__(self, window, get_drive_c, on_add, on_remove):
        super().__init__(orientation=Gtk.Orientation.VERTICAL, spacing=3)
        self.set_margin_top(4)
        self.set_margin_bottom(4)
        self._window = window
        self._get_drive_c = get_drive_c
        self._workdir_follows_exe = True
        self._updating_workdir = False
        # Source of truth for the executable -- never edited directly by the user (see
        # exe_entry.set_editable(False)), so always up to date via load_entry()/_set_exe().
        self._exe_win = ""
        self._exe_linux = ""
        # Current form of the displayed working directory: "win" ("C:\...", from the YAML or
        # typed by hand -- the expected default) or "linux" (raw Linux path, only right after
        # a pick via the native folder picker). Unlike the executable there is no separate
        # "_win"/"_linux" field: the working directory IS hand-editable, so its displayed
        # text is always the source of truth whatever its form.
        self._workdir_form = "win"

        top_row = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=6)
        self.label_entry = Gtk.Entry(
            placeholder_text=t("gui.launcher_entries.label_placeholder"), hexpand=True, valign=Gtk.Align.CENTER
        )
        top_row.append(self.label_entry)

        add_btn = Gtk.Button(icon_name="list-add-symbolic", valign=Gtk.Align.CENTER,
                              tooltip_text=t("gui.create_prefix.add_row_tooltip"))
        add_btn.connect("clicked", lambda *_: on_add(self))
        self.remove_btn = Gtk.Button(icon_name="user-trash-symbolic", valign=Gtk.Align.CENTER,
                                      tooltip_text=t("gui.create_prefix.remove_row_tooltip"))
        self.remove_btn.connect("clicked", lambda *_: on_remove(self))
        top_row.append(add_btn)
        top_row.append(self.remove_btn)
        self.append(top_row)

        exe_row = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=6)
        self.exe_entry = Gtk.Entry(
            placeholder_text=t("gui.launcher_entries.exe_placeholder"), hexpand=True, valign=Gtk.Align.CENTER
        )
        # Never hand-editable (a real native file picker): only the "Browse" button changes
        # the executable, avoiding guessing which format (Linux? Windows? relative?) typed
        # text should be interpreted in.
        self.exe_entry.set_editable(False)
        self.exe_entry.set_can_focus(False)
        exe_browse_btn = Gtk.Button(icon_name="document-open-symbolic", valign=Gtk.Align.CENTER,
                                     tooltip_text=t("gui.launcher_entries.exe_browse_tooltip"))
        exe_browse_btn.connect("clicked", lambda *_: self._browse_exe())
        exe_row.append(self.exe_entry)
        exe_row.append(exe_browse_btn)
        self.append(exe_row)

        workdir_row = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=6)
        self.workdir_entry = Gtk.Entry(
            placeholder_text=t("gui.launcher_entries.workdir_placeholder"), hexpand=True, valign=Gtk.Align.CENTER
        )
        self.workdir_entry.connect("changed", self._on_workdir_changed)
        workdir_browse_btn = Gtk.Button(icon_name="folder-open-symbolic", valign=Gtk.Align.CENTER,
                                         tooltip_text=t("gui.launcher_entries.workdir_browse_tooltip"))
        workdir_browse_btn.connect("clicked", lambda *_: self._browse_workdir())
        workdir_row.append(self.workdir_entry)
        workdir_row.append(workdir_browse_btn)
        self.append(workdir_row)

        self.args_entry = Gtk.Entry(
            placeholder_text=t("gui.launcher_entries.args_placeholder"), hexpand=True, valign=Gtk.Align.CENTER
        )
        self.append(self.args_entry)

        separator = Gtk.Separator(orientation=Gtk.Orientation.HORIZONTAL)
        separator.set_margin_top(4)
        self.append(separator)

    def _refresh_exe_display(self):
        # Simplify the display to SamMax103.exe (file name only) when the executable is in
        # the same folder as the displayed working directory, to avoid repeating a long
        # identical path. Compared in whichever form is available (Windows if "_exe_win" is
        # known, Linux otherwise), never mixing both.
        if self._exe_win:
            workdir_text = self.workdir_entry.get_text().strip()
            same_dir = self._workdir_form == "win" and _ntpath_dirname_eq(self._exe_win, workdir_text)
            self.exe_entry.set_text(_ntpath_basename(self._exe_win) if same_dir else self._exe_win)
        elif self._exe_linux:
            workdir_text = self.workdir_entry.get_text().strip()
            same_dir = self._workdir_form == "linux" and os.path.dirname(self._exe_linux) == workdir_text
            self.exe_entry.set_text(os.path.basename(self._exe_linux) if same_dir else self._exe_linux)
        else:
            self.exe_entry.set_text("")

    def _browse_exe(self):
        def got(paths):
            if paths:
                self._set_exe_linux(paths[0])

        pick_file(self._window, t("gui.launcher_entries.exe_dialog_title"), got,
                  initial_folder=self._get_drive_c())

    def _set_exe_linux(self, exe_path: str):
        # Chosen via the native picker -- always a LINUX path; its Windows form is unknown
        # without rerunning "winepath" (see the class docstring): left to
        # "lib/zgl-launcher-entries.sh" at "set" time, never recomputed here.
        self._exe_win = ""
        self._exe_linux = exe_path
        if self._workdir_follows_exe:
            self._updating_workdir = True
            self.workdir_entry.set_text(os.path.dirname(exe_path))
            self._updating_workdir = False
            self._workdir_form = "linux"
        self._refresh_exe_display()

    def _browse_workdir(self):
        def got(path):
            if path:
                self._updating_workdir = True
                self.workdir_entry.set_text(path)
                self._updating_workdir = False
                self._workdir_follows_exe = False
                self._workdir_form = "linux"
                self._refresh_exe_display()

        pick_folder(self._window, t("gui.launcher_entries.workdir_dialog_title"), got,
                    initial_folder=self._get_drive_c())

    def _on_workdir_changed(self, *_):
        if self._updating_workdir:
            return
        # Manual edit -- detaches auto-tracking from the executable but does NOT change
        # "_workdir_form": hand-edited text stays in the form shown before the edit (mostly
        # Windows, Linux only right after a pick via the folder picker) -- see the class
        # docstring.
        self._workdir_follows_exe = False
        self._refresh_exe_display()

    def entry_payload(self) -> dict:
        workdir_text = self.workdir_entry.get_text().strip()
        return {
            "label": self.label_entry.get_text().strip(),
            "args": self.args_entry.get_text().strip(),
            "exe_win": self._exe_win,
            "exe_linux": self._exe_linux,
            "workdir_win": workdir_text if self._workdir_form == "win" else "",
            "workdir_linux": workdir_text if self._workdir_form == "linux" else "",
        }

    def load_entry(self, entry: dict):
        label = str(entry.get("label") or "")
        args = str(entry.get("args") or "")
        self._exe_win = str(entry.get("exe_win") or "")
        self._exe_linux = str(entry.get("exe_linux") or "")
        workdir_win = str(entry.get("workdir_win") or "")
        workdir_linux = str(entry.get("workdir_linux") or "")
        self.label_entry.set_text(label)
        self._updating_workdir = True
        # Prefer the Windows form (as stored in the YAML, readable); fall back to the Linux
        # form only if it is the only one known (should not happen,
        # "lib/zgl-launcher-entries.sh" always provides "workdir_win").
        if workdir_win:
            self.workdir_entry.set_text(workdir_win)
            self._workdir_form = "win"
        else:
            self.workdir_entry.set_text(workdir_linux)
            self._workdir_form = "linux"
        self._updating_workdir = False
        self.args_entry.set_text(args)
        self._refresh_exe_display()
        # An entry loaded from the YAML already has its own working directory (possibly
        # different from the executable's folder, e.g. chosen by hand earlier) -- NEVER
        # overwrite it on the next executable change until the user picks a new one via the
        # picker.
        self._workdir_follows_exe = False

    def reset(self):
        self.label_entry.set_text("")
        self._exe_win = ""
        self._exe_linux = ""
        self.exe_entry.set_text("")
        self._updating_workdir = True
        self.workdir_entry.set_text("")
        self._updating_workdir = False
        self.args_entry.set_text("")
        self._workdir_follows_exe = True
        self._workdir_form = "win"


def _ntpath_basename(win_path: str) -> str:
    return win_path.rstrip("\\/").rsplit("\\")[-1].rsplit("/")[-1]


def _ntpath_dirname_eq(win_path: str, candidate: str) -> bool:
    # Windows folder comparison: case-insensitive (like the Windows filesystem itself) and
    # ignoring a trailing "\" -- never depending on the Linux host filesystem, which IS
    # case-sensitive.
    trimmed = win_path.rstrip("\\/")
    parent = trimmed.rsplit("\\", 1)[0] if "\\" in trimmed else trimmed.rsplit("/", 1)[0]
    return parent.strip().casefold() == candidate.rstrip("\\/").strip().casefold()


def pick_file(window, title: str, callback, filters: list[tuple[str, list[str]]] | None = None,
              multiple: bool = False, initial_folder: str | None = None):
    """Open a native Gtk.FileDialog (never "zenity --file-selection"). callback receives a
    list of paths (empty if cancelled). "initial_folder" (optional): starting folder of the
    picker -- silently ignored if empty or nonexistent (e.g. the "drive_c" of a prefix not
    yet created), never blocking."""
    dialog = Gtk.FileDialog(title=title)
    if initial_folder and os.path.isdir(initial_folder):
        dialog.set_initial_folder(Gio.File.new_for_path(initial_folder))
    if filters:
        store = Gio.ListStore.new(Gtk.FileFilter)
        for label, patterns in filters:
            f = Gtk.FileFilter()
            f.set_name(label)
            for p in patterns:
                f.add_pattern(p)
            store.append(f)
        dialog.set_filters(store)

    def on_result(dlg, res):
        try:
            if multiple:
                files = dlg.open_multiple_finish(res)
                paths = [files.get_item(i).get_path() for i in range(files.get_n_items())]
            else:
                f = dlg.open_finish(res)
                paths = [f.get_path()] if f else []
        except GLib.Error:
            paths = []
        callback(paths)

    if multiple:
        dialog.open_multiple(window, None, on_result)
    else:
        dialog.open(window, None, on_result)


def _wrapping_text_factory() -> Gtk.SignalListItemFactory:
    """Factory for Adw.ComboRow (RunnerCombo) that shows the full text, on several lines if
    needed, instead of truncating with "..." -- both the displayed value (closed row) and
    each dropdown entry, since "factory" serves both by default (per the Adw.ComboRow docs,
    "list_factory" falls back to "factory" only if not set separately -- never the case here).
    Runner names (often long, e.g. "lutris-GE-Proton8-26-x86_64") would otherwise be cut off
    by the ellipsis."""
    factory = Gtk.SignalListItemFactory()

    def on_setup(_factory, list_item):
        label = Gtk.Label(xalign=0, wrap=True, wrap_mode=Pango.WrapMode.WORD_CHAR)
        list_item.set_child(label)

    def on_bind(_factory, list_item):
        list_item.get_child().set_label(list_item.get_item().get_string())

    factory.connect("setup", on_setup)
    factory.connect("bind", on_bind)
    return factory


def pick_folder(window, title: str, callback, initial_folder: str | None = None):
    dialog = Gtk.FileDialog(title=title)
    if initial_folder and os.path.isdir(initial_folder):
        dialog.set_initial_folder(Gio.File.new_for_path(initial_folder))

    def on_result(dlg, res):
        try:
            f = dlg.select_folder_finish(res)
            path = f.get_path() if f else None
        except GLib.Error:
            path = None
        callback(path)

    dialog.select_folder(window, None, on_result)


def _default_desktop_dir() -> str:
    """Python version of zgu_get_desktop_dir() (lib/zgu-desktop-utils.sh): xdg-user-dir
    DESKTOP first (the only reliable source whatever the system language), then fall back
    to ~/Bureau, then ~/Desktop, and finally $HOME if neither exists on disk. This only
    pre-fills the GUI field; the CLI makes the same decision independently if the field is
    unchanged."""
    home = GLib.get_home_dir()
    try:
        result = subprocess.run(["xdg-user-dir", "DESKTOP"], capture_output=True,
                                 text=True, timeout=2)
        xdg_desktop = result.stdout.strip()
        # xdg-user-dir returns $HOME as is when XDG_DESKTOP_DIR is not configured: not a real
        # answer in that case (same remark as on the bash side).
        if xdg_desktop and xdg_desktop != home:
            return xdg_desktop
    except (OSError, subprocess.SubprocessError):
        pass

    for name in ("Bureau", "Desktop"):
        candidate = os.path.join(home, name)
        if os.path.isdir(candidate):
            return candidate
    return home


def _resolve_default_runner() -> str:
    """Python version of zgu_get_default_runner() (lib/zgu-lutris-utils.sh): reads the
    "version:" key of runners/wine.yml (Flatpak or native package), or falls back to
    "proton-cachyos-x86_64" if not found. Used by the "create an empty prefix" page to show
    WHICH runner "(Lutris default)" actually means. A plain local file read (never a bin/lpm
    call), so no impact on GUI response time even when creating several prefixes at once."""
    home = GLib.get_home_dir()
    for runners_path in (
        os.path.join(home, ".local/share/lutris/runners/wine.yml"),
        os.path.join(home, ".var/app/net.lutris.Lutris/data/lutris/runners/wine.yml"),
        os.path.join(home, ".config/lutris/runners/wine.yml"),
    ):
        try:
            with open(runners_path, "r", encoding="utf-8") as f:
                for line in f:
                    m = re.match(r"^\s*version:\s*(.+?)\s*$", line)
                    if m:
                        value = m.group(1).strip("'\"")
                        if value:
                            return value
        except OSError:
            continue
    return "proton-cachyos-x86_64"


class DesktopPathRow(Adw.EntryRow):
    """Field pre-filled with the detected desktop shortcut location (see
    _default_desktop_dir), editable directly or via the "Browse" button -- a single
    pre-filled field that can be changed, not a choice between "default" and "custom"
    presented as two separate options."""

    def __init__(self, window):
        super().__init__(title=t("gui.common.desktop_path_title"))
        self._window = window
        browse_btn = Gtk.Button(icon_name="folder-open-symbolic", valign=Gtk.Align.CENTER,
                                 tooltip_text=t("gui.common.desktop_path_browse_tooltip"))
        browse_btn.connect("clicked", lambda *_: self._browse())
        self.add_suffix(browse_btn)
        self.reset()

    def reset(self):
        self.set_text(_default_desktop_dir())

    def _browse(self):
        def got(path):
            if path:
                self.set_text(path)

        pick_folder(self._window, t("gui.common.desktop_path_browse_title"), got)

    def value(self) -> str:
        return self.get_text().strip()


def sibling_files(chosen_paths: list[str], extension: str) -> list[str]:
    """All files with the given extension in the folder of the first chosen file (sorted),
    so they can be added at once with "check all" without going back to the native picker.
    Unreadable folder or no match: falls back to the chosen files."""
    directory = os.path.dirname(chosen_paths[0])
    try:
        found = sorted(
            os.path.join(directory, name)
            for name in os.listdir(directory)
            if name.lower().endswith(extension)
        )
    except OSError:
        found = []
    return found or list(chosen_paths)


def add_compression_rows(page):
    """Compression level (1-22, default 3) and "hash" checkbox of the packing pages.
    Returns (level_row, hash_row)."""
    level_row = Adw.SpinRow.new_with_range(1, 22, 1)
    level_row.set_title(t("gui.pack.compression_title"))
    level_row.set_value(3)
    page.add_row(level_row)
    hash_row = Adw.SwitchRow(title=t("gui.pack.hash_title"))
    page.add_row(hash_row)
    return level_row, hash_row


def add_shortcut_rows(page, window):
    """Shortcut settings shared by install and the "Shortcut" page: menu shortcut (on by
    default, the convention for installed software), file shortcut (off by default: a page
    processing several games at once would otherwise create several unrequested files), its
    path (visible only if the file shortcut is on) and the lpm loading screen (on by
    default; only effective through a shortcut created by lpm, so hidden when menu and file
    are both unchecked).
    Returns (menu_row, desktop_row, desktop_path_row, loadingscreen_row)."""
    menu_row = Adw.SwitchRow(title=t("gui.install.menu_shortcut_title"), active=True)
    page.add_row(menu_row)
    desktop_row = Adw.SwitchRow(title=t("gui.install.desktop_shortcut_title"), active=False)
    page.add_row(desktop_row)

    desktop_path_row = DesktopPathRow(window)
    page.add_row(desktop_path_row)

    def update_path_visibility(*_):
        desktop_path_row.set_visible(desktop_row.get_active())

    desktop_row.connect("notify::active", update_path_visibility)
    update_path_visibility()

    loadingscreen_row = Adw.SwitchRow(title=t("gui.shortcut.loadingscreen_title"),
                                      subtitle=t("gui.shortcut.loadingscreen_subtitle"),
                                      active=True)
    page.add_row(loadingscreen_row)

    def update_loadingscreen_visibility(*_):
        loadingscreen_row.set_visible(menu_row.get_active() or desktop_row.get_active())

    menu_row.connect("notify::active", update_loadingscreen_visibility)
    desktop_row.connect("notify::active", update_loadingscreen_visibility)
    update_loadingscreen_visibility()

    return menu_row, desktop_row, desktop_path_row, loadingscreen_row


def ask_keep_or_delete(window, heading: str, body: str, on_delete):
    """Dialog offered after a batch is cancelled (install, export): keep what was already
    done (default choice, including when closing the window: deletion is irreversible) or
    delete it -- on_delete() is called only in the latter case.
    i18n.t does not convert the literal "\\n" of the .lang files (only the bash loader
    does): explicit conversion here."""
    dialog = Adw.AlertDialog(heading=heading, body=body.replace("\\n", "\n"))
    dialog.add_response("keep", t("gui.install.cancel_keep"))
    dialog.add_response("delete", t("gui.install.cancel_delete"))
    dialog.set_response_appearance("delete", Adw.ResponseAppearance.DESTRUCTIVE)
    dialog.set_default_response("keep")
    dialog.set_close_response("keep")
    dialog.connect("response", lambda _dlg, response: on_delete() if response == "delete" else None)
    dialog.present(window)
