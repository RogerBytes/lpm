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


# --- Shared game/runner refresh ---
# backend.run_lpm() must not run on the GTK main thread (it would freeze the UI), and the
# "back" button refreshes every built page at once. _make_coalesced_refresher(fetch_fn)
# therefore builds ONE shared refresher: fetch_fn() runs in a background thread, several close
# requests trigger a single subprocess, requests arriving meanwhile get the same result, and
# each callback is called on the main thread (GLib.idle_add).
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
