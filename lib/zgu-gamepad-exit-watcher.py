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
# Lifetime: the script stops by itself once it has sent SIGTERM once. The orchestrator
# cannot reliably tell when a game ends normally (zgl-launcher-orchestrator.sh hands over
# to Lutris via "exec" and loses track of the game process), so if the combo is never used
# the watcher keeps running after the game exits. This is harmless: reading is passive with
# near-zero CPU cost, and with no process of the prefix the combo does nothing.
#
# SYSTEM DEPENDENCY: the libSDL2 shared library ("libsdl2-2.0-0" on Debian/Ubuntu, "sdl2"
# on Arch, "SDL2" on Fedora). No extra Python package (pysdl2): the script calls libSDL2
# directly via ctypes to keep the added dependency to a minimum.

import sys
import os
import signal
import time
import ctypes
import ctypes.util

if len(sys.argv) < 3 or sys.argv[1] not in ("x11", "wayland") or not sys.argv[2]:
    sys.stderr.write("Usage: zgu-gamepad-exit-watcher.py <x11|wayland> <dossier_du_prefixe>\n")
    sys.exit(1)

SESSION_KIND = sys.argv[1]
PREFIX_DIR = os.path.realpath(sys.argv[2])

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
GAMECONTROLLERDB_PATH = os.path.join(SCRIPT_DIR, "data", "gamecontrollerdb.txt")

running = True


def handle_signal(_signum, _frame):
    global running
    running = False


signal.signal(signal.SIGTERM, handle_signal)
signal.signal(signal.SIGINT, handle_signal)


# --- Loading libSDL2 -----------------------------------------------------------------
def _load_sdl2():
    names = []
    found = ctypes.util.find_library("SDL2")
    if found:
        names.append(found)
    names += ["libSDL2-2.0.so.0", "libSDL2-2.0.so", "SDL2"]
    for name in names:
        try:
            return ctypes.CDLL(name)
        except OSError:
            continue
    return None


sdl = _load_sdl2()
if sdl is None:
    sys.stderr.write(
        "zgu-gamepad-exit-watcher: libSDL2 introuvable "
        "(paquet manquant : libsdl2-2.0-0 / sdl2 / SDL2)\n"
    )
    sys.exit(1)

# No window here, only gamepad reading: force a dummy video driver so SDL_Init never tries
# to reach a display server (also useful if DISPLAY/WAYLAND_DISPLAY is not reachable at
# launch).
os.environ.setdefault("SDL_VIDEODRIVER", "dummy")
# The gamepad must keep being read even though this process never has focus (it has no
# window). This is SDL2's default for the joystick subsystem on Linux (direct joystick/evdev
# reads, not tied to X11/Wayland focus); set explicitly so it does not depend on a default.
os.environ.setdefault("SDL_JOYSTICK_ALLOW_BACKGROUND_EVENTS", "1")

SDL_INIT_JOYSTICK = 0x00000200
SDL_INIT_GAMECONTROLLER = 0x00002000
SDL_INIT_EVENTS = 0x00004000

sdl.SDL_Init.restype = ctypes.c_int
sdl.SDL_Init.argtypes = [ctypes.c_uint32]
sdl.SDL_Quit.restype = None
sdl.SDL_GetError.restype = ctypes.c_char_p
sdl.SDL_NumJoysticks.restype = ctypes.c_int
sdl.SDL_IsGameController.restype = ctypes.c_int
sdl.SDL_IsGameController.argtypes = [ctypes.c_int]
sdl.SDL_GameControllerOpen.restype = ctypes.c_void_p
sdl.SDL_GameControllerOpen.argtypes = [ctypes.c_int]
sdl.SDL_GameControllerClose.restype = None
sdl.SDL_GameControllerClose.argtypes = [ctypes.c_void_p]
sdl.SDL_GameControllerUpdate.restype = None
sdl.SDL_GameControllerGetButton.restype = ctypes.c_uint8
sdl.SDL_GameControllerGetButton.argtypes = [ctypes.c_void_p, ctypes.c_int]
sdl.SDL_GameControllerGetAxis.restype = ctypes.c_int16
sdl.SDL_GameControllerGetAxis.argtypes = [ctypes.c_void_p, ctypes.c_int]
# SDL_GameControllerAddMappingsFromFile is optional: some libSDL2 builds do not export it
# (absent from Ubuntu's libSDL2-2.0.so.0 2.30.0). Resolve it defensively via getattr so a
# missing symbol never crashes startup; the library's built-in database is used instead.
_add_mappings_from_file = getattr(sdl, "SDL_GameControllerAddMappingsFromFile", None)
if _add_mappings_from_file is not None:
    _add_mappings_from_file.restype = ctypes.c_int
    _add_mappings_from_file.argtypes = [ctypes.c_char_p]

