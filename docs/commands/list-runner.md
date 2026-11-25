# ludis list-runner

Lists the Wine/Proton runners installed for Lutris, one name per line.

## Synopsis

```
ludis list-runner
```

## Description

Prints the names of the sub-folders of Lutris' Wine runners directory, sorted. These names are what [`ludis uninstall-runner`](uninstall-runner.md) and [`ludis pack-runner`](pack-runner.md) expect, and what the `wine.version` entry of a game's Lutris configuration refers to.

## Arguments

None. Any argument is ignored (the router does not pass arguments to this script).

## Options

None. The global options are accepted by the router but have no effect (see [Global options](options.md)).

## Behavior

1. **Lutris detection**: Flatpak or native. If both are installed, the choice saved by [`ludis lutris-version`](lutris-version.md) (or `LUDIS_LUTRIS_VERSION=flatpak|native`) is used; otherwise ludis asks (see Scripting notes). If neither is found: "Error: Lutris is not installed on this system.", exit 1.
2. **Runners folder**: `~/.var/app/net.lutris.Lutris/data/lutris/runners/wine` (Flatpak) or `~/.local/share/lutris/runners/wine` (native). If it does not exist: "Error: Runner folder not found: <path>", exit 1.
3. The immediate sub-directories are listed (regular files and hidden folders, whose name starts with `.`, are ignored), sorted with `sort`, so the order follows the current locale (for example, upper-case names may come before lower-case ones).
4. If there is none, "No runner installed." is printed on **standard error** and the command exits 0 with an empty standard output.

## Output

Standard output contains only runner names, one per line, and nothing else:

```
GE-Proton9-1
Zeta
wine-ge-8-26
```

## Exit status

| Code | Meaning |
|---|---|
| 0 | Success (including "No runner installed."). |
| 1 | Lutris not found, or runners folder missing. |

## Scripting notes

- Standard output is safe to parse: names only, one per line, no decoration, no colour. "No runner installed." goes to standard error, so an empty folder gives an empty standard output.
- Names may contain spaces in theory; read line by line (`while IFS= read -r`), do not word-split.
- The only possible prompt is the dual-Lutris choice (both Flatpak and native Lutris installed, nothing saved). The question goes to standard error and is read from standard input; an empty answer or end of input selects Flatpak **and saves that choice**. Avoid it by exporting `LUDIS_LUTRIS_VERSION=flatpak` or `native`, or by running `ludis lutris-version flatpak|native` once.
- An error (exit 1) is also appended to the ludis log ([`ludis log`](log.md)).

## Examples

```
ludis list-runner
ludis list-runner 2>/dev/null | grep -c .
LUDIS_LUTRIS_VERSION=native ludis list-runner
```

## Files and data touched

- Reads: the runners folder (directory names only); `~/.config/ludis/lutris-version`.
- Writes: `~/.config/ludis/lutris-version` (only when the dual-Lutris prompt is answered or a stale saved choice is discarded); `~/.local/share/ludis/ludis.log` (errors).

## See also

[`ludis list-remote-runners`](list-remote-runners.md), [`ludis install-runner`](install-runner.md), [`ludis uninstall-runner`](uninstall-runner.md), [`ludis pack-runner`](pack-runner.md), [`ludis lutris-version`](lutris-version.md)
