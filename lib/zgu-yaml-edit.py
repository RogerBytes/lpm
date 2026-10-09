#!/usr/bin/env python3
"""Targeted edit of a simple value in a Lutris YAML, WITHOUT rewriting the whole file.

Usage: zgu-yaml-edit.py <yml> set   <section> <key> <value> [--bool]
       zgu-yaml-edit.py <yml> unset <section> <key>

"section" is a top-level key (e.g. game, system); "key" is a direct child key of that section.
Writing is done by editing text lines (never yaml.dump): a PyYAML round trip destroys all comments,
including the hooks neutralized by LPM ("# lpm:hook-disabled"), which are used to restore them
later. The result is re-read with yaml.safe_load and compared to what is expected; on any deviation
nothing is modified and the exit code is non-zero (the caller can then fall back to a full rewrite).
"""
import copy
import os
import re
import sys
import tempfile

import yaml

SECTION_RE = r"^{}:\s*(#.*)?$"


def indent_of(line):
    return len(line) - len(line.lstrip(" "))


def is_skippable(line):
    s = line.strip()
    return not s or s.startswith("#")


def quote(value):
    return "'" + value.replace("'", "''") + "'"


def block_end(lines, start, parent_indent):
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


def find_key(lines, start, end, indent, key):
    pat = re.compile(r"^" + " " * indent + r"(?:\"" + re.escape(key) + r"\"|'" + re.escape(key)
                     + r"'|" + re.escape(key) + r")\s*:(\s|$)")
    for i in range(start, end):
        if not is_skippable(lines[i]) and indent_of(lines[i]) == indent and pat.match(lines[i]):
            return i
    return None


def edit(lines, section, key, value):
    """value=None -> removal. Returns the new lines."""
    sec_idx = next((i for i, l in enumerate(lines) if re.match(SECTION_RE.format(re.escape(section)), l)), None)
    if sec_idx is None:
        if value is None:
            return lines
        if lines and not lines[-1].endswith("\n"):
            lines[-1] += "\n"
        lines.append(section + ":\n")
        sec_idx = len(lines) - 1
    sec_end = block_end(lines, sec_idx, 0)
    child = 2
    for i in range(sec_idx + 1, sec_end):
        if not is_skippable(lines[i]):
            child = indent_of(lines[i])
            break
    key_idx = find_key(lines, sec_idx + 1, sec_end, child, key)
    if key_idx is not None:
        key_end = block_end(lines, key_idx, child)
        if value is None:
            return lines[:key_idx] + lines[key_end:]
        return lines[:key_idx] + [" " * child + key + ": " + value + "\n"] + lines[key_end:]
    if value is None:
        return lines
    return lines[:sec_idx + 1] + [" " * child + key + ": " + value + "\n"] + lines[sec_idx + 1:]


def main():
    args = sys.argv[1:]
    if len(args) < 4 or args[1] not in ("set", "unset"):
        sys.exit("usage: zgu-yaml-edit.py <yml> set <section> <key> <value> [--bool] | unset <section> <key>")
    path, action, section, key = args[0], args[1], args[2], args[3]
    if not re.match(r"^[A-Za-z_][A-Za-z0-9_]*$", section) or not re.match(r"^[A-Za-z_][A-Za-z0-9_]*$", key):
        sys.exit("invalid section or key")
    if action == "set":
        if len(args) < 5:
            sys.exit("missing value")
        raw = args[4]
        if "\n" in raw or "\r" in raw:
            sys.exit("newline in value")
        as_bool = "--bool" in args[5:]
        py_value = (raw.lower() == "true") if as_bool else raw
        yaml_value = ("true" if py_value else "false") if as_bool else quote(raw)
    else:
        py_value = None
        yaml_value = None

    with open(path, "r", encoding="utf-8") as f:
        lines = f.readlines()
    before = yaml.safe_load("".join(lines)) or {}
    if not isinstance(before, dict):
        sys.exit("root is not a mapping")
    if section in before and not isinstance(before[section], dict):
        sys.exit("section is not a mapping")

    expected = copy.deepcopy(before)
    if action == "set":
        expected.setdefault(section, {})[key] = py_value
    elif isinstance(expected.get(section), dict):
        expected[section].pop(key, None)

    new_lines = edit(list(lines), section, key, yaml_value)
    try:
        after = yaml.safe_load("".join(new_lines)) or {}
    except yaml.YAMLError as exc:
        sys.exit("refusing to write, result is not valid YAML: %s" % exc)
    if after != expected:
        sys.exit("refusing to write, result differs from expected")
    if new_lines == lines:
        return
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path) or ".", prefix=".lpm-yaml-")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.writelines(new_lines)
        os.chmod(tmp, os.stat(path).st_mode & 0o777)
        os.replace(tmp, path)
    except BaseException:
        if os.path.exists(tmp):
            os.unlink(tmp)
        raise


if __name__ == "__main__":
    main()
