# lpm launcher

Enables or disables the LPM Launcher (a multi-executable picker run before each launch) for one or more installed Wine/Proton games, or lists the games that have it enabled.

## Synopsis

```
lpm launcher <slug>... on  [--if-needed]
lpm launcher <slug>... off [--if-needed]
lpm launcher status
```

## Description

With the LPM Launcher enabled, the lpm shortcut of the game (menu, desktop or any folder) reads the game's `lpm-launcher.yml` at every launch, writes `lpm-launch.bat` with the entry to run, and only then starts Lutris. There is no relay script and no Lutris prelaunch command. The menu therefore exists only when the game is started from an lpm shortcut; started from Lutris itself, the game runs the last chosen entry. With a single entry the game starts directly; with several entries (episodes, DLC, bonus content...) a picker lets the player choose which executable to run. On the loading screen, the label of the chosen entry is shown as a subtitle under the game name, except when it is exactly the game name (strict comparison): then there is no subtitle. The entries are therefore never fixed at activation time; edit `lpm-launcher.yml` by hand or with `lpm launcher-entries`.

Enabling is independent of lpm's loading screen (`lpm shortcut -n`, `lpm splash`, `lpm logo`): those work with or without the launcher.

Only Wine/Proton games (`runner='wine'`) are handled; shared store prefixes are included.

The action word (`on`/`off`) must be the last argument (ignoring `--if-needed`) and at least one slug is required. `status` is only accepted as the single argument. There is no interactive game selection.

## Arguments

- `<slug>...` : Lutris slugs.
- `on` | `off` : the action.
- `status` : alone; prints the slugs that currently have the launcher enabled.

## Options

| Option | Effect |
| --- | --- |
| `--if-needed` | Anywhere among the arguments. A game that is already in the requested state is silently skipped instead of causing an error. (Not listed in `lpm --help`.) |

## Behavior

Common to all forms: needs `python3`, `sqlite3` and PyYAML; resolves Lutris (Flatpak or native); reads `pga.db`. If there is no Wine game: "No Wine/Proton games found." on stderr, exit 0.

A game counts as **enabled** when its Lutris YAML has `game.exe` whose file name is `lpm-launch.bat`. This is re-read at each call; there is no separate state file.

**Games of lpm 0.9.5 and earlier** used a relay `scripts/lpm-launcher.sh` run by a Lutris `prelaunch_command`. They still count as enabled and are converted automatically: at their first launch from an lpm shortcut, when `lpm launcher <slug> on` is run, or when a package made then is installed, lpm removes that prelaunch command (only if it is the relay; a command of yours is never touched), deletes the relay, and aligns `bat_path` of `lpm-launcher.yml` on the `game.exe` of Lutris. This conversion is permanent: old packages can be installed years later.

`status`: prints the slug of every enabled game, one per line, in game-name order, and exits 0. Changes nothing.

`on` / `off`: all slugs are validated first. Unknown slug -> error, exit 1. Game already enabled (`on`) or not enabled (`off`) -> error, exit 1, unless `--if-needed` was given (then that game is skipped). Nothing is modified if validation fails.

Enabling a game (`on`):

1. Reads the game's current `game.exe`, `working_dir` (default: the exe's folder), `game.prefix` (default: game dir) and `wine.version` from its Lutris YAML. No executable: error "has no executable currently configured in Lutris".
2. Converts the exe and working directory to Windows paths. A path inside the prefix's `drive_c` is converted as plain text (`.../drive_c/Games/x.exe` becomes `C:\Games\x.exe`), so no Wine process is started and no Wine window can appear. Only a path outside `drive_c` uses `winepath -w` (the one next to the game's wine runner, else `winepath` from `PATH`). Failure: error "could not resolve the Windows path".
3. Writes `lpm-launch.bat` in `<prefix>/drive_c/Games/<top folder of the exe>/` (or, if the exe is not under `drive_c/Games/`, in the working directory; a warning is logged). It `cd`s to the working directory and `start`s the exe.
4. Creates `<game dir>/lpm-launcher.yml` **only if it does not exist yet**, containing `title` (game name), `prompt`, `original_exe`, `bat_path`, one auto-filled entry (label `Launch`) and a commented example entry. An existing file (and your entries) is never overwritten (`off` deletes it, so this only concerns a hand-written or restored file); only `bat_path` (always) and `original_exe` (unless `game.exe` already points to an `lpm-launch.bat`) are brought up to date in it, because they are absolute paths of this machine and a hand-written or imported file may lack them. The shortcut also aligns `bat_path` on the `game.exe` of Lutris at each launch.
5. Edits the game's Lutris YAML line by line (helper `lib/zgu-yaml-edit.py`): `game.exe` = the `lpm-launch.bat` path. Nothing else: no relay, no prelaunch command. YAML comments, including `# lpm:hook-disabled` lines, are preserved. Only if this targeted edit is impossible does lpm fall back to rewriting the whole file with PyYAML (`yaml.dump`), which loses the comments.
6. Removes an old-format relay if the game still has one (see above).
7. Prints `<name>: enabled. Edit <game dir>/lpm-launcher.yml to add or change entries.`

