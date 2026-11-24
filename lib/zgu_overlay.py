"""Window helpers shared by the in-game menu and the virtual keyboard (GTK4): is the fullscreen
translucent "veil" usable, which monitor is the pointer on, and centering a small window on X11
(GTK4 cannot place a window itself). Imported by zgu-game-menu.py and zgu-virtual-keyboard.py."""

import ctypes
import ctypes.util
import os
import shutil
import subprocess

import gi

gi.require_version("Gtk", "4.0")
from gi.repository import Gdk, GLib  # noqa: E402

from zgu_common import load_menu_conf  # noqa: E402


def xdotool_path():
    if shutil.which("xdotool"):
        return "xdotool"
    if os.access("/run/host/usr/bin/xdotool", os.X_OK):
        return "/run/host/usr/bin/xdotool"
    return None


def use_veil():
    """True when the fullscreen translucent veil can be used: the desktop composites (a fullscreen
    window would otherwise hide the game behind an opaque rectangle) and menu.conf does not say
    "backdrop=off"."""
    if os.environ.get("LPM_MENU_FORCE_VEIL") == "1":
        return True
    if load_menu_conf().get("backdrop", "auto").lower() == "off":
        return False
    display = Gdk.Display.get_default()
    return bool(display is not None and display.is_composited())


def _pointer(xdotool):
    mouse = subprocess.run([xdotool, "getmouselocation", "--shell"], check=False,
                           capture_output=True, text=True, timeout=3).stdout
    pos = dict(line.split("=", 1) for line in mouse.split() if "=" in line)
    return int(pos.get("X", 0)), int(pos.get("Y", 0))


def pointer_monitor(session_kind):
    """Monitor under the pointer (X11, through xdotool), else None (Wayland: the compositor
    chooses, usually the focused monitor)."""
    xdotool = xdotool_path()
    if session_kind != "x11" or not xdotool:
        return None
    try:
        px, py = _pointer(xdotool)
        monitors = Gdk.Display.get_default().get_monitors()
        for i in range(monitors.get_n_items()):
            monitor = monitors.get_item(i)
            g = monitor.get_geometry()
            if g.x <= px < g.x + g.width and g.y <= py < g.y + g.height:
                return monitor
    except Exception:
        pass
    return None


def place_on_x11(win, title, where="center", attempt=0, done=None, retry_ms=200, max_attempts=5):
    """Move a small window to the middle ("center") or the bottom middle ("bottom") of the monitor
    under the pointer, with xdotool. Retries a few times while the window is not mapped yet."""
    xdotool = xdotool_path()
    if not xdotool:
        if done:
            done()
        return False
    try:
        found = subprocess.run([xdotool, "search", "--onlyvisible", "--pid", str(os.getpid()),
                                "--name", "^%s$" % title], check=False, capture_output=True,
                               text=True, timeout=3).stdout.split()
        width, height = win.get_width(), win.get_height()
        if not found or width <= 1 or height <= 1:
            if attempt < max_attempts:
                GLib.timeout_add(retry_ms, place_on_x11, win, title, where, attempt + 1, done, retry_ms, max_attempts)
            elif done:
                done()
            return False
        monitor = pointer_monitor("x11")
        monitors = Gdk.Display.get_default().get_monitors()
        if monitor is None and monitors.get_n_items():
            monitor = monitors.get_item(0)
        if monitor is None:
            if done:
                done()
            return False
        geo = monitor.get_geometry()
        x = geo.x + (geo.width - width) // 2
        if where == "topright":
            x = geo.x + geo.width - width - 24
            y = geo.y + 24
        else:
            y = geo.y + (geo.height - height) // 2 if where == "center" else geo.y + geo.height - height - 60
        subprocess.run([xdotool, "windowmove", found[-1], str(x), str(y)], check=False,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=3)
    except Exception:
        pass
    if done:
        done()
    return False


# --- X11 window hints, set BEFORE the window is shown ---------------------------------------------
# Used for windows that must not take the focus (the virtual keyboard, so that the game keeps it and
# keys can be sent to it with no hide / show flicker) or that must not get the desktop's opening
# animation (the little notice). Everything is a plain window property, so it works on any X11
# window manager. On Wayland a client cannot do this: callers keep their other method there.

class _XWMHints(ctypes.Structure):
    _fields_ = [("flags", ctypes.c_long), ("input", ctypes.c_int), ("initial_state", ctypes.c_int),
                ("icon_pixmap", ctypes.c_ulong), ("icon_window", ctypes.c_ulong), ("icon_x", ctypes.c_int),
                ("icon_y", ctypes.c_int), ("icon_mask", ctypes.c_ulong), ("window_group", ctypes.c_ulong)]


