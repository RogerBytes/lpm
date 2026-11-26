# ludis doctor

Diagnoses the machine: Lutris, runners, the tools ludis needs and the optional ones. Says what is missing and how to fix it. Changes nothing.

## Synopsis

```
ludis doctor
```

## Description

`ludis doctor` is a read-only check, useful after an installation or when something does not work. It never asks a question, never downloads anything and never modifies a file. This is the difference with [`ludis check`](check.md), which fetches the runners needed by your games.

Each line starts with a status:

| Status | Meaning |
|---|---|
| `[ OK ]` | Present. |
| `[WARN]` | Optional or degraded: ludis works, but a feature is limited. |
| `[FAIL]` | ludis cannot work without it. |

A line that is not `[ OK ]` is followed by an indented hint (how to fix it).

## Arguments and options

None. Extra arguments are ignored.

## Behavior

The checks, in order:

1. **Session**: `Graphical session: wayland` if `XDG_SESSION_TYPE` is `wayland` or `WAYLAND_DISPLAY` is set, otherwise `x11`.
2. **Tools needed by ludis** (`[FAIL]` if missing): `sqlite3`, `python3`, `bsdtar`, `sha256sum`, `tar`, `zstd`, `curl` or `wget` (one of them is enough), and the Python module `PyYAML`.
3. **Graphical interface** (`[WARN]` if missing): the Python bindings for GTK4 and Libadwaita. Without them the command line works but `ludis-gui` does not start.
4. **Lutris**: each of the two installations (Flatpak, native package) that exists is checked: its database (`[WARN]` if absent: start Lutris once), the number of Wine/Proton runners installed (`[WARN]` if none), and that the default runner of Lutris is installed (`[WARN]` otherwise). If **neither** Lutris is installed: `[FAIL]`. Both can be present: doctor does not ask which one to use, it reports both (see [`ludis lutris-version`](lutris-version.md)).
5. **Wine**: the version of a system Wine if there is one. Not having one is normal and reported `[ OK ]`: ludis uses the runners of Lutris.
6. **Optional** (`[WARN]` if missing):
   - MangoHud (native, or as a Flatpak runtime): needed for the FPS overlay of the in-game menu.
   - AntiMicroX (native, or Flatpak `io.github.antimicrox.antimicrox`): needed for the gamepad profiles.
   - `xdotool`: checked **only on an X11 session**. Without it, the gamepad combos (Alt-Tab, quit) and the game window detection are degraded.

The last line is the summary: `Everything needed is present. <n> warning(s).` or `<n> problem(s) to fix, <m> warning(s).`

## Output

Plain text on stdout, one section per group. Example (English, `LC_ALL=C`):

```
Session
[ OK ] Graphical session: x11

Tools needed by ludis
[ OK ] sqlite3
...
Lutris
[ OK ] Lutris (flatpak) found
[ OK ] Lutris database: /home/you/.var/app/net.lutris.Lutris/data/lutris/pga.db
[ OK ] 5 Wine/Proton runner(s) installed (flatpak)

Optional
[WARN] AntiMicroX is missing: gamepad profiles will not work
       Install antimicrox with your package manager or Flatpak (io.github.antimicrox.antimicrox).

Everything needed is present. 1 warning(s).
```

## Exit status

| Code | Meaning |
|---|---|
| 0 | No `[FAIL]` (there may be warnings). |
| 1 | At least one `[FAIL]`. |

## Scripting notes

- Parse the first characters of each line (`[ OK ]`, `[WARN]`, `[FAIL]`) or just use the exit status.
- The text follows the locale; the status tags do not. Use `LC_ALL=C` for English.
- Nothing is written, not even to the ludis log.

## Examples

```
ludis doctor

# Only the problems
ludis doctor | grep -A1 -E '^\[(WARN|FAIL)\]'

# In a script
ludis doctor >/dev/null || echo "Something required is missing"
```

## Files and data touched

- Reads: the Lutris database path and runner folder of each installation (only their presence and the number of runner folders), the Lutris default runner setting.
- Writes: nothing.

## See also

[`ludis check`](check.md), [`ludis lutris-version`](lutris-version.md), [`ludis lutris-defaults`](lutris-defaults.md), [`ludis list-runner`](list-runner.md).
