#!/usr/bin/env python3
"""
GTK4/Libadwaita graphical interface for ludis -- entry point.

Principles:
  1. The GUI implements NO business logic: each screen gathers the user's choices with
     native GTK4 widgets, then runs "bin/ludis <command> <args>" in the background -- the same
     lib/ scripts as from a terminal.
  2. The desktop theme (light/dark, accent color) is followed natively by Libadwaita
     (AdwStyleManager). A CSS bridge to third-party GTK3 theme colors is not possible on
     GTK < 4.16 (the required custom CSS properties are not recognized there).
  3. Every command runs in a separate thread (backend.run_ludis_async): the GTK main thread
     never waits for a script to finish.
  4. The full output (stdout/stderr) of each command goes to
     ~/.local/share/ludis/ludis-gui.log (size-based rotation), never live in the window: only a
     toast (success/failure) is shown; see CommandPage.run_command.

Layout (flat files in gui/, all imported from this directory):
  ludis_gtk.py       this file: entry point (run by bin/ludis-gui)
  app.py           Adw.Application (.zgp/.zgr file opening), stylesheet, main()
  mainwindow.py    main window: sidebar, navigation, page construction
  pages.py         CommandPages = assembly of pages_*.py (one page_<command>() method per screen)
  pages_*.py       the screens, grouped by theme (home, game lifecycle, media, runners, system, VSync)
  commandpage.py   generic command page: form, launching bin/ludis, line protocol
  widgets_*.py     reusable selectors and form rows
  sgdb.py          SteamGridDB windows (titles, images)
  guilog.py, updatecheck.py, refresh.py, util.py, backend.py, i18n.py   shared services

Requirements: Python 3.11+, PyGObject, GTK4 >= 4.10 (Gtk.FileDialog), Libadwaita >= 1.5
(Adw.AlertDialog, NavigationSplitView).
"""

import os
import sys

# The GUI modules are flat files next to this one (gui/*.py): make sure they are
# importable regardless of the directory the script is launched from.
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

# Folders of the former name ("lpm"): moved to "ludis" once (bin/ludis does the same for the CLI).
for _base in (os.environ.get("XDG_CONFIG_HOME") or os.path.expanduser("~/.config"),
              os.path.expanduser("~/.local/share"),
              os.environ.get("XDG_CACHE_HOME") or os.path.expanduser("~/.cache")):
    _old, _new = os.path.join(_base, "lpm"), os.path.join(_base, "ludis")
    try:
        if os.path.isdir(_old) and not os.path.islink(_old) and not os.path.lexists(_new):
            os.rename(_old, _new)
    except OSError:
        pass

from app import APP_ID, LudisApp, main  # noqa: E402,F401
from mainwindow import MainWindow  # noqa: E402,F401

if __name__ == "__main__":
    sys.exit(main())
