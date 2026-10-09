"""Small helpers shared by the interface modules."""

import json

import gi

gi.require_version("Gtk", "4.0")
gi.require_version("Adw", "1")
from gi.repository import GLib  # noqa: E402


def _run_on_main(fn, *args):
    GLib.idle_add(lambda: (fn(*args), False)[1])


def _escape_markup(text: str | None) -> str | None:
    """Titles/subtitles of Adw.ActionRow (and similar) are parsed as Pango markup: an
    unescaped "&" (or "<") silently breaks rendering (empty title, e.g. "Sam & Max..."). Use
    on any dynamic text displayed this way (game, runner or file names), which we do not
    control."""
    if text is None:
        return None
    return GLib.markup_escape_text(text, -1)


def json_result(result) -> dict:
    """JSON output (stdout) of a successful lpm command; {} if the command failed or the
    output is not valid JSON."""
    if result.returncode != 0:
        return {}
    try:
        return json.loads(result.stdout)
    except (ValueError, TypeError):
        return {}
