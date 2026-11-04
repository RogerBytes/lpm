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


def sync_controllers(sdl, pads, on_added=None, on_removed=None):
    """Hot-plug: makes the list of open handles "pads" (modified in place) match the game
    controllers connected RIGHT NOW. A controller that was disconnected is closed and dropped
    (on_removed(handle)), a new or reconnected one (Bluetooth, USB) is opened and added
    (on_added(handle)). Best-effort: never raises. Events are pumped first (that is when SDL
    notices a device appearing) then discarded, so the event queue never fills up."""
    try:
        sdl.SDL_PumpEvents()
        sdl.SDL_FlushEvents(0, 0xFFFF)
        for pad in list(pads):
            if not sdl.SDL_GameControllerGetAttached(pad):
                pads.remove(pad)
                sdl.SDL_GameControllerClose(pad)
                if on_removed:
                    on_removed(pad)
        open_ids = set()
        for pad in pads:
            joystick = sdl.SDL_GameControllerGetJoystick(pad)
            if joystick:
                open_ids.add(sdl.SDL_JoystickInstanceID(joystick))
        for i in range(sdl.SDL_NumJoysticks()):
            if not sdl.SDL_IsGameController(i):
                continue
            if sdl.SDL_JoystickGetDeviceInstanceID(i) in open_ids:
                continue
            handle = sdl.SDL_GameControllerOpen(i)
            if handle:
                pads.append(handle)
                open_ids.add(sdl.SDL_JoystickGetDeviceInstanceID(i))
                if on_added:
                    on_added(handle)
    except Exception:
        pass


def connect_double_click(listbox, on_activate):
    """Double-click on a row of a Gtk.ListBox: selects the row under the pointer, then calls
    on_activate(). The timing is done HERE (two presses on the same row within the system's
    double-click time, gtk-double-click-time) instead of trusting GTK's press counter, which
    is reset whenever the list's own click handling interferes. Capture phase, so that
    handling can never swallow the click either."""
    import gi
    gi.require_version("Gtk", "4.0")
    from gi.repository import Gtk, GLib

    gesture = Gtk.GestureClick()
    gesture.set_button(1)
    gesture.set_propagation_phase(Gtk.PropagationPhase.CAPTURE)
    last = {"row": None, "time": 0.0}

    def pressed(_gesture, _n_press, _x, y):
        row = listbox.get_row_at_y(int(y))
        if row is None:
            last["row"] = None
            return
        now = GLib.get_monotonic_time() / 1000.0
        settings = Gtk.Settings.get_default()
        limit = settings.get_property("gtk-double-click-time") if settings else 400
        if row is last["row"] and now - last["time"] <= limit:
            last["row"] = None
            listbox.select_row(row)
            GLib.idle_add(on_activate)
        else:
            last["row"], last["time"] = row, now

    gesture.connect("pressed", pressed)
    listbox.add_controller(gesture)


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


def close_prefix_game(prefix_dir):
    """Stop the wineserver(s) OF THIS PREFIX with SIGINT, exactly what "wineserver -k" does:
    Wine then closes every process of the prefix, whatever its name. Never touches a wineserver
    of another prefix, never uses "kill -9". Returns how many wineservers were signalled."""
    import signal
    prefix_dir = os.path.realpath(prefix_dir) if prefix_dir else ""
    if not prefix_dir:
        return 0

    def in_prefix(path):
        if not path:
            return False
        path = os.path.realpath(path)
        return path == prefix_dir or path.startswith(prefix_dir + os.sep)

    count = 0
    for entry in os.listdir("/proc"):
        if not entry.isdigit() or int(entry) == os.getpid():
            continue
        pid = int(entry)
        try:
            with open("/proc/%d/comm" % pid, "r") as f:
                if f.read().strip() != "wineserver":
                    continue
        except OSError:
            continue
        if not (in_prefix(env_value(pid, b"WINEPREFIX")) or in_prefix(env_value(pid, b"STEAM_COMPAT_DATA_PATH"))):
            continue
        try:
            os.kill(pid, signal.SIGINT)
            count += 1
        except OSError:
            pass
    return count


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
    sdl.SDL_PumpEvents.restype = None
    sdl.SDL_FlushEvents.restype = None
    sdl.SDL_FlushEvents.argtypes = [ctypes.c_uint32, ctypes.c_uint32]
    sdl.SDL_GameControllerGetAttached.restype = ctypes.c_int
    sdl.SDL_GameControllerGetAttached.argtypes = [ctypes.c_void_p]
    sdl.SDL_GameControllerGetJoystick.restype = ctypes.c_void_p
    sdl.SDL_GameControllerGetJoystick.argtypes = [ctypes.c_void_p]
    sdl.SDL_JoystickInstanceID.restype = ctypes.c_int32
    sdl.SDL_JoystickInstanceID.argtypes = [ctypes.c_void_p]
    sdl.SDL_JoystickGetDeviceInstanceID.restype = ctypes.c_int32
    sdl.SDL_JoystickGetDeviceInstanceID.argtypes = [ctypes.c_int]
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
