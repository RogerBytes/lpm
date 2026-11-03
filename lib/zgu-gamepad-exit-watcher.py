#!/usr/bin/env python3
# --- lpm launcher: "quit the game" gamepad combo, via SDL2, no exclusive grab ---
#
# Usage: zgu-gamepad-exit-watcher.py <x11|wayland> <prefix_folder>
#
# Deliberately separate from the picker's gamepad navigation (read directly in SDL2 by
# zgu-launcher-screen.py / zgu-launcher-picker.py), which only runs while the picker is
# shown. This watcher runs DURING the game, where the gamepad must stay readable by the
# game itself AND by a remapping tool such as AntiMicro. SDL2 reads the gamepad through
# the kernel joystick/evdev subsystem WITHOUT EVIOCGRAB, so several non-exclusive readers
# coexist fine on Linux.
#
# Why SDL2 rather than raw evdev: raw evdev button/axis codes differ per gamepad model
# (the symbolic evdev names did not match the physical buttons on an 8BitDo SN30 Pro+).
# SDL2's community "gamecontrollerdb.txt" (bundled in lib/data/gamecontrollerdb.txt) maps
# each known gamepad, identified by its GUID (vendor/product/version), to a fixed standard
# layout (LEFTSHOULDER, RIGHTSHOULDER, LEFTSTICK, RIGHTSTICK, TRIGGERLEFT/TRIGGERRIGHT), so
# the combo works on any gamepad SDL2 recognizes without per-model capture.
#
# Watched combo: L1 + R1 + L2 + R2 + left stick click (L3) + right stick click (R3), ALL
# pressed at once. Chosen to avoid classic "reset" combos (Start+Select+L+R) and known
# cheat-code combos (e.g. L1+L2+R1 on some PS2 games); it is also physically unlikely to
# be done by accident.
#
# Trigger: as soon as all 6 are pressed (polled every 50ms, no hold delay), it asks for the
# game to be closed, then the script exits (single use).
#
# How the game is closed: not a global Alt+F4, which goes to whichever window has focus at
# that instant (it once logged the user out of their whole graphical session). Instead,
# send SIGINT to the wineserver OF THIS GAME'S PREFIX (matched via WINEPREFIX /
# STEAM_COMPAT_DATA_PATH read from /proc, compared with the prefix folder argument). This is
# equivalent to "wineserver -k": Wine closes the whole prefix itself. The game process is
# deliberately not looked up by name (it may be called anything, e.g. "Main thread").
# Independent of X11/Wayland and focus, can never touch anything outside that prefix, does
# nothing if no wineserver of that prefix exists, and never uses "kill -9".
#
# Lifetime: the script stops by itself once it has sent SIGTERM once, or once the game is over
# (no wineserver of the prefix any more, see zgu-prefix-watch.py). The orchestrator hands over
# to Lutris via "exec" and cannot tell when the game ends, so the watcher checks by itself.
#
# SYSTEM DEPENDENCY: the libSDL2 shared library ("libsdl2-2.0-0" on Debian/Ubuntu, "sdl2"
# on Arch, "SDL2" on Fedora). No extra Python package (pysdl2): the script calls libSDL2
# directly via ctypes to keep the added dependency to a minimum.

import sys
import os
import signal
import time
# lib/ is the folder of this script: zgu_common.py sits next to it, whatever the way it is started.
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from zgu_common import (
    SDL_CONTROLLER_AXIS_TRIGGERLEFT,
    SDL_CONTROLLER_AXIS_TRIGGERRIGHT,
    SDL_CONTROLLER_BUTTON_LEFTSHOULDER,
    SDL_CONTROLLER_BUTTON_LEFTSTICK,
    SDL_CONTROLLER_BUTTON_RIGHTSHOULDER,
    SDL_CONTROLLER_BUTTON_RIGHTSTICK,
    close_prefix_game,
    find_controllers,
    init_sdl,
    load_sdl2,
)

if len(sys.argv) < 3 or sys.argv[1] not in ("x11", "wayland") or not sys.argv[2]:
    sys.stderr.write("Usage: zgu-gamepad-exit-watcher.py <x11|wayland> <prefix_folder>\n")
    sys.exit(1)

SESSION_KIND = sys.argv[1]
PREFIX_DIR = os.path.realpath(sys.argv[2])

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))

running = True


