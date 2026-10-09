#!/usr/bin/env python3
"""Read / edit the "VSync disabled" settings of ONE game (system.env of its Lutris YAML).

Usage: zgu-vsync-edit.py <yml> status
       zgu-vsync-edit.py <yml> on  [setting...]
       zgu-vsync-edit.py <yml> off [setting...]
       zgu-vsync-edit.py any       (reads "slug<TAB>path.yml" lines on stdin and
                                    prints the slugs with at least one active setting)

Settings (no argument: all):
  d3d9       DXVK_CONFIG: d3d9.presentInterval = 0
  d3d11      DXVK_CONFIG: dxgi.syncInterval = 0            (Direct3D 10 and 11)
  d3d12      VKD3D_SWAPCHAIN_PRESENT_MODE=IMMEDIATE        (VKD3D-Proton)
  gl-nvidia  __GL_SYNC_TO_VBLANK=0                         (OpenGL, proprietary NVIDIA driver)
  gl-mesa    vblank_mode=0                                 (OpenGL, Mesa)

Sources: official dxvk.conf (dxgi.syncInterval, d3d9.presentInterval), DXVK README (several options
in DXVK_CONFIG separated by ";"), VKD3D-Proton README (VKD3D_SWAPCHAIN_PRESENT_MODE), NVIDIA driver
README (__GL_SYNC_TO_VBLANK).

DXVK_CONFIG is MERGED, never overwritten: "on" only adds or fixes our options, "off" only removes
our options (and deletes the variable if it becomes empty). The other variables are only removed if
their value is exactly the one set by "on"; a different user-chosen value is never touched by "off".

The YAML is written through zgu-env-edit.py (line editing, comments kept, result re-read and
verified before writing).
"""
import importlib.util
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))

DXVK = "DXVK_CONFIG"

# id -> (variable, DXVK option or None, value)
SETTINGS = {
    "d3d9": (DXVK, "d3d9.presentInterval", "0"),
    "d3d11": (DXVK, "dxgi.syncInterval", "0"),
    "d3d12": ("VKD3D_SWAPCHAIN_PRESENT_MODE", None, "IMMEDIATE"),
    "gl-nvidia": ("__GL_SYNC_TO_VBLANK", None, "0"),
    "gl-mesa": ("vblank_mode", None, "0"),
}


def load_env_edit():
    spec = importlib.util.spec_from_file_location("zgu_env_edit", os.path.join(HERE, "zgu-env-edit.py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def split_options(value):
    """DXVK_CONFIG -> list of (key, value); options are separated by ";"."""
    options = []
    for part in value.split(";"):
        part = part.strip()
        if not part:
            continue
        if "=" in part:
            key, val = part.split("=", 1)
            options.append((key.strip(), val.strip()))
        else:
            options.append((part, ""))
    return options


def join_options(options):
    return "; ".join("%s = %s" % (k, v) if v != "" else k for k, v in options)


def is_on(env, setting):
    var, option, wanted = SETTINGS[setting]
    value = env.get(var)
    if value is None:
        return False
    if option is not None:
        return any(k == option and v == wanted for k, v in split_options(value))
    return value.strip().upper() == wanted.upper()


def apply(env, setting, enable):
    var, option, wanted = SETTINGS[setting]
    if option is not None:
        options = split_options(env.get(var, ""))
        options = [(k, v) for k, v in options if k != option]
        if enable:
            options.append((option, wanted))
        if options:
            env[var] = join_options(options)
        else:
            env.pop(var, None)
        return
    if enable:
        env[var] = wanted
    elif is_on(env, setting):
        env.pop(var, None)


def parse_settings(names):
    if not names:
        return list(SETTINGS)
    for name in names:
        if name not in SETTINGS:
            sys.exit("unknown setting: %s (expected: %s)" % (name, ", ".join(SETTINGS)))
    return list(dict.fromkeys(names))


def main():
    env_edit = load_env_edit()
    if len(sys.argv) == 2 and sys.argv[1] == "any":
        for raw in sys.stdin:
            raw = raw.rstrip("\r\n")
            if "\t" not in raw:
                continue
            slug, path = raw.split("\t", 1)
            try:
                env = env_edit.load_env(path)
            except Exception:
                continue
            if any(is_on(env, s) for s in SETTINGS):
                print(slug)
        return
    if len(sys.argv) < 3:
        sys.exit("usage: zgu-vsync-edit.py <yml> status|on|off [setting...]")
    path, action = sys.argv[1], sys.argv[2]
    env = env_edit.load_env(path)
    if action == "status":
        if len(sys.argv) != 3:
            sys.exit("usage: zgu-vsync-edit.py <yml> status")
        for setting in SETTINGS:
            print("%s=%s" % (setting, "on" if is_on(env, setting) else "off"))
    elif action in ("on", "off"):
        for setting in parse_settings(sys.argv[3:]):
            apply(env, setting, action == "on")
        env_edit.write_desired(path, env)
    else:
        sys.exit("usage: zgu-vsync-edit.py <yml> status|on|off [setting...]")


if __name__ == "__main__":
    main()
