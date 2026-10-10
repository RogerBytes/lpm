# lpm install

Installs one or more games from `.zgp` archives into Lutris as ready-to-run Wine prefixes.

## Synopsis

```
lpm install [-y] [--allow-scripts] [--ignore-hash] [-s <mode>] [--desktop-dir=<dir>] [-n] <file.zgp>...
```

## Description

`lpm install` unpacks each `.zgp` archive (a zstd-compressed tar produced by [`lpm pack`](pack.md)) into your Lutris games folder, adapts the game's embedded Lutris configuration to the current machine, registers the game in the Lutris database and creates launcher shortcuts.

Each archive contains exactly one top-level folder; its name becomes the game's **slug** and the name of the new prefix folder. A game is never overwritten: if a prefix folder with that slug already exists, that archive is refused (uninstall the game first with [`lpm uninstall`](uninstall.md)).

Lutris is **killed** (`SIGKILL`) at the start of the command so that its database is not locked. Close any running Lutris session first.

## Arguments

| Argument | Meaning |
|---|---|
| `<file.zgp>...` | One or more existing archive files. A path that is not a regular file aborts the whole command (exit 1) before anything is installed. With no file at all, the command prints `Error: nothing to do, no target given to 'lpm install'. Run 'lpm --help' for the usage.` on stderr and exits 1. |

## Options

`-y`, `--allow-scripts` and `--ignore-hash` are read by `bin/lpm` and **must be written before the first file name** (right after `install`). The remaining options are read by the installer script itself and may appear anywhere in the argument list.

| Option | Meaning |
|---|---|
| `-y` | Skips the "Are you sure you want to install these games?" confirmation. It does **not** skip the hash-mismatch prompt nor the embedded-script prompt (see Scripting notes). |
| `--allow-scripts` | Keeps and enables the launch/exit scripts embedded in the package (`prelaunch_command`, `postexit_command`, ...) without asking. Without it, such entries are disabled (commented out). Use only for packages you trust or built yourself. |
| `--ignore-hash` | Does not check the sha256 sidecar file, even if one exists next to the archive. |
| `-s <mode>`, `--shortcut <mode>`, `--shortcut=<mode>` | Which shortcuts to create: `menu`, `desktop`, `both` (default) or `none`. Any other value: error, exit 1. If the option is the very last argument with no value, the default `both` is used. |
| `--desktop-dir=<dir>` | Folder in which to write the desktop shortcut instead of the detected desktop folder. The folder must already exist, otherwise the desktop shortcut is silently not written. Ignored when the mode is `menu` or `none`. |
| `-n`, `--no-loadingscreen` | Disables the lpm loading screen for the game's shortcuts (creates an empty marker file `.lpm-no-loadingscreen` in the prefix). |

The compression-level options (`-0` to `-22`) and `--hash` are accepted by the router but have no effect on `install`.

## Behavior

1. **Dependencies**: `sqlite3`, `pv`, `bsdtar`, `python3` and the Python module `PyYAML` are required, otherwise the command stops with exit 1.
2. **Lutris is closed**: `flatpak kill net.lutris.Lutris` (if the Flatpak is installed), then `pkill -9` on any `lutris` process.
3. **Lutris flavour**: Flatpak or native package is detected. If both are installed, lpm uses `LPM_LUTRIS_VERSION=flatpak|native` if set, else the choice saved in `~/.config/lpm/lutris-version`, else it asks once (see Scripting notes) and saves the answer. Paths used:
   - Flatpak: database `~/.var/app/net.lutris.Lutris/data/lutris/pga.db`, game configs `~/.var/app/net.lutris.Lutris/data/lutris/games/`.
   - Native: database `~/.local/share/lutris/pga.db`, game configs `~/.config/lutris/games/`.
