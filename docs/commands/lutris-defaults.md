# ludis lutris-defaults

Shows or sets two defaults of Lutris that apply to every Wine game: the default runner, and which winetricks games use.

## Synopsis

```
ludis lutris-defaults [status]
ludis lutris-defaults runner [<name>]
ludis lutris-defaults winetricks [system|runner]
ludis lutris-defaults apply [runner=<name>] [winetricks=system|runner]
```

## Description

These are the settings of the `wine` section of Lutris' own file `runners/wine.yml` (the same ones as in Lutris, Preferences > Runners > Wine). They apply to every game that does not have its own value: **a game that has its own runner or winetricks setting keeps it**. For one game, see [`ludis tools`](tools.md) (`runner`, `system-winetricks`).

- `runner`: the Wine or Proton runner used by default (the `version` key of Lutris).
- `winetricks`: `runner` (the winetricks bundled with Lutris, the default) or `system` (the one installed on your system), the `system_winetricks` key of Lutris.

Only that file is edited, and only these two keys; your other settings in it are kept.

## Arguments

| Argument | Meaning |
|---|---|
| (none), `status` | Prints the two current values. |
| `runner` | Prints the default runner, or `default` if none is set. |
| `runner <name>` | Sets it. The runner must be installed (see [`ludis list-runner`](list-runner.md)); the name may not contain `/` nor start with `.`. |
| `winetricks` | Prints `system` or `runner`. |
| `winetricks system\|runner` | Sets it. |
| `apply ...` | Sets several values in one call: `runner=<name>` and/or `winetricks=system\|runner`. Used by the graphical interface. |

## Behavior

1. Lutris is detected (Flatpak or native, see [`ludis lutris-version`](lutris-version.md); the question when both are installed is asked here too). Not installed: error, exit 1.
2. `python3` with `PyYAML` is required (the file is edited through ludis' YAML tool, never with `sed`).
3. The file is `<Lutris config folder>/runners/wine.yml`: `~/.config/lutris/runners/wine.yml` for the native package, `~/.var/app/net.lutris.Lutris/config/lutris/runners/wine.yml` for the Flatpak. It is created (`wine:` only) if it does not exist.
4. Lutris is **not** stopped. Close and reopen it if it was open, so that it re-reads the file.

## Output

```
$ ludis lutris-defaults
runner=default
winetricks=runner
$ ludis lutris-defaults runner GE-Proton10-4
Default runner of Lutris set to GE-Proton10-4.
$ ludis lutris-defaults winetricks system
Default winetricks of Lutris: system.
```

Errors go to stderr: `Error: the runner '<name>' is not installed ...`, `Invalid value: <x> (use system or runner)`, `Unknown action: <x> (use status, runner or winetricks)`.

## Exit status

| Code | Meaning |
|---|---|
| 0 | Success. |
| 1 | Lutris not installed, `PyYAML` missing, runner not installed or invalid name, invalid value, unknown action, or the file could not be written. With `apply`, 1 if any value failed (the others are still applied). |

## Scripting notes

- `status` prints `key=value` lines: easy to parse.
- Messages follow the locale; use `LC_ALL=C` for English.
- With both Lutris installations present and no saved choice, the question of [`ludis lutris-version`](lutris-version.md) may be asked; avoid it with `LUDIS_LUTRIS_VERSION=flatpak` or `native`.

## Examples

```
# What are the defaults?
ludis lutris-defaults

# Use GE-Proton by default for new games
ludis lutris-defaults runner GE-Proton10-4

# Use the system winetricks by default
ludis lutris-defaults winetricks system
```

## Files and data touched

- Reads and writes: `<Lutris config folder>/runners/wine.yml` (keys `version` and `system_winetricks` of the `wine` section only).
- Reads: the Lutris runner folder (to check that the runner exists).
- Does not touch any game.

## See also

[`ludis tools`](tools.md), [`ludis list-runner`](list-runner.md), [`ludis lutris-version`](lutris-version.md), [`ludis doctor`](doctor.md).