def _load_prefix_watch():
    import importlib.util
    spec = importlib.util.spec_from_file_location(
        "zgu_prefix_watch", os.path.join(os.path.dirname(os.path.abspath(__file__)), "zgu-prefix-watch.py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def handle_signal(_signum, _frame):
    global running
    running = False


signal.signal(signal.SIGTERM, handle_signal)
signal.signal(signal.SIGINT, handle_signal)



sdl = load_sdl2()
if sdl is None:
    sys.stderr.write(
        "zgu-gamepad-exit-watcher: libSDL2 not found "
        "(missing package: libsdl2-2.0-0 / sdl2 / SDL2)\n"
    )
    sys.exit(1)

if not init_sdl(sdl):
    sys.stderr.write(
        "zgu-gamepad-exit-watcher: SDL_Init failed (%s)\n"
        % sdl.SDL_GetError().decode("utf-8", "replace")
    )
    sys.exit(1)
elif getattr(sdl, "SDL_GameControllerAddMappingsFromFile", None) is None:
    sys.stderr.write(
        "zgu-gamepad-exit-watcher: SDL_GameControllerAddMappingsFromFile unavailable in "
        "this libSDL2 -- bundled database ignored, falling back to the installed library's built-in one.\n"
    )



def close_game():
    """Stop the wineserver OF THIS GAME'S PREFIX (see zgu_common.close_prefix_game)."""
    close_prefix_game(PREFIX_DIR)


# --- SDL2 standardized buttons/axes (SDL_GameControllerButton / SDL_GameControllerAxis,
# fixed numeric values of the C API, see SDL_gamecontroller.h). SDL2 translates every
# recognized gamepad to this fixed layout, whatever the model.

COMBO_BUTTONS = (
    SDL_CONTROLLER_BUTTON_LEFTSHOULDER,
    SDL_CONTROLLER_BUTTON_RIGHTSHOULDER,
    SDL_CONTROLLER_BUTTON_LEFTSTICK,
    SDL_CONTROLLER_BUTTON_RIGHTSTICK,
)
COMBO_AXES = (SDL_CONTROLLER_AXIS_TRIGGERLEFT, SDL_CONTROLLER_AXIS_TRIGGERRIGHT)
AXIS_PULL_THRESHOLD = int(32767 * 0.9)  # trigger counts as pressed beyond 90% of its travel
POLL_INTERVAL_SECONDS = 0.05
# Re-scan connected gamepads about once per second (not on every 50ms tick); see the
# comment in main() below.
RESCAN_INTERVAL_LOOPS = max(1, round(1.0 / POLL_INTERVAL_SECONDS))



def count_available_controllers():
    """Count the gamepads SDL2 recognizes WITHOUT opening them, only to detect a change
    before calling find_controllers(sdl) again (see main())."""
    return sum(1 for i in range(sdl.SDL_NumJoysticks()) if sdl.SDL_IsGameController(i))


def combo_complete(pads):
    for pad in pads:
        buttons_ok = all(
            sdl.SDL_GameControllerGetButton(pad, code) for code in COMBO_BUTTONS
        )
        axes_ok = all(
            sdl.SDL_GameControllerGetAxis(pad, code) >= AXIS_PULL_THRESHOLD
            for code in COMBO_AXES
        )
        if buttons_ok and axes_ok:
            return True
    return False


def main():
    # "pads" must not be detected only once at startup: if no gamepad is ready at that
    # instant (Bluetooth still reconnecting, wireless dongle negotiating, game launching
    # faster than the pad), exiting would leave the combo unreachable for the whole session.
    # Reading is passive and nearly free (see file header), so keep running and re-scan
    # periodically (RESCAN_INTERVAL_LOOPS, ~1x/s). This also covers a pad that disconnects
    # and reconnects mid-game. The comparison is deliberately simple (number of recognized
    # gamepads, not a per-GUID match); enough since lpm assumes one player/one gamepad.
    pads = find_controllers(sdl)
    loops_since_rescan = 0
    game_watch = _load_prefix_watch().GameEndWatch(PREFIX_DIR)

    try:
        while running:
            if game_watch.game_ended():
                return
            sdl.SDL_GameControllerUpdate()

            loops_since_rescan += 1
            if loops_since_rescan >= RESCAN_INTERVAL_LOOPS:
                loops_since_rescan = 0
                if count_available_controllers() != len(pads):
                    for pad in pads:
                        try:
                            sdl.SDL_GameControllerClose(pad)
                        except Exception:
                            pass
                    pads = find_controllers(sdl)

            if pads and combo_complete(pads):
                close_game()
                return
            time.sleep(POLL_INTERVAL_SECONDS)
    finally:
        for pad in pads:
            try:
                sdl.SDL_GameControllerClose(pad)
            except Exception:
                pass
        sdl.SDL_Quit()


if __name__ == "__main__":
    main()