4. **Games folder**: `~/Games`, unless the `game_path:` entry of Lutris' `system.yml` says otherwise (`~/.config/lutris/system.yml` or the Flatpak equivalent). Created if missing.
5. **Argument check**: at least one target must be given (otherwise the "nothing to do" error above, exit 1; Lutris has already been closed at that point) and every target must exist, otherwise exit 1 (nothing installed).
6. **Confirmation** (unless `-y`): lists the games and asks `[Y/n]`. Pressing Enter (or any answer other than `n`/`N`) confirms. `n`/`N`, or end of input (no terminal, empty stdin), cancels (message "Installation cancelled.", exit 0).
7. **Integrity check** (unless `--ignore-hash`), done for the whole batch before any extraction. For an archive `dir/name.zgp` lpm looks for a sidecar `dir/hash/name.zgp.sha256`, then `dir/name.zgp.sha256`. The sidecar must contain only the 64-hex-digit sha256 of the archive; a sidecar that is empty, malformed or different is a mismatch. No sidecar means no check. If there are mismatches, lpm lists them and asks `Do you want to install them anyway? [y/N]`: `y`/`Y` installs them, anything else silently removes them from the batch. If the batch becomes empty, the command exits 0.
8. **Per game, in order**:
   1. The archive is extracted with `bsdtar` (through `pv`) into a temporary folder `.zgp-extract-XXXXXX` inside the games folder, with `umask 022`. `bsdtar` rejects members that escape the folder (`../`, hostile symlinks).
   2. The single top-level folder name is the slug. It is rejected if it is a symlink, contains `/`, is `.`/`..`, or contains control characters.
   3. If `<games folder>/<slug>` already exists: error, game skipped.
   4. The folder is moved to `<games folder>/<slug>`.
   5. In `system.reg`, `user.reg`, `userdef.reg`, `lutris.json` and the game's `goglog.ini`, the placeholder user name `anonuser` is replaced by your `$USER`.
   6. `dosdevices/c:` and `pfx` links are recreated; a leftover `drive_c/users/steamuser/Local Settings` is removed; a leftover Proton `version` file (archives made by lpm 0.9.5) is removed so that Proton repairs its own files in the prefix at the first launch.
   7. The embedded `zgp-game-config.yml` is read for the display name and rewritten as a Lutris game config `<config dir>/<slug>-<timestamp>.yml`: the `script` and `version` keys are dropped, `/home/<user>` is replaced by your home, `$GAMEDIR` by the prefix path, and `game.prefix` is set. The embedded file is then deleted. If it is absent, the error "Critical error: The zgp-game-config.yml file was not found in the archive!" is printed, but the game is still registered (without a usable config).
   8. **Embedded scripts**: every key (at any depth) whose name ends in `_command`, `_script` or `_wait`, or contains `exec`, is considered a hook. If any is found, lpm prints them and asks `Keep it and allow it to run automatically? ... [y/N]` (accepts `y`, `Y`, `o`, `O`), unless `--allow-scripts` is given. If not allowed, the hook lines are **commented out** in the YAML (marked `lpm:hook-disabled`), never deleted. If the package ships `scripts/lpm-launcher.sh` and the config has no `prelaunch_command`, that relay is re-attached.
   9. Database: any row with the same slug is deleted, then a row is inserted in `games` (name, slug, `installer_slug`=slug, runner `wine`, executable, directory, `configpath`, `installed`=1, timestamps).
   10. Shortcuts are written according to `-s` (see Files).
   11. The success is written to the lpm log.
9. A desktop notification (`notify-send`, best effort) summarises the result, and a detached background job runs `lpm sync-media` for the installed slugs to fetch Lutris banners/icons (network errors there are only logged).

A failure on one game (corrupt or unreadable archive, invalid slug, already installed, move failure) prints an error on stderr, is logged, and the command **continues with the next game**.

Pressing Ctrl-C (or sending `SIGTERM`) removes only the game being installed (temporary extraction, half-registered prefix, Lutris entry, config, shortcuts), keeps the finished ones and the archive, prints "Installation cancelled: the game in progress has been cleaned up." and exits 130.

## Output

Progress goes to stdout, errors to stderr (in red when attached to a terminal). Typical run:

```
[1/1] Importing 'mario.zgp'...
Analyzing and configuring mario...
Processing Windows registries...
Registering with Lutris...
Creating shortcuts...
Finalizing...
```

Other messages (from `lang/en.lang`):

- `Games to install:` / ` - <name> (<path>)` (confirmation list)
- `Invalid signature for the following games:` / ` - <name>`
- `The package for '<game>' embeds the following script(s), ...` followed by ` - <key.path>: <value>` lines
- `Note: '<game>' embeds an automatic launch/close script, kept and allowed to run automatically (--allow-scripts).`
- `Error: File not found: <path>`
- `Error: The game '<slug>' is already installed. Please uninstall it first before reinstalling.`
- `Error: The archive for '<name>' is corrupted or invalid (decompression failed, code <n>).`
- `Critical error: Unable to determine the extracted prefix for <name>.`
- `Error: invalid value "<x>" for --shortcut (accepted values: menu, desktop, both, none).`
- `Error: '<cmd>' is not installed on this system.` and `Error: Lutris is not installed on this system.` (these two are printed on stdout)

stdout also contains a few extra lines in square brackets with a capitalised tag. They are meant for the graphical front-end and are not a stable interface: scripts should ignore them.

## Exit status

