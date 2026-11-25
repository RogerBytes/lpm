"""One-time offer, at GUI startup, to let the in-game Ludis menu be opened from the keyboard.

The keyboard hotkey (lib/zgu-gamepad-exit-watcher.py) reads /dev/input/event*, the only way that
works on X11 AND Wayland (Wayland forbids global key capture). That needs the user to be in the
"input" group. This module asks ONCE per start (until the user answers "don't ask again") and,
on approval, runs "pkexec usermod -aG input <user>" (the system's own password dialog; Ludis never
sees the password). The change applies after the next login.
"""

from __future__ import annotations

import getpass
import glob
import grp
import os
import shutil

import gi

gi.require_version("Adw", "1")
from gi.repository import Adw, Gio, GLib  # noqa: E402

from i18n import t  # noqa: E402

FLAG_NAME = "input-access"  # <XDG config>/ludis/input-access = "never" once declined for good


def _flag_path() -> str:
    base = os.environ.get("XDG_CONFIG_HOME") or os.path.join(os.path.expanduser("~"), ".config")
    return os.path.join(base, "ludis", FLAG_NAME)


def _declined() -> bool:
    try:
        with open(_flag_path(), encoding="utf-8") as f:
            return f.read().strip() == "never"
    except OSError:
        return False


def _remember_never() -> None:
    try:
        os.makedirs(os.path.dirname(_flag_path()), exist_ok=True)
        with open(_flag_path(), "w", encoding="utf-8") as f:
            f.write("never\n")
    except OSError:
        pass


def keyboard_access_ok() -> bool:
    """True when this user can already read the keyboards (or there is nothing to read)."""
    events = glob.glob("/dev/input/event*")
    if not events:
        return True  # no /dev/input here (container, CI): nothing to offer
    if any(os.access(path, os.R_OK) for path in events):
        return True
    try:
        return grp.getgrnam("input").gr_gid in os.getgroups()
    except KeyError:
        return False


def needs_offer() -> bool:
    if _declined() or keyboard_access_ok():
        return False
    if not shutil.which("pkexec") or not (shutil.which("usermod") or os.path.exists("/usr/sbin/usermod")):
        return False
    try:
        grp.getgrnam("input")
    except KeyError:
        return False
    return True


def maybe_offer(window) -> bool:
    """GLib idle callback: shows the offer if needed. Returns False (run once)."""
    try:
        if not needs_offer():
            return False
    except Exception:
        return False
    dialog = Adw.AlertDialog(heading=t("gui.inputaccess.heading"), body=t("gui.inputaccess.body"))
    dialog.add_response("later", t("gui.inputaccess.later"))
    dialog.add_response("never", t("gui.inputaccess.never"))
    dialog.add_response("allow", t("gui.inputaccess.allow"))
    dialog.set_response_appearance("allow", Adw.ResponseAppearance.SUGGESTED)
    dialog.set_default_response("later")
    dialog.set_close_response("later")
    dialog.connect("response", lambda _d, r: _on_response(window, r))
    dialog.present(window)
    return False


def _on_response(window, response: str) -> None:
    if response == "never":
        _remember_never()
    elif response == "allow":
        _enable(window)


def _enable(window) -> None:
    usermod = shutil.which("usermod") or "/usr/sbin/usermod"
    try:
        proc = Gio.Subprocess.new(
            ["pkexec", usermod, "-aG", "input", getpass.getuser()],
            Gio.SubprocessFlags.STDERR_SILENCE | Gio.SubprocessFlags.STDOUT_SILENCE,
        )
    except GLib.Error:
        _result(window, False)
        return

    def done(p, res):
        try:
            p.wait_check_finish(res)
            ok = True
        except GLib.Error:
            ok = False
        _result(window, ok)

    proc.wait_check_async(None, done)


def _result(window, ok: bool) -> None:
    dialog = Adw.AlertDialog(
        heading=t("gui.inputaccess.done_heading" if ok else "gui.inputaccess.failed_heading"),
        body=t("gui.inputaccess.done_body" if ok else "gui.inputaccess.failed_body"),
    )
    dialog.add_response("ok", "OK")
    dialog.present(window)
