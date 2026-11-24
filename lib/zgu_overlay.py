"""Window helpers shared by the in-game menu and the virtual keyboard (GTK4): is the fullscreen
translucent "veil" usable, which monitor is the pointer on, and centering a small window on X11
(GTK4 cannot place a window itself). Imported by zgu-game-menu.py and zgu-virtual-keyboard.py."""

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


def place_on_x11(win, title, where="center", attempt=0):
    """Move a small window to the middle ("center") or the bottom middle ("bottom") of the monitor
    under the pointer, with xdotool. Retries a few times while the window is not mapped yet."""
    xdotool = xdotool_path()
    if not xdotool:
        return False
    try:
        found = subprocess.run([xdotool, "search", "--onlyvisible", "--pid", str(os.getpid()),
                                "--name", "^%s$" % title], check=False, capture_output=True,
                               text=True, timeout=3).stdout.split()
        width, height = win.get_width(), win.get_height()
        if not found or width <= 1 or height <= 1:
            if attempt < 5:
                GLib.timeout_add(200, place_on_x11, win, title, where, attempt + 1)
            return False
        monitor = pointer_monitor("x11")
        monitors = Gdk.Display.get_default().get_monitors()
        if monitor is None and monitors.get_n_items():
            monitor = monitors.get_item(0)
        if monitor is None:
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
    return False
