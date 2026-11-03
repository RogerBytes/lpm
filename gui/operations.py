"""The ONE running operation (0 or 1, never more), shared by every page.

An operation is anything that shows a progress window (install, uninstall, export, runner,
check...). While one runs, every other page refuses to start another one, and a second
.zgp opened from the file manager does not replace anything: it is told to wait.
"""

import shutil
import subprocess

import gi

gi.require_version("Adw", "1")
from gi.repository import Adw  # noqa: E402

from i18n import t

# The running operation object (it has a "progress_window" attribute when it shows a ProgressWindow), or None.
_current = [None]

# "lpm <command>" whose own script already sends the end-of-run desktop notification, so the
# GUI must not send a second one (see notify-send in lib/zgp-game-installer.sh and
# lib/zgc-wine-killer.sh).
COMMANDS_THAT_NOTIFY = ("install", "killwine")


# "stop" / "undo" while an on_cancelled handler runs (the choice made in the progress window,
# see widgets_rows.ask_keep_or_delete), else None.
cancel_choice = [None]


def is_busy() -> bool:
    return _current[0] is not None


def begin(operation) -> None:
    _current[0] = operation


def end(operation) -> None:
    if _current[0] is operation:
        _current[0] = None


def progress_window():
    """Progress window of the running operation, or None."""
    return getattr(_current[0], "progress_window", None)


def notify(title: str, body: str) -> None:
    """Plain desktop notification (notify-send), the same one the install script sends. Silent
    when notify-send is missing: it is a convenience, never a reason to fail."""
    if shutil.which("notify-send") is None:
        return
    try:
        subprocess.Popen(["notify-send", title, body], stdout=subprocess.DEVNULL,
                         stderr=subprocess.DEVNULL, start_new_session=True)
    except OSError:
        pass


def show_busy_dialog(parent):
    """Told to wait: an operation is already running (0 or 1 at a time)."""
    dialog = Adw.AlertDialog(heading=t("gui.op.busy_heading"), body=t("gui.op.already_running"))
    dialog.add_response("ok", t("gui.op.error_close"))
    dialog.present(parent)
