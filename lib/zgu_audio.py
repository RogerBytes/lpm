"""Master volume of the machine (the default output), for the in-game menu.

PipeWire (wpctl) or PulseAudio / pipewire-pulse (pactl): both work on X11 and Wayland whatever
the desktop. Nothing is installed or configured: when neither tool exists, available() is False
and the menu does not show the volume entries."""

import re
import shutil
import subprocess

STEP = 5     # percent per press
MAXIMUM = 100  # no amplification above 100 %


def _tool():
    for name in ("wpctl", "pactl"):
        if shutil.which(name):
            return name
    return None


def available():
    return _tool() is not None


def _run(args):
    try:
        out = subprocess.run(args, capture_output=True, text=True, timeout=2, check=False)
        return out.stdout
    except (OSError, subprocess.SubprocessError):
        return ""


def get_volume():
    """Volume of the default output in percent (0..100), None when it cannot be read."""
    tool = _tool()
    if tool == "wpctl":
        match = re.search(r"Volume:\s*([0-9.]+)", _run(["wpctl", "get-volume", "@DEFAULT_AUDIO_SINK@"]))
        if match:
            return max(0, min(MAXIMUM, int(round(float(match.group(1)) * 100))))
    elif tool == "pactl":
        match = re.search(r"(\d+)%", _run(["pactl", "get-sink-volume", "@DEFAULT_SINK@"]))
        if match:
            return max(0, min(MAXIMUM, int(match.group(1))))
    return None


def set_volume(percent):
    percent = max(0, min(MAXIMUM, int(percent)))
    tool = _tool()
    if tool == "wpctl":
        _run(["wpctl", "set-volume", "@DEFAULT_AUDIO_SINK@", "%.2f" % (percent / 100.0)])
    elif tool == "pactl":
        _run(["pactl", "set-sink-volume", "@DEFAULT_SINK@", "%d%%" % percent])


def get_mute():
    tool = _tool()
    if tool == "wpctl":
        return "[MUTED]" in _run(["wpctl", "get-volume", "@DEFAULT_AUDIO_SINK@"])
    if tool == "pactl":
        return bool(re.search(r"yes", _run(["pactl", "get-sink-mute", "@DEFAULT_SINK@"]), re.I))
    return False


def set_mute(muted):
    tool = _tool()
    if tool == "wpctl":
        _run(["wpctl", "set-mute", "@DEFAULT_AUDIO_SINK@", "1" if muted else "0"])
    elif tool == "pactl":
        _run(["pactl", "set-sink-mute", "@DEFAULT_SINK@", "1" if muted else "0"])
