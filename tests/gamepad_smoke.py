#!/usr/bin/env python3
"""Test of the gamepad watcher (lib/zgu-gamepad-alttab-watcher.py) WITHOUT a gamepad or real
SDL: the SDL object is replaced by a fake whose button state follows a scenario, and the
keyboard commands that would be sent (xdotool on X11, ydotool on Wayland) are recorded.

Run: python3 tests/gamepad_smoke.py   (only needs libSDL2 installed, like the script itself;
no gamepad, no display).
"""
import importlib.util
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PATH = os.path.join(ROOT, "lib", "zgu-gamepad-alttab-watcher.py")

BTN = dict(BACK=4, L3=7, R3=8, L1=9, R1=10, UP=11, DOWN=12, LEFT=13, RIGHT=14)
AX_L2, AX_R2 = 4, 5
COMBO = ("L1", "R1", "R3")


def run(session, script):
    """script: list of (pressed buttons, trigger combo?) -- one item per tick."""
    sys.argv = ["zgu-gamepad-alttab-watcher.py", session]
    spec = importlib.util.spec_from_file_location("alttab_watcher_%s" % session, PATH)
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)

    state = {"tick": 0}

    class FakeSDL:
        def SDL_GameControllerUpdate(self): pass
        def SDL_NumJoysticks(self): return 1
        def SDL_IsGameController(self, i): return 1
        def SDL_GameControllerOpen(self, i): return 1
        def SDL_GameControllerClose(self, h): pass
        def SDL_Quit(self): pass

        def SDL_GameControllerGetButton(self, pad, code):
            pressed, _ = script[min(state["tick"], len(script) - 1)]
            return 1 if any(BTN[name] == code for name in pressed) else 0

        def SDL_GameControllerGetAxis(self, pad, code):
            _, triggers = script[min(state["tick"], len(script) - 1)]
            return 32767 if triggers else 0

    calls = []
    m.sdl = FakeSDL()
    m.XDOTOOL_BIN = "xdotool"
    m._run_best_effort = lambda argv: calls.append(" ".join(argv))
    m.shutil.which = lambda name: "/usr/bin/" + name if name in ("ydotool", "xdotool") else None
    m._find_antimicro_pids = lambda: []

    def fake_sleep(_):
        state["tick"] += 1
        if state["tick"] >= len(script):
            m.running = False

    m.time.sleep = fake_sleep
    m.main()
    return calls


def held(*names):
    return list(COMBO) + list(names), True


FREE = ([], False)
scenario = [
    (["BACK"], False),          # Select held BEFORE the combo: must trigger nothing
    held("BACK"),               # combo completed with Select already held: nothing either
    held("UP"), held("UP"),     # Up / Down / Select during the hold: no longer shortcuts
    held("DOWN"), held(),
    held("BACK"), held(),
    held("LEFT"), held(),
    FREE,                       # combo released
    (["UP"], False),            # Up outside the combo: must send nothing
]

ok = True


def expect(label, got, want):
    global ok
    if got != want:
        ok = False
        print("FAILED %s:\n   got     : %s\n   expected: %s" % (label, got, want))
    else:
        print("OK: " + label)


x11 = run("x11", scenario)
expect("X11", x11, [
    "xdotool keydown alt",
    "xdotool key shift+Tab",
    "xdotool keyup alt",
])

wl = run("wayland", scenario)
expect("Wayland", wl, [
    "ydotool key 56:1",
    "ydotool key 42:1 15:1 15:0 42:0",
    "ydotool key 56:0",
])


# --- End-of-game detection (lib/zgu-prefix-watch.py) -------------------------------------
import subprocess
import tempfile
import time

spec = importlib.util.spec_from_file_location("pw", os.path.join(ROOT, "lib", "zgu-prefix-watch.py"))
pw = importlib.util.module_from_spec(spec)
spec.loader.exec_module(pw)


def watch_scenario(alive_by_time, times):
    """alive_by_time(t) -> is the game alive at time t; returns game_ended() for each t."""
    now = {"t": 0.0}
    w = pw.GameEndWatch("/tmp", alive=lambda _p: alive_by_time(now["t"]), clock=lambda: now["t"])
    out = []
    for t in times:
        now["t"] = t
        out.append(w.game_ended())
    return out


