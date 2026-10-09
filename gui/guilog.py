"""UI log (lpm-gui.log): writing, reading, filtering, dialog."""

import datetime
import logging
import logging.handlers
import os
import re

import gi

gi.require_version("Gtk", "4.0")
gi.require_version("Adw", "1")
from gi.repository import Adw, GLib, Gtk  # noqa: E402

from i18n import t


# ---------------------------------------------------------------------------------------
# File log: full raw stdout/stderr of each command launched from the GUI, with rotation;
# never shown live in the UI (see CommandPage below). Deliberately separate from
# ~/.local/share/lpm/lpm.log: that one (written by lib/*.sh via zgu_log, see
# lib/zgu-log-utils.sh) is a line-per-event log of business decisions (4 columns) whose
# format "lpm log --grep" parses, and mixing raw output into it would break that. Rotation
# is by size (standard RotatingFileHandler style) rather than by line count like lpm.log,
# since raw output has a different volume profile.
_LOG_DIR = os.path.join(os.path.expanduser("~"), ".local", "share", "lpm")


_GUI_LOGGER = logging.getLogger("lpm.gui.commands")


def _init_gui_logger():
    if _GUI_LOGGER.handlers:
        return
    try:
        os.makedirs(_LOG_DIR, exist_ok=True)
        handler = logging.handlers.RotatingFileHandler(
            os.path.join(_LOG_DIR, "lpm-gui.log"),
            maxBytes=1_000_000,
            backupCount=3,
            encoding="utf-8",
        )
        handler.setFormatter(logging.Formatter("%(asctime)s %(message)s"))
        _GUI_LOGGER.addHandler(handler)
    except OSError:
        # Best-effort, like zgu_log on the bash side: a log write error (disk full,
        # read-only directory...) must never make the GUI itself fail.
        pass


_init_gui_logger()


# ---------------------------------------------------------------------------------------
# --- Reading/filtering the two logs ("Logs" page, see page_logs) ---
#   lpm.log     : "YYYY-MM-DDTHH:MM:SS+ZZZZ<TAB>command<TAB>status<TAB>detail" (written by lib/*.sh)
#   lpm-gui.log : "YYYY-MM-DD HH:MM:SS,mmm <message>" (local time, written by _GUI_LOGGER), plus
#                 its rotated files lpm-gui.log.1..3 (newest to oldest).
# A line without a recognized timestamp (continuation of multi-line output) is attached to
# the previous entry: it is kept or dropped together with it.
_LPM_LOG_TS_RE = re.compile(r"^(\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d[+-]\d{4})\t")


_GUI_LOG_TS_RE = re.compile(r"^(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d),\d+ ")


def _log_files(kind: str) -> list[str]:
    """Files of a log, oldest to newest."""
    if kind == "lpm":
        return [os.path.join(_LOG_DIR, "lpm.log")]
    base = os.path.join(_LOG_DIR, "lpm-gui.log")
    return [f"{base}.3", f"{base}.2", f"{base}.1", base]


def _read_log_lines(kind: str, cutoff: "datetime.datetime | None", query: str) -> list[str]:
    """Lines of log "kind" ("lpm" or "gui") newer than "cutoff" (None = all), containing
    "query" (case-insensitive, empty = all). Reading/parsing happens off the GTK thread."""
    ts_re = _LPM_LOG_TS_RE if kind == "lpm" else _GUI_LOG_TS_RE
    needle = query.lower()
    out: list[str] = []
    keep = True
    for path in _log_files(kind):
        try:
            with open(path, "r", encoding="utf-8", errors="replace") as f:
                for raw in f:
                    line = raw.rstrip("\n")
                    m = ts_re.match(line)
                    if m and cutoff is not None:
                        try:
                            if kind == "lpm":
                                ts = datetime.datetime.strptime(m.group(1), "%Y-%m-%dT%H:%M:%S%z")
                                keep = ts >= cutoff
                            else:
                                ts = datetime.datetime.strptime(m.group(1), "%Y-%m-%d %H:%M:%S")
                                keep = ts >= cutoff.replace(tzinfo=None)
                        except ValueError:
                            keep = True
                    elif m:
                        keep = True
                    if keep and (not needle or needle in line.lower()):
                        out.append(line)
        except OSError:
            continue
    return out


def _clear_log_files(kind: str):
    """Clear a log. The current file is TRUNCATED (not deleted): the GUI logger keeps its
    descriptor open, so an unlink would make it write to a ghost file."""
    for path in _log_files(kind):
        try:
            if path == _log_files(kind)[-1]:
                open(path, "w").close()
            else:
                os.remove(path)
        except OSError:
            pass


def _read_gui_log_tail(max_lines: int = 300) -> str:
    """Last lines of lpm-gui.log (see _init_gui_logger), for display in the GUI."""
    try:
        with open(os.path.join(_LOG_DIR, "lpm-gui.log"), "r", encoding="utf-8", errors="replace") as f:
            lines = f.readlines()
    except OSError:
        return ""
    return "".join(lines[-max_lines:])


def show_log_dialog(parent: Gtk.Widget | None):
    """Window showing the end of the command log (lpm-gui.log), selectable and copyable
    text -- opened from the "View log" button of the failure message."""
    dialog = Adw.Dialog()
    dialog.set_title(t("gui.common.log_dialog_title"))
    dialog.set_content_width(900)
    dialog.set_content_height(600)
    text_view = Gtk.TextView(editable=False, cursor_visible=False, monospace=True,
                             wrap_mode=Gtk.WrapMode.WORD_CHAR, top_margin=8, bottom_margin=8,
                             left_margin=10, right_margin=10)
    buffer = text_view.get_buffer()
    buffer.set_text(_read_gui_log_tail() or t("gui.common.log_empty"))
    scroller = Gtk.ScrolledWindow(vexpand=True, hexpand=True)
    scroller.set_child(text_view)
    toolbar = Adw.ToolbarView()
    toolbar.add_top_bar(Adw.HeaderBar())
    toolbar.set_content(scroller)
    dialog.set_child(toolbar)
    # Scroll to the bottom (the most recent lines are at the end).
    GLib.idle_add(lambda: (text_view.scroll_to_iter(buffer.get_end_iter(), 0.0, False, 0.0, 0.0), False)[1])
    dialog.present(parent)
