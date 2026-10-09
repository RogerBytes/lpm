#!/usr/bin/env python3
# --- Helper for the gamepad watchers: has the game of this prefix ended? ---
#
# Loaded by zgu-gamepad-alttab-watcher.py and zgu-gamepad-exit-watcher.py (importlib, by path).
#
# The orchestrator hands over to Lutris with "exec" and loses track of the game, so the
# watchers have to notice by themselves when it is over. A game of a prefix is "alive" while
# a wineserver of that prefix exists (WINEPREFIX or STEAM_COMPAT_DATA_PATH in its environment,
# the same match as the "quit game" combo uses).
#
# Safe by construction: the watcher is only told to stop AFTER a wineserver of the prefix has
# been seen at least once, and only once it has been gone for GONE_GRACE_SECONDS (a game may
# restart its wineserver briefly, e.g. between an installer and the game). If no wineserver
# is ever recognised, the watcher is never stopped by this helper, which is the old behaviour
# (it then ends at the next game launch, see the "pkill" in zgl-launcher-orchestrator.sh).
import os
import time

CHECK_INTERVAL_SECONDS = 1.0
GONE_GRACE_SECONDS = 4.0


def _env_value(pid, name):
    try:
        with open("/proc/%d/environ" % pid, "rb") as f:
            for entry in f.read().split(b"\0"):
                if entry.startswith(name + b"="):
                    return entry[len(name) + 1:].decode("utf-8", "replace")
    except OSError:
        pass
    return None


def _in_prefix(path, prefix_dir):
    if not path:
        return False
    path = os.path.realpath(path)
    return path == prefix_dir or path.startswith(prefix_dir + os.sep)


def prefix_alive(prefix_dir):
    """True if a wineserver of this prefix is running."""
    for entry in os.listdir("/proc"):
        if not entry.isdigit():
            continue
        pid = int(entry)
        try:
            with open("/proc/%d/comm" % pid, "r") as f:
                if f.read().strip() != "wineserver":
                    continue
        except OSError:
            continue
        if (_in_prefix(_env_value(pid, b"WINEPREFIX"), prefix_dir)
                or _in_prefix(_env_value(pid, b"STEAM_COMPAT_DATA_PATH"), prefix_dir)):
            return True
    return False


class GameEndWatch:
    """Call game_ended() from the watcher loop (cheap: it only scans /proc every
    CHECK_INTERVAL_SECONDS). Returns True once the game has been seen and is gone."""

    def __init__(self, prefix_dir, alive=prefix_alive, clock=time.monotonic):
        self.prefix_dir = os.path.realpath(prefix_dir) if prefix_dir else None
        self._alive = alive
        self._clock = clock
        self._seen = False
        self._last_seen = 0.0
        self._next_check = 0.0

    def game_ended(self):
        if not self.prefix_dir:
            return False
        now = self._clock()
        if now < self._next_check:
            return False
        self._next_check = now + CHECK_INTERVAL_SECONDS
        if self._alive(self.prefix_dir):
            self._seen = True
            self._last_seen = now
            return False
        return self._seen and now - self._last_seen >= GONE_GRACE_SECONDS
