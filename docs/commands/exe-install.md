# lpm exe-install

Creates a new Wine prefix, runs a Windows installer (`.exe`, `.msi`, `.bat`, `.cmd`) inside it, and registers the result in Lutris.

## Synopsis

```
lpm exe-install [-y] <file>[|<name>[|<slug>]] [-r <runner>] [-a <win32|win64>] [-f <path>|none]
```

## Description

`lpm exe-install` does what Lutris' "Install a Windows executable" wizard does: it initialises a blank prefix (as [`lpm create-prefix`](create-prefix.md) does), runs the given installer in the foreground with the chosen runner, waits for it to finish, then adds a game entry to Lutris, optionally with the path of the installed game's executable. One installer at a time.

The installer runs with your terminal's stdout/stderr attached and its window visible; the command blocks until the installer exits. Lutris is **killed** (`SIGKILL`) first so its database is not locked.

## Arguments

The installer is the **first argument after `-y`** and must come before the options.

| Argument | Meaning |
|---|---|
| `<file>` | Path to the installer. Must be an existing regular file; a leading `~` is expanded. |
| `<file>\|<name>` | Also sets the display name. Default: the file name without its last extension (`setup.exe` gives `setup`). |
| `<file>\|<name>\|<slug>` | Also sets the slug (and prefix folder name). |

The slug (given or derived from the name) is normalised like in `create-prefix` (ASCII, lower case, `[a-z0-9_-]`, hyphens) and, if already used in the Lutris database, suffixed with `-2`, `-3`, ... The path itself cannot contain `|`.

## Options

`-y` is read by `bin/lpm` (directly after `exe-install`). The others are read by the script and must follow the file argument; unknown extra arguments there are silently ignored. `-r`, `-a` or `-f` given as the very last argument with no value is treated as not given (default runner, `win64`, final executable asked interactively).

| Option | Meaning |
|---|---|
| `-y` | Skips the launch confirmation. It never skips the question asked when the installer fails. |
| `-r <runner>`, `--runner <runner>`, `--runner=<runner>` | Runner folder to use. Default: `version:` of Lutris' `runners/wine.yml`, else `proton-cachyos-x86_64`. |
| `-a <arch>`, `--arch <arch>`, `--arch=<arch>` | `win32` or `win64` (default); anything else: error, exit 1. |
| `-f <path>`, `--final-exe <path>`, `--final-exe=<path>` | Executable of the installed game, stored in Lutris. `none` means no executable. Giving this option removes the last interactive question. |

## Behavior

1. `sqlite3`, `python3`, PyYAML required; Lutris closed; Lutris flavour resolved as in [`lpm install`](install.md); games folder is `~/Games` or Lutris' `game_path`.
2. The runner folder must exist and be recognised (Wine: executable `bin/wine`; Proton: `toolmanifest.vdf`, which also requires `umu-run`), as described in [`create-prefix`](create-prefix.md). These checks come first, before the file is checked.
3. A missing target is `Error: no file path provided. Syntax: ...` (exit 1); a target that is not a file is `Error: file "<path>" was not found.` (exit 1). If `<games folder>/<slug>` already exists: `Error: a prefix already exists at this location: <path>` (exit 1).
4. Unless `-y`, a summary (Name, Slug, File, Runner and arch) is shown and `Continue? [Y/n]` asked. Enter, `y`, `Y`, `o` or `O` continue; any other text, or end of input (no terminal, empty stdin), cancels (`Cancelled.`, exit 0).
5. The prefix is created and initialised (`wineboot`, or `umu-run createprefix` for Proton) and lpm waits up to 180 s for the registry files. On timeout: `Error: prefix initialization failed (timed out).`, the folder is removed, exit 1.
6. The installer is run in the foreground: `WINEARCH=<arch> WINEPREFIX=<prefix> <runner>/bin/wine <file>` (Wine), or the same with `PROTONPATH=<runner folder> GAMEID=0 umu-run <file>` (Proton). Wine opens `.msi` and `.bat`/`.cmd` itself. The working directory is the one you launched `lpm` from.
7. If the installer's exit code is **non-zero**: `The installer exited with code <n> (possible failure or cancellation).` then `Delete the created prefix? [y/N]` is asked, **always, even with `-y`**. `y`, `Y`, `o`, `O` delete the prefix folder, print `The prefix has been deleted.` and exit 0 (no Lutris entry is made). Any other answer, including empty/closed stdin, keeps the prefix and goes on as if the install had succeeded.
8. Final executable: with `-f`, its value is used (`none` = empty). Without `-f`, `Select the installed game's .exe (optional).` is printed and `Path to the game's .exe (leave empty to skip):` is asked; the typed line is used verbatim. The path is stored as given: lpm does not check that it exists and does not make it relative to the prefix, so give an absolute path on the host.
9. A Lutris config `<config dir>/<slug>-<timestamp>.yml` is written (name, `game_slug`, `game.exe`, `game.prefix`, `wine.version: <runner>`, `system.env.LC_ALL: ''`) and a row is inserted in the `games` table (runner `wine`, `executable` = the final executable).
10. `"<name>" was installed and registered in Lutris.` is printed (green on a terminal) and a detached `lpm sync-media` job is started (errors only logged).