def x11_set_hints(win, window_type=None, no_focus=False, above=False):
    """Sets, on the (realized, not yet shown) X11 window: _NET_WM_WINDOW_TYPE_<window_type> (e.g.
    "NOTIFICATION", "UTILITY"), "never takes the focus" (WM_HINTS input=False and no WM_TAKE_FOCUS)
    and "stays above" (_NET_WM_STATE_ABOVE). Returns True when the properties were set."""
    try:
        import gi
        gi.require_version("GdkX11", "4.0")
        from gi.repository import GdkX11  # noqa: F401
        win.realize()
        surface = win.get_surface()
        xid = surface.get_xid()
        lib = ctypes.CDLL(ctypes.util.find_library("X11") or "libX11.so.6")
        lib.XOpenDisplay.restype = ctypes.c_void_p
        lib.XOpenDisplay.argtypes = [ctypes.c_char_p]
        lib.XInternAtom.restype = ctypes.c_ulong
        lib.XInternAtom.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_int]
        lib.XChangeProperty.argtypes = [ctypes.c_void_p, ctypes.c_ulong, ctypes.c_ulong, ctypes.c_ulong,
                                        ctypes.c_int, ctypes.c_int, ctypes.c_void_p, ctypes.c_int]
        lib.XSetWMHints.argtypes = [ctypes.c_void_p, ctypes.c_ulong, ctypes.c_void_p]
        lib.XGetWMProtocols.argtypes = [ctypes.c_void_p, ctypes.c_ulong, ctypes.c_void_p, ctypes.c_void_p]
        lib.XSetWMProtocols.argtypes = [ctypes.c_void_p, ctypes.c_ulong, ctypes.c_void_p, ctypes.c_int]
        display = lib.XOpenDisplay(None)
        if not display:
            return False
        atom = lambda name: lib.XInternAtom(display, name.encode(), 0)  # noqa: E731
        xa_atom, replace = 4, 0
        if window_type:
            value = (ctypes.c_ulong * 1)(atom("_NET_WM_WINDOW_TYPE_" + window_type))
            lib.XChangeProperty(display, xid, atom("_NET_WM_WINDOW_TYPE"), xa_atom, 32, replace, value, 1)
        if above:
            value = (ctypes.c_ulong * 2)(atom("_NET_WM_STATE_ABOVE"), atom("_NET_WM_STATE_STICKY"))
            lib.XChangeProperty(display, xid, atom("_NET_WM_STATE"), xa_atom, 32, replace, value, 2)
        if no_focus:
            # EWMH: a window whose user time is 0 must not get the focus when it is mapped
            lib.XChangeProperty(display, xid, atom("_NET_WM_USER_TIME"), 6, 32, replace,
                                (ctypes.c_ulong * 1)(0), 1)
            hints = _XWMHints(flags=1, input=0)  # InputHint, input = False
            lib.XSetWMHints(display, xid, ctypes.byref(hints))
            protocols = ctypes.POINTER(ctypes.c_ulong)()
            count = ctypes.c_int(0)
            if lib.XGetWMProtocols(display, xid, ctypes.byref(protocols), ctypes.byref(count)):
                take_focus = atom("WM_TAKE_FOCUS")
                keep = [protocols[i] for i in range(count.value) if protocols[i] != take_focus]
                array = (ctypes.c_ulong * max(1, len(keep)))(*keep)
                lib.XSetWMProtocols(display, xid, array, len(keep))
        lib.XFlush.argtypes = [ctypes.c_void_p]
        lib.XFlush(display)
        lib.XCloseDisplay.argtypes = [ctypes.c_void_p]
        lib.XCloseDisplay(display)
        return True
    except Exception:
        return False


def _x11_lib():
    lib = ctypes.CDLL(ctypes.util.find_library("X11") or "libX11.so.6")
    lib.XOpenDisplay.restype = ctypes.c_void_p
    lib.XOpenDisplay.argtypes = [ctypes.c_char_p]
    lib.XGetInputFocus.argtypes = [ctypes.c_void_p, ctypes.POINTER(ctypes.c_ulong), ctypes.POINTER(ctypes.c_int)]
    lib.XSetInputFocus.argtypes = [ctypes.c_void_p, ctypes.c_ulong, ctypes.c_int, ctypes.c_ulong]
    lib.XFlush.argtypes = [ctypes.c_void_p]
    lib.XCloseDisplay.argtypes = [ctypes.c_void_p]
    return lib


def x11_focus_window():
    """The X11 window that has the keyboard focus right now (0 if unknown)."""
    try:
        lib = _x11_lib()
        display = lib.XOpenDisplay(None)
        if not display:
            return 0
        window, revert = ctypes.c_ulong(0), ctypes.c_int(0)
        lib.XGetInputFocus(display, ctypes.byref(window), ctypes.byref(revert))
        lib.XCloseDisplay(display)
        return window.value if window.value > 1 else 0
    except Exception:
        return 0


def x11_restore_focus(xid):
    """Gives the keyboard focus back to a window found with x11_focus_window()."""
    if not xid:
        return
    try:
        lib = _x11_lib()
        display = lib.XOpenDisplay(None)
        if not display:
            return
        lib.XSetInputFocus(display, xid, 2, 0)  # RevertToParent, CurrentTime
        lib.XFlush(display)
        lib.XCloseDisplay(display)
    except Exception:
        pass


def x11_xid(win):
    """X11 window id of a realized GTK window (0 if unknown)."""
    try:
        import gi
        gi.require_version("GdkX11", "4.0")
        from gi.repository import GdkX11  # noqa: F401
        return int(win.get_surface().get_xid())
    except Exception:
        return 0