Disabling a game (`off`):

1. Needs `<game dir>/lpm-launcher.yml` with an `original_exe`; otherwise errors "lpm-launcher.yml not found for ..." or "no original executable saved for ..." (game left untouched).
2. Sets `game.exe` back to `original_exe`. If that key is missing (hand-written file), the exe of the first menu entry is used (only a `C:\...` path can be converted) and a message says so; with no usable entry: "no original executable saved". Removes `system.prelaunch_command` and `system.prelaunch_wait` only if the command contains `scripts/lpm-launcher.sh` (old format). The YAML is edited line by line as for `on` (comments preserved), with the same PyYAML-rewrite fallback.
3. Then **deletes the files the launcher added**, by name: `lpm-launcher.yml` (the entries go with it, a later `on` starts from a fresh file), `scripts/lpm-launcher.sh` (old format), every `lpm-launch.bat` (the one of `bat_path`, the one at the game folder root, those of `drive_c/Games/*/`) and the temporary `.lpm-launcher-choice`. `scripts/` is removed only if it is then empty. Never touched: the game's files, any other file of the prefix, `splash/`, and the other files of `scripts/` (loading screen). No confirmation is asked.
4. Prints `<name>: disabled.`

A per-game failure is reported and the other games continue; the final status is 1 if any failed.

## Gamepad shortcuts while the game runs

When the LPM Launcher is enabled, a small watcher runs for the whole play session (`lib/zgu-gamepad-alttab-watcher.py`). It reads the pad through SDL2 without grabbing it, so the game and tools like AntiMicroX keep working. It stops by itself a few seconds after the game ends. It works on X11 (`xdotool`) and on Wayland (`ydotool`, which needs its `ydotoold` service).

Hold the hotkey combo **L1 + L2 + R1 + R2 + R3** (all pulled or pressed together), then:

| While holding the combo | Sends |
|---|---|
| D-pad left / right | Shift+Tab / Tab, as with Alt held: the window switcher moves back / forward. Releasing the combo validates the selection. |
| D-pad up | `F4` alone (Alt is released for the keypress, so it never becomes Alt+F4 and the window is not closed). |
| D-pad down | `Alt+Enter`. |
| Select | `F11` alone (Alt released for the keypress). |

A button already held when the combo is completed does nothing; only a new press counts, and holding a button does not repeat it. While the loading screen is shown and a pad is detected, a tip at the bottom left shows these combos one at a time (random first tip, 4.75 s each, fading in and out). Force-quitting the game uses a different combo (L1 + L2 + R1 + R2 + R3 + L3).

## Output

stdout:

```
Foo Game: enabled. Edit /home/me/Games/foo/lpm-launcher.yml to add or change entries.
Foo Game: disabled.
foo
```

(the last line is a `status` line: a slug.) The first two use the display name.

stderr:

```
Usage: lpm launcher <slug...> on|off
Error: the "<cmd>" command is required and was not found.
Error: the PyYAML Python module is required (pip install pyyaml, or your distribution's python3-yaml package).
Error: Lutris was not found on this machine.
Error: Lutris database not found at: <path>
Error: game "<slug>" not found.
Error: the LPM Launcher is already enabled for "<slug>".
Error: the LPM Launcher is not enabled for "<slug>".
Error: Lutris configuration file missing for "<slug>".
Error: "<slug>" has no executable currently configured in Lutris.
Error: could not resolve the Windows path for "<slug>" (winepath unavailable or failed).
Error: could not write lpm-launcher.yml for "<slug>".
Error: could not update the Lutris configuration for "<slug>".
Error: lpm-launcher.yml not found for "<slug>" -- cannot restore the original executable.
Error: no original executable saved for "<slug>".
No Wine/Proton games found.
```


## Exit status

- `0` : success (including `status`, skipped games with `--if-needed`, and "No Wine/Proton games found").
- `1` : usage error, missing dependency, Lutris/database missing, unknown slug, game in the wrong state (without `--if-needed`), or any per-game failure.

## Scripting notes

- Prompts: only the dual-Lutris question (`Use [1] Flatpak (default) or [2] the native package? :`). Avoid the latter with `LPM_LUTRIS_VERSION=flatpak|native` or `lpm lutris-version`.
- Use `--if-needed` to make `on`/`off` idempotent in scripts.
- `status` output is stable: only slugs, one per line, nothing else on stdout.
- With no arguments the command prints a bash "bad array subscript" warning on stderr before the usage message (harmless, exit status 1).
- `LC_ALL=C` forces English messages.

## Examples

```
lpm launcher my-game on
lpm launcher my-game other-game off
lpm launcher my-game on --if-needed
lpm launcher status
```

## Files and data touched

- The game's Lutris YAML (`game.exe`; the old relay's `system.prelaunch_command`/`prelaunch_wait` are removed), edited in place line by line (comments kept).
- `<game dir>/lpm-launcher.yml` (created if missing), `<prefix>/drive_c/Games/<folder>/lpm-launch.bat`.
- `~/.local/share/lpm/lpm.log`.

## See also

`lpm launcher-entries`, `lpm splash`, `lpm logo`, `lpm shortcut`, `lpm lutris-version`
