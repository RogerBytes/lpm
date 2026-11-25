#!/usr/bin/env python3
# --- Automatic saves: copy the saves of the running game to the sync folder ---
#
# Started (detached) by zgl-launcher-orchestrator.sh just before the game, only when the automatic
# mode is on for that game (see zgu_saves_auto_wanted in zgu-ludis-paths.sh). While the game of the
# prefix runs it calls "zgp-game-saves.sh <slug> push" every <minutes> minutes (0 = never), and once
# more when the game has ended. The work itself (what to copy, atomic write, previous/ rotation)
# is all in zgp-game-saves.sh; this script only watches the clock and the game.
#
# Usage: zgu-saves-monitor.py <prefix_dir> <slug> <minutes>
import importlib.util
import os
import signal
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
GIVE_UP_SECONDS = float(os.environ.get("LUDIS_SAVES_GIVEUP", 15 * 60))  # the game never showed up (launch cancelled): stop


def load_watch():
    spec = importlib.util.spec_from_file_location("zgu_prefix_watch", os.path.join(HERE, "zgu-prefix-watch.py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def push(slug):
    try:
        subprocess.run(["bash", os.path.join(HERE, "zgp-game-saves.sh"), slug, "push"],
                       stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=600)
    except (OSError, subprocess.SubprocessError):
        pass


def main(argv):
    if len(argv) < 3:
        return 2
    prefix, slug = argv[1], argv[2]
    try:
        minutes = max(0, min(60, int(argv[3]))) if len(argv) > 3 else 10
    except ValueError:
        minutes = 10
    running = [True]
    signal.signal(signal.SIGTERM, lambda *_: running.__setitem__(0, False))
    watch = load_watch().GameEndWatch(prefix)
    started = time.monotonic()
    seen = False
    next_push = None
    while running[0]:
        if watch.game_ended():
            push(slug)  # last copy, once the game is gone
            return 0
        now = time.monotonic()
        if not seen and watch._seen:
            seen = True
            next_push = now + minutes * 60 if minutes else None
        if not seen and now - started > GIVE_UP_SECONDS:
            return 0
        if seen and next_push is not None and now >= next_push:
            push(slug)
            next_push = time.monotonic() + minutes * 60
        time.sleep(1.0)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
