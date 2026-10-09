#!/usr/bin/env python3
# --- lpm launcher: "switch window" (Alt+Tab) gamepad combo, via SDL2 ---
#
# Usage: zgu-gamepad-alttab-watcher.py <x11|wayland>
#
# Sibling of zgu-gamepad-exit-watcher.py (same principles: SDL2, no grab(), non-exclusive
# reading compatible with AntiMicro; see that file), with a different lifetime and gesture:
#
#   - NOT single-shot: it stays active for the WHOLE game session and can trigger any
#     number of times.
#   - The gesture is a HOLD: while L1+L2+R1+R2+R3 click stays pressed, D-pad Left/Right
#     cycles windows (Shift+Tab / Tab), like holding Alt on a keyboard and pressing Tab
#     repeatedly. Releasing the combo releases Alt and confirms the selection.
#
# During the same hold, three more keys are available (one press = one key):
#
#   D-pad Up    -> F4         (F4 ALONE: Alt is released during the press, otherwise it
#                              would be Alt+F4 and close the active window)
#   D-pad Down  -> Alt+Enter  (Alt is already held by the hold: only Enter is sent)
#   Select/Back -> F11        (F11 ALONE, Alt released during the press, like F4)
#
# Works on X11 (xdotool) and Wayland (ydotool).
#
# Deliberately different (not a subset) from the "quit" combo of
# zgu-gamepad-exit-watcher.py (L1+L2+R1+R2+L3+R3): L3 is never part of this combo, and
# direction uses ONLY the D-pad, never the left stick, so moving the stick during the hold
# can never complete the quit combo by accident.
#
# SYSTEM DEPENDENCY: libSDL2, same as zgu-gamepad-exit-watcher.py (see that file).

import sys
import os
import signal
import subprocess
import shutil
import time
import ctypes
import ctypes.util

if len(sys.argv) < 2 or sys.argv[1] not in ("x11", "wayland"):
    sys.stderr.write("Usage: zgu-gamepad-alttab-watcher.py <x11|wayland>\n")
    sys.exit(1)

SESSION_KIND = sys.argv[1]

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
GAMECONTROLLERDB_PATH = os.path.join(SCRIPT_DIR, "data", "gamecontrollerdb.txt")

running = True


def handle_signal(_signum, _frame):
    global running
    running = False


signal.signal(signal.SIGTERM, handle_signal)
signal.signal(signal.SIGINT, handle_signal)


# --- Loading libSDL2 (same as zgu-gamepad-exit-watcher.py) ---------------------------
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
        "zgu-gamepad-alttab-watcher: libSDL2 introuvable "
        "(paquet manquant : libsdl2-2.0-0 / sdl2 / SDL2)\n"
    )
    sys.exit(1)

os.environ.setdefault("SDL_VIDEODRIVER", "dummy")
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

_add_mappings_from_file = getattr(sdl, "SDL_GameControllerAddMappingsFromFile", None)
if _add_mappings_from_file is not None:
    _add_mappings_from_file.restype = ctypes.c_int
    _add_mappings_from_file.argtypes = [ctypes.c_char_p]

if sdl.SDL_Init(SDL_INIT_JOYSTICK | SDL_INIT_GAMECONTROLLER | SDL_INIT_EVENTS) != 0:
    sys.stderr.write(
        "zgu-gamepad-alttab-watcher: SDL_Init a échoué (%s)\n"
        % sdl.SDL_GetError().decode("utf-8", "replace")
    )
    sys.exit(1)

if _add_mappings_from_file is not None and os.path.isfile(GAMECONTROLLERDB_PATH):
    _add_mappings_from_file(GAMECONTROLLERDB_PATH.encode("utf-8"))


def _resolve_xdotool():
    if shutil.which("xdotool"):
        return "xdotool"
    if os.access("/run/host/usr/bin/xdotool", os.X_OK):
        return "/run/host/usr/bin/xdotool"
    return None


XDOTOOL_BIN = _resolve_xdotool()

# Linux key codes (linux/input-event-codes.h) for ydotool: KEY_LEFTALT=56,
# KEY_TAB=15, KEY_LEFTSHIFT=42.
YDOTOOL_ALT_DOWN = ["56:1"]
YDOTOOL_ALT_UP = ["56:0"]
YDOTOOL_TAB = ["15:1", "15:0"]
YDOTOOL_SHIFT_TAB = ["42:1", "15:1", "15:0", "42:0"]
# KEY_ENTER=28, KEY_F4=62, KEY_F11=87. For F4/F11, Alt is released (56:0) before the press
# and pressed again (56:1) after, in ONE call, so the hold continues normally.
YDOTOOL_ENTER = ["28:1", "28:0"]
YDOTOOL_F4_WITHOUT_ALT = ["56:0", "62:1", "62:0", "56:1"]
YDOTOOL_F11_WITHOUT_ALT = ["56:0", "87:1", "87:0", "56:1"]


