"""Registry of game/runner selectors and shared refresh."""

import threading

import gi

gi.require_version("Gtk", "4.0")
gi.require_version("Adw", "1")
from gi.repository import GLib  # noqa: E402

import backend


# --- Registry of already-built game/runner selectors, for global refresh ---
# (see CommandPage.run_command, "refresh" parameter). A built page normally stays cached
# for good (see MainWindow._built_pages); without this, its game/runner list would stay
# frozen as of its first opening, even after ANOTHER page installs or uninstalls something.
# Plain list (no weakref): the number of built pages is bounded, so no real memory leak.
_GAME_LIST_WIDGETS: list = []


_RUNNER_LIST_WIDGETS: list = []


def _refresh_game_lists():
    for widget in _GAME_LIST_WIDGETS:
        widget.refresh()


def _refresh_runner_lists():
    for widget in _RUNNER_LIST_WIDGETS:
        widget.refresh()


# --- Shared game/runner refresh (avoids N "bin/lpm list*" subprocesses) ---
#
# backend.run_lpm() must not be called from the GTK main thread (it would freeze the UI).
# GameMultiSelect/SingleGameSelect/RunnerCombo (and page_uninstall_runner's hand-made
# listbox) used to call backend.list_games()/list_runners() directly from refresh() on the
# main thread, and MainWindow._on_back_to_categories() (the "back" button) calls them ALL at
# once for every built page (see CommandPage.reset_selection): one subprocess PER visited
# page, a 1-2 second freeze.
#
# _make_coalesced_refresher(fetch_fn) builds a shared "refresher": fetch_fn()
# (backend.list_games or list_runners) runs in a background thread, NEVER on the main
# thread. Several close requests (e.g. the N pages on "back") trigger a SINGLE subprocess;
# requests arriving while one is in flight are queued and receive the same result. Each
# registered callback is called on the main thread (GLib.idle_add), never from the
# background thread.
def _make_coalesced_refresher(fetch_fn):
    state = {"inflight": False, "waiters": []}

    def request(callback):
        state["waiters"].append(callback)
        if state["inflight"]:
            return
        state["inflight"] = True

        def _worker():
            result = fetch_fn()

            def _apply():
                state["inflight"] = False
                waiters, state["waiters"] = state["waiters"], []
                for cb in waiters:
                    cb(result)
                return False

            GLib.idle_add(_apply)

        threading.Thread(target=_worker, daemon=True).start()

    return request


_request_games_refresh = _make_coalesced_refresher(lambda: backend.list_games())


_request_runners_refresh = _make_coalesced_refresher(lambda: backend.list_runners())


class _RefreshCallback:
    """Minimal wrapper to register in _GAME_LIST_WIDGETS/_RUNNER_LIST_WIDGETS a hand-made
    refresh (a page with its own inline Gtk.ListBox, like page_uninstall_runner) without
    duplicating the machinery of a reusable widget like GameMultiSelect."""

    def __init__(self, fn):
        self._fn = fn

    def refresh(self):
        self._fn()