| Code | Meaning |
|---|---|
| 0 | Every archive of the batch was installed, or the user cancelled at the confirmation prompt (including end of input), or every archive was excluded after a hash mismatch (nothing left to install). |
| 1 | At least one archive was **not** installed (corrupt archive, invalid slug, already installed, move failure, ...; the other games of the batch are still installed), or: missing dependency, Lutris not installed, no file given, a target file does not exist, invalid `--shortcut` value (in these last cases nothing has been installed). |
| 130 | Interrupted (`SIGINT`/`SIGTERM`). |

Archives that you refused at the hash-mismatch prompt are removed from the batch beforehand and do not count as failures.

## Scripting notes

Interactive prompts that can occur, and how to avoid them:

| Prompt | Shown when | Avoid with | Answer if stdin is empty / not a terminal |
|---|---|---|---|
| `Use [1] Flatpak (default) or [2] the native package?` | Lutris installed both as Flatpak and natively, and no saved choice | `LPM_LUTRIS_VERSION=flatpak` or `native` in the environment, or `lpm lutris-version flatpak\|native` once | Flatpak is chosen and saved |
| `Are you sure you want to install these games? [Y/n]` | no `-y` | `-y` | Treated as **no**: the installation is cancelled (exit 0) |
| `Do you want to install them anyway? [y/N]` | an archive's sha256 sidecar does not match | `--ignore-hash` (skips the check; `-y` does **not**), or fix the archive | Treated as **no**: mismatching archives are skipped silently |
| `Keep it and allow it to run automatically? ... [y/N]` | the package embeds hooks, per game | `--allow-scripts` (keep them). There is no flag to refuse explicitly; the default answer is no | Treated as **no**: hooks are commented out |

When stdin is not a terminal (pipe, `</dev/null`, cron), bash does not print the text of the prompts, but the lists that precede them are still printed, and the default answers above apply. A fully non-interactive trusted install is therefore:

```
LPM_LUTRIS_VERSION=native lpm install -y --allow-scripts --ignore-hash game.zgp
```

and a non-interactive install that keeps the safe defaults (hooks disabled, bad archives refused) is `lpm install -y game.zgp </dev/null`. Without `-y`, an install whose stdin is empty is cancelled at the confirmation prompt.

Other points:

- Because of the router, `lpm install game.zgp -y` does **not** work (`-y` is taken as a file name: "File not found: -y"). The same holds for `--allow-scripts` and `--ignore-hash`. `-s`, `--shortcut=`, `--desktop-dir=` and `-n` may be placed anywhere.
- The exit status is 0 only if every archive was installed (or you cancelled). For details, run `lpm list` afterwards, or parse the log (`~/.local/share/lpm/lpm.log`, tab-separated: timestamp, command, status `OK`/`ERROR`/`WARN`/`INFO`, detail).
- Messages follow the locale (`LC_ALL`, then `LC_MESSAGES`, then `LANG`). Use `LC_ALL=C` to get the English strings quoted here.
- Error messages are also appended to the log.

## Examples

```
# Install one game, asking for confirmation
lpm install ~/Downloads/mariovania.zgp

# Install several games with no confirmation, only a desktop shortcut
lpm install -y --shortcut=desktop a.zgp b.zgp c.zgp

# Install without any shortcut and without loading screen
lpm install -y -s none -n game.zgp

# Install a package you built yourself, whose config has a prelaunch_command
lpm install -y --allow-scripts mygame.zgp

# Install an archive whose sidecar hash is known to be stale
lpm install -y --ignore-hash game.zgp
```

## Files and data touched

- Reads: the `.zgp`, its sidecar `hash/<archive>.sha256` or `<archive>.sha256`, Lutris `system.yml`.
- Creates: `<games folder>/<slug>/` (the prefix), temporary `<games folder>/.zgp-extract-*` (removed afterwards), `<Lutris games config dir>/<slug>-<timestamp>.yml`, optional `<games folder>/<slug>/.lpm-no-loadingscreen`.
- Shortcuts: menu `~/.local/share/applications/net.lutris.<slug>.desktop` (then `update-desktop-database`); desktop `<desktop dir>/<slug>.desktop` (marked trusted with `gio`), plus, if the prefix has an `extras/` folder, a symlink `<desktop dir>/<Game name> Bonus` to it. The desktop dir is `xdg-user-dir DESKTOP`, else `~/Bureau`, else `~/Desktop`, else `~`, unless `--desktop-dir` is given.
- Modifies: the Lutris database `games` table; may rewrite `~/.config/lpm/lutris-version`.
- Writes: `~/.local/share/lpm/lpm.log`.
- Kills: running Lutris processes.
- Does not delete the `.zgp`.

## See also

[`lpm uninstall`](uninstall.md), [`lpm pack`](pack.md), [`lpm list`](list.md), [`lpm info`](info.md); `lpm install-runner`, `lpm log`, `lpm lutris-version`.
