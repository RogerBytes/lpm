# Test helper: runs a script with a virtual gamepad pressing (button, start_ms, hold_ms) events.
import ctypes, os, sys, runpy
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "lib"))
import zgu_common
sdl = zgu_common.load_sdl2(); zgu_common.init_sdl(sdl)
sdl.SDL_JoystickAttachVirtual.restype = ctypes.c_int
idx = sdl.SDL_JoystickAttachVirtual(1, 6, 15, 0)
sdl.SDL_JoystickOpen.restype = ctypes.c_void_p
js = ctypes.c_void_p(sdl.SDL_JoystickOpen(idx))
from gi.repository import GLib
script = sys.argv[1]
def press(btn, t, hold=150):
    GLib.timeout_add(t, lambda: (sdl.SDL_JoystickSetVirtualButton(js, btn, 1), False)[1])
    GLib.timeout_add(t + hold, lambda: (sdl.SDL_JoystickSetVirtualButton(js, btn, 0), False)[1])
# events: (button, start_ms, hold_ms)
for b, t, h in eval(sys.argv[2]):
    press(b, t, h)
sys.argv = [script, "x11", os.environ.get("LUDIS_TEST_PREFIX", "/tmp")]
runpy.run_path(script, run_name="__main__")