def _run_best_effort(argv):
    try:
        subprocess.run(argv, check=False, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except Exception:
        pass  # best-effort -- a missed press must never crash this watcher


def alt_down():
    if SESSION_KIND == "x11" and XDOTOOL_BIN:
        _run_best_effort([XDOTOOL_BIN, "keydown", "alt"])
    elif shutil.which("ydotool"):
        _run_best_effort(["ydotool", "key", *YDOTOOL_ALT_DOWN])


def alt_up():
    if SESSION_KIND == "x11" and XDOTOOL_BIN:
        _run_best_effort([XDOTOOL_BIN, "keyup", "alt"])
    elif shutil.which("ydotool"):
        _run_best_effort(["ydotool", "key", *YDOTOOL_ALT_UP])


def send_tab(reverse):
    if SESSION_KIND == "x11" and XDOTOOL_BIN:
        _run_best_effort([XDOTOOL_BIN, "key", "shift+Tab" if reverse else "Tab"])
    elif shutil.which("ydotool"):
        _run_best_effort(["ydotool", "key", *(YDOTOOL_SHIFT_TAB if reverse else YDOTOOL_TAB)])


def send_alt_enter():
    """Alt is already held by the combo hold, so sending only Enter gives Alt+Enter.
    (Sending "alt+Return" would release Alt at the end and break the hold.)"""
    if SESSION_KIND == "x11" and XDOTOOL_BIN:
        _run_best_effort([XDOTOOL_BIN, "key", "Return"])
    elif shutil.which("ydotool"):
        _run_best_effort(["ydotool", "key", *YDOTOOL_ENTER])


def send_key_without_alt(x11_name, ydotool_sequence):
    """Send a key ALONE (F4, F11...) while Alt is held by the combo: Alt is released for
    the press then restored, otherwise F4 would become Alt+F4 (closing the window).
    xdotool "--clearmodifiers" does exactly this (removes then restores modifiers)."""
    if SESSION_KIND == "x11" and XDOTOOL_BIN:
        _run_best_effort([XDOTOOL_BIN, "key", "--clearmodifiers", x11_name])
    elif shutil.which("ydotool"):
        _run_best_effort(["ydotool", "key", *ydotool_sequence])


def send_f4():
    send_key_without_alt("F4", YDOTOOL_F4_WITHOUT_ALT)


def send_f11():
    send_key_without_alt("F11", YDOTOOL_F11_WITHOUT_ALT)


# --- Pausing AntiMicro(X) during the hold ----------------------------------------------
#
# AntiMicro reads the gamepad IN PARALLEL with this watcher (non-exclusive SDL2 reading).
# If the user already mapped the D-pad Left/Right in AntiMicro (e.g. to arrow keys), each
# press during the hold would trigger both Tab/Shift+Tab from this script AND the mapped
# key: a duplicate.
#
# Fix: pause AntiMicro(X) with SIGSTOP (standard POSIX) for exactly the duration of the
# hold, then resume it with SIGCONT on release. While paused it neither reads nor emits
# anything. Nothing to configure in AntiMicro, and no effect if it is not running (empty
# PID list).
#
# Looked up under both names: "antimicrox" (current fork) and "antimicro" (old name).
# "pgrep" is not a new dependency ("pkill", from the same procps package, is already used
# in zgl-launcher-orchestrator.sh and zgp-game-uninstaller.sh); if absent, silently skip.
ANTIMICRO_PROCESS_NAMES = ("antimicrox", "antimicro")


def _find_antimicro_pids():
    pids = []
    if not shutil.which("pgrep"):
        return pids
    for name in ANTIMICRO_PROCESS_NAMES:
        try:
            result = subprocess.run(["pgrep", "-x", name], check=False,
                                     stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                                     text=True)
        except Exception:
            continue
        for line in result.stdout.splitlines():
            line = line.strip()
            if line.isdigit():
                pids.append(int(line))
    return pids


def _pause_antimicro():
    pids = _find_antimicro_pids()
    for pid in pids:
        try:
            os.kill(pid, signal.SIGSTOP)
        except OSError:
            pass
    return pids


def _resume_antimicro(pids):
    for pid in pids:
        try:
            os.kill(pid, signal.SIGCONT)
        except OSError:
            pass


# --- SDL2 standardized buttons/axes (same constants as the other watchers) -----------------
SDL_CONTROLLER_BUTTON_BACK = 4               # Select
SDL_CONTROLLER_BUTTON_LEFTSTICK = 7
SDL_CONTROLLER_BUTTON_RIGHTSTICK = 8         # right stick click (R3)
SDL_CONTROLLER_BUTTON_LEFTSHOULDER = 9       # L1
SDL_CONTROLLER_BUTTON_RIGHTSHOULDER = 10     # R1
SDL_CONTROLLER_BUTTON_DPAD_UP = 11
SDL_CONTROLLER_BUTTON_DPAD_DOWN = 12
SDL_CONTROLLER_BUTTON_DPAD_LEFT = 13
SDL_CONTROLLER_BUTTON_DPAD_RIGHT = 14
SDL_CONTROLLER_AXIS_TRIGGERLEFT = 4          # L2
SDL_CONTROLLER_AXIS_TRIGGERRIGHT = 5         # R2

# Hold: L1 + R1 + R3 click (buttons) + L2 + R2 (axes), deliberately WITHOUT L3 (left stick
# click): direction uses the D-pad, never the left stick, so it never overlaps the quit
# combo of zgu-gamepad-exit-watcher.py.
HOLD_BUTTONS = (
    SDL_CONTROLLER_BUTTON_LEFTSHOULDER,
    SDL_CONTROLLER_BUTTON_RIGHTSHOULDER,
    SDL_CONTROLLER_BUTTON_RIGHTSTICK,
)
HOLD_AXES = (SDL_CONTROLLER_AXIS_TRIGGERLEFT, SDL_CONTROLLER_AXIS_TRIGGERRIGHT)
AXIS_PULL_THRESHOLD = int(32767 * 0.9)
POLL_INTERVAL_SECONDS = 0.05
# Re-scan connected gamepads about once per second (not on every 50ms tick); see the
# comment in main() below (same fix as zgu-gamepad-exit-watcher.py).
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


def hold_active(pads):
    for pad in pads:
        buttons_ok = all(sdl.SDL_GameControllerGetButton(pad, code) for code in HOLD_BUTTONS)
        axes_ok = all(
            sdl.SDL_GameControllerGetAxis(pad, code) >= AXIS_PULL_THRESHOLD for code in HOLD_AXES
        )
        if buttons_ok and axes_ok:
            return True
    return False


def dpad_direction(pads):
    """-1 (left), 1 (right) or 0: first pad that responds, never both at once."""
    for pad in pads:
        left = sdl.SDL_GameControllerGetButton(pad, SDL_CONTROLLER_BUTTON_DPAD_LEFT)
        right = sdl.SDL_GameControllerGetButton(pad, SDL_CONTROLLER_BUTTON_DPAD_RIGHT)
        if left and not right:
            return -1
        if right and not left:
            return 1
    return 0


# Single-press keys during the hold: SDL2 button -> action. An action fires on the rising
# edge (released to pressed), never repeating while the button stays held.
ONE_SHOT_ACTIONS = (
    (SDL_CONTROLLER_BUTTON_DPAD_UP, send_f4),
    (SDL_CONTROLLER_BUTTON_DPAD_DOWN, send_alt_enter),
    (SDL_CONTROLLER_BUTTON_BACK, send_f11),
)


def button_down(pads, code):
    return any(sdl.SDL_GameControllerGetButton(pad, code) for pad in pads)


def main():
    # "pads" must not be detected only once at startup (same fix as
    # zgu-gamepad-exit-watcher.py, see its main()): keep running even with no gamepad at
    # start, and re-scan periodically (RESCAN_INTERVAL_LOOPS, ~1x/s) to catch a pad that
    # appears later or reconnects mid-game.
    pads = find_controllers()
    loops_since_rescan = 0

    alt_is_held = False
    prev_dpad_dir = 0
    prev_one_shot = {}  # button -> was pressed on the previous tick (see ONE_SHOT_ACTIONS)
    antimicro_paused_pids = []  # see _pause_antimicro()/_resume_antimicro() above

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

            active = hold_active(pads)

            if active and not alt_is_held:
                alt_down()
                alt_is_held = True
                prev_dpad_dir = 0  # restart from zero on each new hold
                # A button already held when the combo completes triggers nothing:
                # only a NEW press during the hold counts.
                prev_one_shot = {code: button_down(pads, code) for code, _ in ONE_SHOT_ACTIONS}
                antimicro_paused_pids = _pause_antimicro()
            elif not active and alt_is_held:
                alt_up()
                alt_is_held = False
                prev_dpad_dir = 0
                _resume_antimicro(antimicro_paused_pids)
                antimicro_paused_pids = []

            if alt_is_held:
                direction = dpad_direction(pads)
                if direction != prev_dpad_dir and direction != 0:
                    send_tab(reverse=(direction < 0))
                prev_dpad_dir = direction

                for code, action in ONE_SHOT_ACTIONS:
                    pressed = button_down(pads, code)
                    if pressed and not prev_one_shot.get(code, False):
                        action()
                    prev_one_shot[code] = pressed

            time.sleep(POLL_INTERVAL_SECONDS)
    finally:
        # Safety net: if we exit (SIGTERM, game killed...) while Alt is still held on the
        # virtual keyboard, release it, otherwise Alt would stay stuck for the rest of the
        # desktop session and break keyboard/mouse navigation. Same for AntiMicro: if it is
        # paused at that point it MUST be resumed, or it would stay frozen until the user
        # restarts it by hand.
        if alt_is_held:
            alt_up()
            _resume_antimicro(antimicro_paused_pids)
        for pad in pads:
            try:
                sdl.SDL_GameControllerClose(pad)
            except Exception:
                pass
        sdl.SDL_Quit()


if __name__ == "__main__":
    main()
