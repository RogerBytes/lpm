#!/usr/bin/env python3
"""Read / edit the environment variables of ONE game (system.env in its Lutris YAML).

Usage: zgu-env-edit.py <yml> list
       zgu-env-edit.py <yml> set KEY VALUE
       zgu-env-edit.py <yml> unset KEY
       zgu-env-edit.py <yml> apply <file of KEY=VALUE lines>

Writing is done by editing text lines (never yaml.dump): a PyYAML round trip destroys comments,
including the hooks neutralized by LPM ("# lpm:hook-disabled"). The result is re-read with
yaml.safe_load before being written; on any deviation from what is expected, nothing is modified.
"""
import os
import re
import sys
import tempfile

import yaml

KEY_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")


def indent_of(line):
    return len(line) - len(line.lstrip(" "))


def is_skippable(line):
    s = line.strip()
    return not s or s.startswith("#")


def load_env(path):
    with open(path, "r", encoding="utf-8") as f:
        data = yaml.safe_load(f) or {}
    system = data.get("system") if isinstance(data, dict) else None
    env = system.get("env") if isinstance(system, dict) else None
    if not isinstance(env, dict):
        return {}
    return {str(k): ("" if v is None else str(v)) for k, v in env.items()}


def quote(value):
    return "'" + value.replace("'", "''") + "'"


def entry_line(key, value, indent):
    return " " * indent + key + ": " + quote(value) + "\n"


def block_end(lines, start, parent_indent):
    """End (exclusive) of the child block of line `start` with indentation parent_indent,
    not counting trailing comments/blank lines."""
    i = start + 1
    last = start
    while i < len(lines):
        if is_skippable(lines[i]):
            i += 1
            continue
        if indent_of(lines[i]) <= parent_indent:
            break
        last = i
        i += 1
    return last + 1


def edit_lines(lines, desired):
    current_env = load_env_from_lines(lines)
    # --- locate / create system: then env: ---
    sys_idx = next((i for i, l in enumerate(lines)
                    if re.match(r"^system:\s*(#.*)?$", l)), None)
    if sys_idx is None:
        if lines and not lines[-1].endswith("\n"):
            lines[-1] += "\n"
        lines.append("system:\n")
        sys_idx = len(lines) - 1
    sys_end = block_end(lines, sys_idx, 0)
    child = 2
    for i in range(sys_idx + 1, sys_end):
        if not is_skippable(lines[i]):
            child = indent_of(lines[i])
            break
    env_idx = next((i for i in range(sys_idx + 1, sys_end)
                    if indent_of(lines[i]) == child
                    and re.match(r"^env:\s*(\{\s*\}\s*)?(#.*)?$", lines[i].strip())), None)
    if env_idx is None:
        if not desired:
            return lines
        lines.insert(sys_idx + 1, " " * child + "env:\n")
        env_idx = sys_idx + 1
    else:
        lines[env_idx] = " " * child + "env:\n"
    env_end = block_end(lines, env_idx, child)
    entry_indent = child + 2
    for i in range(env_idx + 1, env_end):
        if not is_skippable(lines[i]):
            entry_indent = indent_of(lines[i])
            break
    # --- in-place removals / modifications ---
    key_re = re.compile(r"^(\s*)(?:\"([^\"]+)\"|'([^']+)'|([^:#\s][^:]*?))\s*:(\s|$)")
    out_block = []
    seen = set()
    for i in range(env_idx + 1, env_end):
        line = lines[i]
        m = key_re.match(line) if not is_skippable(line) and indent_of(line) == entry_indent else None
        if not m:
            out_block.append(line)
            continue
        key = m.group(2) or m.group(3) or m.group(4)
        if key not in desired:
            continue
        seen.add(key)
        if current_env.get(key) != desired[key]:
            out_block.append(entry_line(key, desired[key], entry_indent))
        else:
            out_block.append(line)
    for key, value in desired.items():
        if key not in seen:
            out_block.append(entry_line(key, value, entry_indent))
    return lines[:env_idx + 1] + out_block + lines[env_end:]


def load_env_from_lines(lines):
    data = yaml.safe_load("".join(lines)) or {}
    system = data.get("system") if isinstance(data, dict) else None
    env = system.get("env") if isinstance(system, dict) else None
    if not isinstance(env, dict):
        return {}
    return {str(k): ("" if v is None else str(v)) for k, v in env.items()}


def write_desired(path, desired):
    for k, v in desired.items():
        if not KEY_RE.match(k):
            sys.exit("invalid variable name: %s" % k)
        if "\n" in v or "\r" in v:
            sys.exit("newline in value of %s" % k)
    with open(path, "r", encoding="utf-8") as f:
        lines = f.readlines()
    new_lines = edit_lines(list(lines), desired)
    try:
        check = load_env_from_lines(new_lines)
    except yaml.YAMLError as exc:
        sys.exit("refusing to write, result is not valid YAML: %s" % exc)
    if check != desired:
        sys.exit("refusing to write, result differs from expected")
    if new_lines == lines:
        return
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path) or ".", prefix=".lpm-env-")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.writelines(new_lines)
        os.chmod(tmp, os.stat(path).st_mode & 0o777)
        os.replace(tmp, path)
    except BaseException:
        if os.path.exists(tmp):
            os.unlink(tmp)
        raise


def main():
    if len(sys.argv) < 3:
        sys.exit("usage: zgu-env-edit.py <yml> list|set|unset|apply ...")
    path, action = sys.argv[1], sys.argv[2]
    env = load_env(path)
    if action == "list":
        for k, v in env.items():
            print("%s=%s" % (k, v))
    elif action == "set" and len(sys.argv) == 5:
        env[sys.argv[3]] = sys.argv[4]
        write_desired(path, env)
    elif action == "unset" and len(sys.argv) == 4:
        env.pop(sys.argv[3], None)
        write_desired(path, env)
    elif action == "apply" and len(sys.argv) == 4:
        desired = {}
        with open(sys.argv[3], "r", encoding="utf-8") as f:
            for raw in f:
                raw = raw.rstrip("\r\n")
                if not raw.strip():
                    continue
                if "=" not in raw:
                    sys.exit("invalid line (expected KEY=VALUE): %s" % raw)
                k, v = raw.split("=", 1)
                desired[k.strip()] = v
        write_desired(path, desired)
    else:
        sys.exit("usage: zgu-env-edit.py <yml> list|set KEY VALUE|unset KEY|apply FILE")


if __name__ == "__main__":
    main()
