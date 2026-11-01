#!/usr/bin/env python3
"""Adds "system.env.GAMEID: umu-<id>" to a game's Lutris YAML when the game runs with Proton/umu and has none,
and prints the window class (WM_CLASS "steam_app_<id>") the game's window will have, so the .desktop shortcut
can match it (StartupWMClass). Prints nothing when it does not apply (classic Wine build, no YAML, YAML that
cannot be edited safely, PyYAML missing).

Called by zgu_write_game_shortcut (lib/zgu-desktop-utils.sh). Input by environment:
  YML_PATH   Lutris YAML of the game
  RUNNER_DIR folder holding the Wine/Proton builds (the build is a Proton one if it has toolmanifest.vdf)
  GAME_ID    the game's Lutris id
"""
import os, re, sys

yml_path = os.environ["YML_PATH"]
runner_dir = os.environ["RUNNER_DIR"]
game_id = os.environ["GAME_ID"]

try:
    import yaml
except Exception:
    sys.exit(0)

try:
    with open(yml_path, "r") as f:
        raw_text = f.read()
    data = yaml.safe_load(raw_text)
except Exception:
    sys.exit(0)

if not isinstance(data, dict):
    sys.exit(0)

wine_version = data.get("wine", {}).get("version", "") if isinstance(data.get("wine"), dict) else ""
if not wine_version:
    sys.exit(0)

# Same check umu-run does to validate a PROTONPATH: a classic wine build folder never has this file.
if not os.path.isfile(os.path.join(runner_dir, wine_version, "toolmanifest.vdf")):
    sys.exit(0)

system_cfg = data.get("system")
env_cfg = system_cfg.get("env") if isinstance(system_cfg, dict) else None

existing = env_cfg.get("GAMEID") if isinstance(env_cfg, dict) else None
if existing:
    # Never overwrite a GAMEID already set by hand: the expected WM_CLASS is only deduced if it follows
    # the pattern recognized by umu-run (see umu_run.py); otherwise we cannot know the result, so bail out.
    m = re.match(r"^umu-([\d\w]+)$", str(existing))
    if m:
        print(f"steam_app_{m.group(1)}")
    sys.exit(0)

# --- Targeted text insertion: never "yaml.safe_load" + "yaml.dump" to rewrite the whole file. A
# standard YAML parser ignores comments (a line "# prelaunch_command: ...  # lpm:hook-disabled" does
# not exist for it), so a full roundtrip would silently erase every hook currently neutralized by
# zgu_apply_hook_policy. Only the missing GAMEID line is added, by plain text manipulation of the
# file lines; "data"/"raw_text" above only DECIDE whether a write is needed, never produce it.
lines = raw_text.splitlines()


def indent_of(line):
    return len(line) - len(line.lstrip(" "))


def find_top_block(key):
    """Intervalle [start, end) (end exclu) du bloc top-level "<key>:", ou None si la
    cle n existe pas a l indentation 0."""
    for i, line in enumerate(lines):
        if line.startswith(key + ":") and indent_of(line) == 0:
            j = i + 1
            while j < len(lines) and (lines[j].strip() == "" or indent_of(lines[j]) > 0):
                j += 1
            return i, j
    return None


def child_indent(start, end, own_indent):
    """Indentation de la premiere ligne non vide du bloc -- repli a "own_indent + 2"
    (convention 2-espaces constatee partout ailleurs dans ce projet) si le bloc est
    vide."""
    for k in range(start + 1, end):
        if lines[k].strip() != "":
            return indent_of(lines[k])
    return own_indent + 2


system_block = find_top_block("system")

if system_block is None:
    # No "system:" key at all -- appended at end of file with its "env:" and the GAMEID key.
    if lines and lines[-1].strip() != "":
        lines.append("")
    lines.extend(["system:", "  env:", f"    GAMEID: umu-{game_id}"])
else:
    sys_start, sys_end = system_block
    sys_child_indent = child_indent(sys_start, sys_end, 0)
    env_block = None
    for i in range(sys_start + 1, sys_end):
        if lines[i].strip().startswith("env:") and indent_of(lines[i]) == sys_child_indent:
            j = i + 1
            while j < sys_end and (lines[j].strip() == "" or indent_of(lines[j]) > sys_child_indent):
                j += 1
            env_block = (i, j)
            break

    if env_block is None:
        # "system:" exists but without "env:" -- inserted as first child of the block.
        lines[sys_start + 1:sys_start + 1] = [
            " " * sys_child_indent + "env:",
            " " * (sys_child_indent + 2) + f"GAMEID: umu-{game_id}",
        ]
    else:
        env_start, env_end = env_block
        # "env: {}" (inline empty mapping, as written by a YAML dump) cannot take an indented
        # child: it is turned into a block "env:" first. Any other inline value is left alone
        # (nothing is written) rather than producing an invalid file.
        env_inline = lines[env_start].split("env:", 1)[1].split("#", 1)[0].strip()
        if env_inline == "{}":
            lines[env_start] = lines[env_start].split("env:", 1)[0] + "env:"
        elif env_inline != "":
            sys.exit(0)
        env_child_indent = child_indent(env_start, env_end, indent_of(lines[env_start]))
        lines.insert(env_end, " " * env_child_indent + f"GAMEID: umu-{game_id}")

try:
    with open(yml_path, "w") as f:
        f.write("\n".join(lines) + "\n")
except Exception:
    sys.exit(0)

print(f"steam_app_{game_id}")