times = list(range(0, 16))
expect("game end: never seen -> never stops", watch_scenario(lambda t: False, times), [False] * 16)
expect("game end: seen then gone -> stops after the grace period",
       watch_scenario(lambda t: t < 5, times),
       [False] * 8 + [True] * 8)   # last seen at t=4, gone for 4 s at t=8
expect("game end: short gap (< delay) -> no stop",
       watch_scenario(lambda t: not (6 <= t < 8), times), [False] * 16)
expect("game end: no prefix folder -> never stops",
       [pw.GameEndWatch("").game_ended()], [False])

# Real /proc detection: a process named "wineserver" whose environment holds WINEPREFIX.
with tempfile.TemporaryDirectory() as tmp:
    prefix = os.path.join(tmp, "game", "pfx")
    os.makedirs(prefix)
    fake = os.path.join(tmp, "wineserver")
    os.symlink("/bin/sleep", fake)
    proc = subprocess.Popen([fake, "30"], env={"WINEPREFIX": prefix})
    try:
        for _ in range(100):  # wait for the process to have exec'd (its name appears in /proc)
            if pw.prefix_alive(os.path.join(tmp, "game")):
                break
            time.sleep(0.05)
        expect("/proc detection: prefix wineserver alive", pw.prefix_alive(os.path.join(tmp, "game")), True)
        expect("/proc detection: other folder", pw.prefix_alive(os.path.join(tmp, "other")), False)
    finally:
        proc.kill()
        proc.wait()
    expect("/proc detection: after stop", pw.prefix_alive(os.path.join(tmp, "game")), False)


# --- Random order of the help lines (lib/zgu_screen_config.py) ---------------------------
import ast
import random

tree = ast.parse(open(os.path.join(ROOT, "lib", "zgu_screen_config.py")).read())
func = next(n for n in tree.body if isinstance(n, ast.FunctionDef) and n.name == "extend_help_sequence")
namespace = {"random": random}
exec(compile(ast.Module([func], []), "extend_help_sequence", "exec"), namespace)
extend = namespace["extend_help_sequence"]

good = True
for count in (2, 3, 5):
    for _ in range(300):
        seq = []
        extend(seq, count, 200)
        if any(a == b for a, b in zip(seq, seq[1:])):
            good = False
        for i in range(0, len(seq) - count, count):
            if sorted(seq[i:i + count]) != list(range(count)):
                good = False
expect("random order: never the same line twice in a row, every round complete", good, True)
varied = {tuple(s) for s in ([x for x in (lambda q: (extend(q, 5, 4), q)[1])([])][:5] for _ in range(50))}
expect("random order: the order changes between draws", len(varied) > 1, True)
seq1 = []
extend(seq1, 1, 5)
expect("random order: single line", seq1[:6], [0] * 6)

# --- Hot-plug: sync_controllers follows controllers that appear, disappear and come back (SDL
# virtual joystick: no real device needed).
import ctypes
os.environ.setdefault("SDL_VIDEODRIVER", "dummy")
sys.path.insert(0, os.path.join(ROOT, "lib"))
import zgu_common
_sdl = zgu_common.load_sdl2()
if _sdl is not None and hasattr(_sdl, "SDL_JoystickAttachVirtual") and zgu_common.init_sdl(_sdl):
    _sdl.SDL_JoystickAttachVirtual.restype = ctypes.c_int
    _sdl.SDL_JoystickAttachVirtual.argtypes = [ctypes.c_int] * 4
    _sdl.SDL_JoystickDetachVirtual.argtypes = [ctypes.c_int]
    _pads, _log = [], []
    _sync = lambda: zgu_common.sync_controllers(_sdl, _pads, lambda h: _log.append("add"), lambda h: _log.append("rm"))
    _sync()
    expect("hot-plug: no controller at start", len(_pads), 0)
    _dev = _sdl.SDL_JoystickAttachVirtual(1, 6, 15, 0)
    _sync()
    _sync()
    expect("hot-plug: controller connected later is opened once", (len(_pads), _log), (1, ["add"]))
    _sdl.SDL_JoystickDetachVirtual(_dev)
    _sync()
    expect("hot-plug: disconnected controller is dropped", (len(_pads), _log), (0, ["add", "rm"]))
    _dev = _sdl.SDL_JoystickAttachVirtual(1, 6, 15, 0)
    _sync()
    expect("hot-plug: reconnected controller is opened again", (len(_pads), _log), (1, ["add", "rm", "add"]))

