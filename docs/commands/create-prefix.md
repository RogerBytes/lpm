# lpm create-prefix

Creates one or more empty Wine prefixes and registers them in Lutris, without running any installer.

## Synopsis

```
lpm create-prefix [-y] [-r <runner>] [-a <win32|win64>] <name>[|<slug>]...
```

## Description

For each name given, `lpm create-prefix` initialises a blank Wine prefix in the Lutris games folder (with `wineboot` for a classic Wine runner, or `umu-run createprefix` for a Proton runner, the same mechanism Lutris uses) and adds a game entry for it to Lutris. The game has no executable yet; set one in Lutris, or use [`lpm exe-install`](exe-install.md) to create a prefix and run a Windows installer in it.

The runner and architecture apply to the whole batch. Lutris is **killed** (`SIGKILL`) first so its database is not locked.

## Arguments

| Argument | Meaning |
|---|---|
| `<name>` | Display name of the game in Lutris. The slug (and prefix folder name) is derived from it. |
| `<name>\|<slug>` | Same, with an explicit slug after the first `\|`. |

At least one name is required (`Error: no name given.`, exit 1). Empty names are ignored. Quote names that contain spaces.

Slug rules: accents are removed, text is lower-cased, everything except letters, digits, spaces and hyphens is dropped, runs of spaces/hyphens become one hyphen (`Épée & Bouclier` becomes `epee-bouclier`). An explicit slug goes through the same transformation. If nothing is left (non-Latin names), a deterministic UUID is used. If the slug already exists in the Lutris database (any game, any runner) or earlier in the same batch, `-2`, `-3`, ... is appended, so an explicit slug can still be altered.

## Options

`-y` is read by `bin/lpm` and must come directly after `create-prefix`. The others are read by the script and may be anywhere. If `-r` or `-a` is the very last argument with no value, it is treated as not given (default runner / `win64`).

| Option | Meaning |
|---|---|
| `-y` | Does not ask for confirmation. |
| `-r <runner>`, `--runner <runner>`, `--runner=<runner>` | Name of the runner folder to use (as in `lpm list-runner`). Default: the `version:` set in Lutris' `runners/wine.yml` (checked in `~/.local/share/lutris/`, `~/.var/app/net.lutris.Lutris/data/lutris/`, `~/.config/lutris/`), else `proton-cachyos-x86_64`. |
| `-a <arch>`, `--arch <arch>`, `--arch=<arch>` | `win32` or `win64` (default). Anything else: error, exit 1. |

## Behavior

