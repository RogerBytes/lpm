"""Helpers shared by the small Python programs of lib/ (loading screen, picker, gamepad watchers,
prefix watcher). Each of them runs as a separate process started by path ("python3 lib/<file>.py"),
so this module sits next to them and is imported by name. Nothing runs at import time."""

import ctypes
import ctypes.util
import os


def load_sdl2():
    """Loads the SDL2 shared library (system name first, then the usual file names). Returns the
    ctypes library, or None when SDL2 is not installed (callers then run without gamepad)."""
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


def find_controllers(sdl):
    """Opens every connected SDL game controller and returns the list of handles."""
    pads = []
    for i in range(sdl.SDL_NumJoysticks()):
        if sdl.SDL_IsGameController(i):
            handle = sdl.SDL_GameControllerOpen(i)
            if handle:
                pads.append(handle)
    return pads


def env_value(pid, name):
    """Value of the environment variable <name> (bytes, e.g. b"WINEPREFIX") of process <pid>,
    read from /proc, or None when unreadable or not set."""
    try:
        with open("/proc/%d/environ" % pid, "rb") as f:
            for entry in f.read().split(b"\0"):
                if entry.startswith(name + b"="):
                    return entry[len(name) + 1:].decode("utf-8", "replace")
    except OSError:
        pass
    return None


# --- SDL2 game controller constants (same values in every program) ---
GAMEPAD_POLL_MS = 20
GAMEPAD_AXIS_THRESHOLD = int(32767 * 0.5)  # 50% of the axis travel

SDL_INIT_JOYSTICK = 0x00000200
SDL_INIT_GAMECONTROLLER = 0x00002000
SDL_INIT_EVENTS = 0x00004000
SDL_CONTROLLER_BUTTON_A = 0
SDL_CONTROLLER_BUTTON_B = 1
SDL_CONTROLLER_BUTTON_BACK = 4               # Select
SDL_CONTROLLER_BUTTON_LEFTSTICK = 7          # left stick click (L3)
SDL_CONTROLLER_BUTTON_RIGHTSTICK = 8         # right stick click (R3)
SDL_CONTROLLER_BUTTON_LEFTSHOULDER = 9       # L1
SDL_CONTROLLER_BUTTON_RIGHTSHOULDER = 10     # R1
SDL_CONTROLLER_BUTTON_DPAD_UP = 11
SDL_CONTROLLER_BUTTON_DPAD_DOWN = 12
SDL_CONTROLLER_BUTTON_DPAD_LEFT = 13
SDL_CONTROLLER_BUTTON_DPAD_RIGHT = 14
SDL_CONTROLLER_AXIS_LEFTY = 1
SDL_CONTROLLER_AXIS_TRIGGERLEFT = 4          # L2 (analog, 0..32767)
SDL_CONTROLLER_AXIS_TRIGGERRIGHT = 5         # R2 (analog, 0..32767)

GAMECONTROLLERDB_PATH = os.path.join(
    os.path.dirname(os.path.abspath(__file__)), "data", "gamecontrollerdb.txt"
)


def init_sdl(sdl):
    """Prepares SDL2 for gamepad reading without any window: dummy video driver, joystick events
    kept when unfocused, function signatures, SDL_Init and the controller mappings file. Returns
    True when SDL is ready, False when SDL_Init failed (SDL_GetError says why)."""
    # No window here, only gamepad reading: a dummy video driver so SDL_Init never tries to reach
    # a display server. The gamepad must keep being read even though the process never has focus.
    os.environ.setdefault("SDL_VIDEODRIVER", "dummy")
    os.environ.setdefault("SDL_JOYSTICK_ALLOW_BACKGROUND_EVENTS", "1")

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
    add_mappings = getattr(sdl, "SDL_GameControllerAddMappingsFromFile", None)
    if add_mappings is not None:
        add_mappings.restype = ctypes.c_int
        add_mappings.argtypes = [ctypes.c_char_p]

    if sdl.SDL_Init(SDL_INIT_JOYSTICK | SDL_INIT_GAMECONTROLLER | SDL_INIT_EVENTS) != 0:
        return False
    if add_mappings is not None and os.path.isfile(GAMECONTROLLERDB_PATH):
        add_mappings(GAMECONTROLLERDB_PATH.encode("utf-8"))
    return True


# --- Style (CSS) of the picker, shared by lib/zgu-launcher-picker.py and the picker embedded in
# lib/zgu-launcher-screen.py: same palette, same title/prompt and same Validate/Cancel buttons.
# The rest of each stylesheet (window or card, list rows) differs and stays in each program. ---
PICKER_TEXT_CSS = b"""
.lpm-picker-title {
    font-weight: bold;
    font-size: 24px;
    color: #ffffff;
}
.lpm-picker-prompt {
    font-size: 20px;
    color: #cccccc;
}
"""

PICKER_BUTTON_CSS = b"""
/* Bordure : couleur du fond du bouton eclaircie uniformement (+0x20 par canal), jamais le
   blanc par defaut du theme --. "border" en raccourci complet
   (style + largeur + couleur), meme logique que "background-image: none" plus haut : ne
   laisser aucune propriete de bordure heritee du theme. */
.lpm-picker-validate-button {
    background-image: none;
    background-color: #2e7d32;
    border: 1px solid #4e9d52;
    color: #ffffff;
}
.lpm-picker-validate-button:hover {
    background-image: none;
    background-color: #388e3c;
    border: 1px solid #58ae5c;
}
.lpm-picker-cancel-button {
    background-image: none;
    background-color: #3a3a3a;
    border: 1px solid #5a5a5a;
    color: #ffffff;
}
.lpm-picker-cancel-button:hover {
    background-image: none;
    background-color: #474747;
    border: 1px solid #676767;
}
"""