No shortcut is created. Nothing is added to the lpm log on success.

## Output

```
The following prefix will be created and the installer launched:
  Name    : Cool App
  Slug    : cool
  File    : setup.exe
  Runner  : GE-Proton9 (win64)
Initializing prefix for "Cool App"...
<installer's own output>
Select the installed game's .exe (optional).
"Cool App" was installed and registered in Lutris.
```

The summary block appears only without `-y`; the "Select" line only without `-f`. Errors go to stderr (except `Required command missing: <cmd>` and the "Lutris does not appear to be installed" message, which go to stdout).

## Exit status

| Code | Meaning |
|---|---|
| 0 | Registered; **or** cancelled at the first prompt; **or** the installer failed and you chose to delete the prefix. If the installer failed and you kept the prefix, 0 as well. |
| 1 | Invalid arch, missing dependency, Lutris not found, runner folder missing/unrecognised, `umu-run` missing, no file, file not found, empty name, prefix folder already exists, prefix initialisation timed out. |

The installer's own exit code is not returned.

## Scripting notes

Interactive prompts that exist:

| Prompt | Avoid with | Empty/closed stdin gives |
|---|---|---|
| `Use [1] Flatpak (default) or [2] the native package?` (both Lutris flavours installed, nothing saved) | `LPM_LUTRIS_VERSION=flatpak\|native` | Flatpak, saved |
| `Continue? [Y/n]` | `-y` | **Cancel** (exit 0, nothing done) |
| `Delete the created prefix? [y/N]` (only if the installer exits non-zero) | cannot be skipped | **No**: prefix kept and registered |
| `Path to the game's .exe (leave empty to skip):` | `-f <path>` or `-f none` | empty: no executable |

- A fully unattended call is therefore `lpm exe-install -y ./setup.exe -r <runner> -f none`. Even so, a failing installer is registered as if it had worked when no terminal answers the deletion question; detect failures in the installer's own output or by checking the result.
- The installer is graphical and needs a display (`DISPLAY`/Wayland) like any Wine program; lpm does not provide one.
- Options before the file are misread: `lpm exe-install -r X setup.exe` treats `-r` as the file (`Error: file "-r" was not found.`). `-y` must be before the file; after it, it is ignored silently.
- `-r`, `-a`, `-f` as the last argument with no value are treated as not given.
- Names and slugs: read the `Slug :` line (or run `lpm list`) to learn the final slug. Use `LC_ALL=C` for English messages.

## Examples

```
# Interactive, default runner
lpm exe-install ~/Downloads/setup_game.exe

# Name and slug chosen
lpm exe-install "~/Downloads/setup_game.exe|My Game|my-game"

# Unattended with a given runner, 32-bit, and the game's executable known
lpm exe-install -y ./setup.exe -r wine-ge-8-26-x86_64 -a win32 \
  -f "$HOME/Games/setup/drive_c/Program Files/Game/game.exe"

# MSI package, no final executable
lpm exe-install -y "package.msi|Some Tool" --runner=GE-Proton9-20 --final-exe=none
```

## Files and data touched

- Creates: `<games folder>/<slug>/` (the prefix, plus whatever the installer writes in it), `<Lutris games config dir>/<slug>-<timestamp>.yml`.
- Modifies: table `games` of Lutris' `pga.db`.
- Reads: the installer file (never modified or copied).
- Deletes: the new prefix, only on initialisation failure or if you answer yes after an installer error.
- Kills: running Lutris processes.

## See also

[`lpm create-prefix`](create-prefix.md), [`lpm install`](install.md), [`lpm list`](list.md), [`lpm info`](info.md), [`lpm uninstall`](uninstall.md).
