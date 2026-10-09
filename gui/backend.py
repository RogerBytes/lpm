"""
Bridge to lpm's CLI scripts (lib/*.sh), never going through Zenity.

Each function builds an argv for "bin/lpm <command> ... <CLI flags>", exactly as if typed
in a terminal: the GUI is only a layer on top of the CLI scripts, not a duplicate of their
logic.

Every subprocess is launched with stdin=DEVNULL. Some lib/ scripts still have a fallback
"read -r -p" for a very specific interactive case with no CLI argument equivalent (e.g.
disambiguating an ambiguous game name on SteamGridDB); with stdin closed, that "read" gets
EOF and returns "", which those scripts treat as a clean cancellation of that step. No
screen should ever block waiting for an answer that will never come.
"""

from __future__ import annotations

import os
import re
import shutil
import subprocess
import threading
import unicodedata
import uuid
from dataclasses import dataclass
from typing import Callable


def _resolve_bin_lpm() -> str:
    """Resolve the path of "bin/lpm". In a source checkout, gui/ and bin/ are siblings; after
    install.sh, "bin/lpm" goes to /usr/local/bin/lpm while gui/ goes to
    /usr/local/lib/lpm/gui, so they are no longer siblings. Try the local sibling first,
    then fall back to PATH."""
    sibling = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "bin", "lpm")
    if os.path.isfile(sibling):
        return sibling
    return shutil.which("lpm") or "lpm"


BIN_LPM = _resolve_bin_lpm()


def get_lpm_version() -> str:
    """Version string shown on the home page, read via "bin/lpm --version" so that
    LPM_VERSION (see bin/lpm) stays the single source of truth.

    Called once (page_home is cached by show_page, see MainWindow), before the GTK loop
    starts, so the blocking call does not freeze a visible UI. "--version" is handled by
    bin/lpm right after loading the language loader, so it is almost instant.

    Best-effort: returns "?" if the command fails or the format is unexpected, so a
    secondary display never crashes the home page."""
    try:
        result = run_lpm(["--version"])
        if result.returncode != 0:
            return "?"
        # Expected output: "lpm v0.9.3\n"
        match = re.search(r"\bv?\d+\.\d+\.\d+\b", result.stdout)
        return match.group(0) if match else "?"
    except OSError:
        return "?"


def slugify_preview(name: str) -> str:
    """Reproduce zgp_slugify (lib/zgp-prefix-creator.sh, which itself mirrors Lutris'
    lutris/util/strings.py::slugify): NFD normalization + ASCII encoding (strips accents),
    lowercase, remove everything except letters/digits/spaces/hyphens, collapse runs of
    spaces/hyphens into one hyphen. Falls back to a deterministic UUID5 if the result is
    empty (name entirely in non-Latin characters), like zgp_slugify.

    Used ONLY for a live preview while typing (see PrefixEntryRow in
    gui/widgets_rows.py); computed in pure Python because relaunching "bin/lpm" on each
    keystroke is too slow. Deduplication against existing Lutris slugs (pga.db) or the rest
    of the batch is done by bin/lpm at actual creation (see zgp-prefix-creator.sh), so the
    real slug may get a "-2", "-3"... suffix; this preview shows the base slug only.
    """
    v = unicodedata.normalize("NFD", name).encode("ascii", "ignore").decode("utf-8")
    v = re.sub(r"[^\w\s-]", "", v).strip().lower()
    slug = re.sub(r"[-\s]+", "-", v)
    if not slug:
        slug = str(uuid.uuid5(uuid.NAMESPACE_URL, name))
    return slug


@dataclass
class CommandResult:
    returncode: int
    stdout: str
    stderr: str


def run_lpm(
    args: list[str],
    on_line: Callable[[str], None] | None = None,
    on_proc: Callable[[subprocess.Popen], None] | None = None,
    new_session: bool = False,
) -> CommandResult:
    """Run "bin/lpm <args>" synchronously. Call only from a background thread, never from
    the GTK main thread (the UI would freeze for the duration of the command).

    "new_session": run the command in its own process group, so it can be interrupted as a
    whole with os.killpg without ever targeting the GUI itself.
    "on_proc": called with the Popen right after launch (to keep a handle)."""
    proc = subprocess.Popen(
        [BIN_LPM, *args],
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        bufsize=1,
        start_new_session=new_session,
    )
    if on_proc is not None:
        on_proc(proc)

    out_lines: list[str] = []

    if on_line is not None and proc.stdout is not None:
        for line in proc.stdout:
            out_lines.append(line)
            on_line(line.rstrip("\n"))
        stdout = "".join(out_lines)
        _, stderr = proc.communicate()
    else:
        stdout, stderr = proc.communicate()

    return CommandResult(returncode=proc.returncode, stdout=stdout, stderr=stderr)


def run_lpm_async(
    args: list[str],
    on_line: Callable[[str], None] | None = None,
    on_done: Callable[[CommandResult], None] | None = None,
    on_proc: Callable[[subprocess.Popen], None] | None = None,
    new_session: bool = False,
) -> threading.Thread:
    """Non-blocking variant: runs run_lpm() in a separate thread. on_line/on_done are called
    from that background thread; the caller must re-post to the GTK main thread via
    GLib.idle_add before touching any widget."""

    def _worker():
        result = run_lpm(args, on_line=on_line, on_proc=on_proc, new_session=new_session)
        if on_done is not None:
            on_done(result)

    thread = threading.Thread(target=_worker, daemon=True)
    thread.start()
    return thread


# --- Listers: parsing the text already produced by lib/zg*-lister.sh ---

_SLUG_NAME_RE = re.compile(r"^(\S+)\s+(.*)$")


@dataclass
class GameEntry:
    slug: str
    name: str


@dataclass
class IsolableEntry:
    slug: str
    name: str
    store_label: str


def list_games() -> list[GameEntry]:
    result = run_lpm(["list"])
    entries: list[GameEntry] = []
    for line in result.stdout.splitlines():
        m = _SLUG_NAME_RE.match(line.strip())
        if m:
            entries.append(GameEntry(slug=m.group(1), name=m.group(2)))
    return entries


def list_runners() -> list[str]:
    result = run_lpm(["list-runner"])
    return [line.strip() for line in result.stdout.splitlines() if line.strip()]


def list_remote_runners() -> list[str]:
    result = run_lpm(["list-remote-runners"])
    return [line.strip() for line in result.stdout.splitlines() if line.strip()]


def list_isolable() -> list[IsolableEntry]:
    result = run_lpm(["list-isolable"])
    entries: list[IsolableEntry] = []
    for line in result.stdout.splitlines():
        parts = re.split(r"\s{2,}", line.strip())
        if len(parts) >= 3:
            entries.append(IsolableEntry(slug=parts[0], name=parts[1], store_label=parts[2]))
    return entries