# --- LPM menu opener (lib/zgu-gamepad-exit-watcher.py) ------------------------------------
print("--- menu opener")
expect("hotkey: default", zgu_common.parse_keyboard_hotkey("ctrl+shift+m"), ([(29, 97), (42, 54)], 50))
expect("hotkey: none disables", zgu_common.parse_keyboard_hotkey("none"), None)
expect("hotkey: garbage ignored", zgu_common.parse_keyboard_hotkey("ctrl+bidule"), None)

def load_exit_watcher(conf_text=None):
    import tempfile
    cfg = tempfile.mkdtemp()
    if conf_text is not None:
        os.makedirs(os.path.join(cfg, "lpm"))
        open(os.path.join(cfg, "lpm", "menu.conf"), "w").write(conf_text)
    os.environ["XDG_CONFIG_HOME"] = cfg
    sys.argv = ["zgu-gamepad-exit-watcher.py", "x11", "/tmp"]
    sp = importlib.util.spec_from_file_location("exit_w", os.path.join(ROOT, "lib", "zgu-gamepad-exit-watcher.py"))
    mod = importlib.util.module_from_spec(sp)
    sp.loader.exec_module(mod)
    return mod

w = load_exit_watcher()
expect("combo: default = 4 buttons + 2 triggers", (len(w.COMBO_BUTTONS), len(w.COMBO_AXES)), (4, 2))
w = load_exit_watcher("gamepad_combo=L1,R1\nkeyboard_hotkey=ctrl+f12\n")
expect("combo: configurable", (len(w.COMBO_BUTTONS), len(w.COMBO_AXES), w.KEYBOARD_HOTKEY), (2, 0, ([(29, 97)], 88)))
w = load_exit_watcher("gamepad_combo=L1,bidule\n")
expect("combo: typo falls back to the default", (len(w.COMBO_BUTTONS), len(w.COMBO_AXES)), (4, 2))

# Gamepad: the menu opens once per press (rising edge), not while held, and again after release.
w = load_exit_watcher()
FULL = ["L1", "R1", "L3", "R3"]
seq = [([], False), (FULL, True), (FULL, True), (FULL, True), ([], False), (FULL, True), ([], False)]
state = {"t": 0}
opened = []

class Fake2:
    def SDL_GameControllerUpdate(self): pass
    def SDL_NumJoysticks(self): return 1
    def SDL_IsGameController(self, i): return 1
    def SDL_GameControllerOpen(self, i): return 1
    def SDL_GameControllerClose(self, h): pass
    def SDL_Quit(self): pass
    def SDL_GameControllerGetButton(self, pad, code):
        pressed, _ = seq[min(state["t"], len(seq) - 1)]
        return 1 if any(BTN[n] == code for n in pressed) else 0
    def SDL_GameControllerGetAxis(self, pad, code):
        return 32767 if seq[min(state["t"], len(seq) - 1)][1] else 0

w.sdl = Fake2()
w.MenuLauncher.open = lambda self, source="": opened.append(state["t"])
w.MenuLauncher.close = lambda self: None
def fake_sleep2(_):
    state["t"] += 1
    if state["t"] >= len(seq):
        w.running = False
w.time.sleep = fake_sleep2
w.main()
expect("menu opens once per combo press", opened, [1, 5])

# Keyboard: real struct input_event through a pipe.
import struct as _st
r, wfd = os.pipe()
os.set_blocking(r, False)
kb = w.KeyboardHotkey(([(29, 97), (42, 54)], 50))
kb.fds = {"fake": r}
kb.next_scan = 1e18
def ev(code, value):
    os.write(wfd, _st.pack("llHHi", 0, 0, 1, code, value))
ev(29, 1); ev(42, 1)
expect("keyboard: modifiers alone do nothing", kb.poll(0.05), False)
ev(50, 1)
expect("keyboard: Ctrl+Shift+M triggers", kb.poll(0.05), True)
ev(50, 2)
expect("keyboard: key repeat does not retrigger", kb.poll(0.05), False)
ev(50, 0); ev(50, 1)
expect("keyboard: new press triggers again", kb.poll(0.05), True)
ev(50, 0); ev(42, 0); ev(54, 1); ev(50, 1)
expect("keyboard: right Shift works too", kb.poll(0.05), True)

sys.exit(0 if ok else 1)