1. `sqlite3`, `python3` and PyYAML are required. Lutris is closed. The Lutris flavour is resolved as for [`lpm install`](install.md). The games folder (`~/Games` or `game_path:` in Lutris' `system.yml`) and the Lutris directories are created if missing.
2. The runner folder `<Lutris data>/runners/wine/<runner>` must exist and be recognised: **Wine** if `bin/wine` is executable; **Proton** if `toolmanifest.vdf` exists. Otherwise: `Error: runner "<runner>" was not recognized ...` (exit 1). For Proton, `umu-run` must be found (in `PATH`, `/usr/local/share/umu/`, `/usr/share/umu/`, `/opt/umu/`, or the copy bundled with Lutris), else `Error: this runner is a Proton build and requires "umu-run", ...` (exit 1). (This check happens before the names are examined.)
3. The slugs are computed (rules above).
4. Unless `-y`, the batch is shown and `Create these empty prefixes? [Y/n]` is asked. Pressing Enter, `y`, `Y`, `o` or `O` proceeds; any other text, or end of input (no terminal, empty stdin), cancels with `Cancelled.` (exit 0).
5. For each name, in order:
   1. If the folder `<games folder>/<slug>` already exists (even if it is not in Lutris), the entry is skipped and counted as "skipped".
   2. The folder is created and initialised: `WINEARCH=<arch> WINEPREFIX=<folder> WINEDLLOVERRIDES=winemenubuilder= <runner>/bin/wineboot` (Wine) or `WINEARCH=<arch> WINEPREFIX=<folder> PROTONPATH=<runner folder> GAMEID=0 umu-run createprefix` (Proton). Their output is discarded and their exit code ignored.
   3. lpm waits up to 180 s for `user.reg`, `userdef.reg` and `system.reg` to appear (at the end `user.reg` + `system.reg` are enough). On timeout the entry is counted as "failed", and the (partial) folder is **left in place**; no Lutris entry is created, and a later run with the same slug will skip it because the folder exists.
   4. A Lutris config `<config dir>/<slug>-<timestamp>.yml` is written (game name, `game_slug`, empty `game.exe`, `game.prefix`, `wine.version: <runner>`, `system.env.LC_ALL: ''`) and a row is inserted in `games` (runner `wine`, empty executable, `installed`=1).
6. A summary is printed, then a detached background job runs `lpm sync-media` for the created slugs (network errors are only logged).

No shortcut is created and nothing is written to the lpm log on success.

## Output

```
The following prefixes will be created:
  - My Game (slug: my-game)
Creating prefix for "My Game" (slug: my-game) [1/1]...
1 prefix(es) created.
```

The first two lines appear only without `-y`. After the "created" line (green on a terminal) two more lines may follow on stdout: `<n> skipped (a prefix with that slug already existed).` and `<n> failed (timed out waiting for the prefix to initialize).`. Setup errors go to stderr, except `Required command missing: <cmd>` and `Error: Lutris does not appear to be installed on this machine.`, printed on stdout.

## Exit status

| Code | Meaning |
|---|---|
| 0 | No prefix failed: every prefix was created or skipped because its folder already existed (also if all were skipped), or the batch was cancelled at the prompt. |
| 1 | At least one prefix failed to be created (timed out waiting for the prefix to initialize; the other prefixes of the batch are still processed), invalid `--arch`, missing `sqlite3`/`python3`/PyYAML, Lutris not found, runner folder missing or not recognised, `umu-run` missing for Proton, no name given. |

The `created/skipped/failed` lines (or [`lpm list`](list.md)) give the detailed outcome.

## Scripting notes

- Prompts: the `[Y/n]` confirmation (avoid with `-y`), and the one-time Flatpak/native question if both Lutris flavours are installed (avoid with `LPM_LUTRIS_VERSION=flatpak|native`).
- Without `-y`, a script with no terminal (end of input) cancels (exit 0, nothing created): pass `-y`.
- Put `-y` first. `lpm create-prefix -r Runner -y "Name"` makes `-y` a *name* (a prefix called "-y" is proposed, and with empty stdin the batch is cancelled).
- `-r`, `-a` (or their long forms) given as the last argument with no value are ignored (default runner, `win64`).
- The slugs that will be used are printed before creation (without `-y`) and in each `Creating prefix for "<name>" (slug: <slug>)` line, so a script can read them back. After the run, `lpm list` shows them.
- Creation is sequential; the maximum wait is 180 s per prefix.
- Use `LC_ALL=C` for English messages.

## Examples

```
# One prefix, default runner, asking first
lpm create-prefix "My Game"

# Several prefixes, unattended
lpm create-prefix -y "Game One" "Game Two"

# Explicit slug, specific runner, 32-bit
lpm create-prefix -y -r wine-ge-8-26-x86_64 -a win32 "Old Game|old-game"

# Same with long options
lpm create-prefix -y --runner=GE-Proton9-20 --arch=win64 "Some App"
```

## Files and data touched

- Creates: `<games folder>/<slug>/` (Wine prefix), `<Lutris games config dir>/<slug>-<timestamp>.yml`.
- Modifies: table `games` of Lutris' `pga.db`.
- Runs: the runner's `wineboot` or `umu-run createprefix`.
- Kills: running Lutris processes.
- Does not create shortcuts, and does not write a success line in `~/.local/share/lpm/lpm.log` (errors are logged).

## See also

[`lpm exe-install`](exe-install.md), [`lpm list`](list.md), [`lpm info`](info.md), [`lpm uninstall`](uninstall.md); `lpm list-runner`, `lpm install-runner`.