if sdl.SDL_Init(SDL_INIT_JOYSTICK | SDL_INIT_GAMECONTROLLER | SDL_INIT_EVENTS) != 0:
    sys.stderr.write(
        "zgu-gamepad-exit-watcher: SDL_Init a échoué (%s)\n"
        % sdl.SDL_GetError().decode("utf-8", "replace")
    )
    sys.exit(1)

# Load the bundled community database, giving SDL2 the standard mapping for many known
# gamepads rather than relying only on the libSDL2 built-in one (varies by distribution).
# A missing file or symbol is not fatal: falls back to the built-in database.
if _add_mappings_from_file is not None and os.path.isfile(GAMECONTROLLERDB_PATH):
    _add_mappings_from_file(GAMECONTROLLERDB_PATH.encode("utf-8"))
elif _add_mappings_from_file is None:
    sys.stderr.write(
        "zgu-gamepad-exit-watcher: SDL_GameControllerAddMappingsFromFile indisponible dans "
        "cette libSDL2 -- base bundlée ignorée, repli sur la base interne de la lib installée.\n"
    )


def _env_value(pid, name):
    try:
        with open("/proc/%d/environ" % pid, "rb") as f:
            for entry in f.read().split(b"\0"):
                if entry.startswith(name + b"="):
                    return entry[len(name) + 1:].decode("utf-8", "replace")
    except OSError:
        pass
    return None


def _in_prefix(path):
    if not path:
        return False
    path = os.path.realpath(path)
    return path == PREFIX_DIR or path.startswith(PREFIX_DIR + os.sep)


def close_game():
    """Stop the wineserver OF THIS GAME'S PREFIX: SIGINT, exactly what "wineserver -k"
    does. Wine then closes every process of the prefix, whatever its name (a game's real
    process may be called "Main thread", not "game.exe"). Only targets wineservers whose
    prefix is this game's."""
    me = os.getpid()
    for entry in os.listdir("/proc"):
        if not entry.isdigit() or int(entry) == me:
            continue
        pid = int(entry)
        try:
            with open("/proc/%d/comm" % pid, "r") as f:
                comm = f.read().strip()
        except OSError:
            continue
        if comm != "wineserver":
            continue
        if not (_in_prefix(_env_value(pid, b"WINEPREFIX"))
                or _in_prefix(_env_value(pid, b"STEAM_COMPAT_DATA_PATH"))):
            continue
        try:
            os.kill(pid, signal.SIGINT)
        except OSError:
            pass


# --- SDL2 standardized buttons/axes (SDL_GameControllerButton / SDL_GameControllerAxis,
# fixed numeric values of the C API, see SDL_gamecontroller.h). SDL2 translates every
# recognized gamepad to this fixed layout, whatever the model.
SDL_CONTROLLER_BUTTON_LEFTSTICK = 7        # left stick click (L3)
SDL_CONTROLLER_BUTTON_RIGHTSTICK = 8       # right stick click (R3)
SDL_CONTROLLER_BUTTON_LEFTSHOULDER = 9     # L1
SDL_CONTROLLER_BUTTON_RIGHTSHOULDER = 10   # R1
SDL_CONTROLLER_AXIS_TRIGGERLEFT = 4        # L2 (analog, 0..32767)
SDL_CONTROLLER_AXIS_TRIGGERRIGHT = 5       # R2 (analog, 0..32767)

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


def find_controllers():
    pads = []
    for i in range(sdl.SDL_NumJoysticks()):
        if sdl.SDL_IsGameController(i):
            handle = sdl.SDL_GameControllerOpen(i)
            if handle:
                pads.append(handle)
    return pads


def count_available_controllers():
    """Count the gamepads SDL2 recognizes WITHOUT opening them, only to detect a change
    before calling find_controllers() again (see main())."""
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
    pads = find_controllers()
    loops_since_rescan = 0

    try:
        while running:
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
                    pads = find_controllers()

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
