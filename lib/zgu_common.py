"""Helpers shared by the small Python programs of lib/ (loading screen, picker, gamepad watchers,
prefix watcher). Each of them runs as a separate process started by path ("python3 lib/<file>.py"),
so this module sits next to them and is imported by name. Nothing runs at import time."""

import ctypes
import ctypes.util


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
