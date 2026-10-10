# lpm pack

Packages one or more installed games into portable `.zgp` archives.

## Synopsis

```
lpm pack [-<level>] [--hash] <slug>...
lpm pack [-<level>] [--hash] --all
```

## Description

`lpm pack` takes installed games (by **slug**, as printed by [`lpm list`](list.md)), cleans up their Wine prefix, embeds a sanitised copy of their Lutris configuration and writes `<Game name>.zgp` in your home folder. The `.zgp` can then be installed on another machine (or later on this one) with [`lpm install`](install.md).

**The prefix of the installed game is modified in place** by the cleaning step (see Behavior). The changes are harmless for Wine/Proton, which recreate what is needed, but they are not undone.

The archive can contain private data (Wine registry, licence keys, paths). It is created with permissions `600`.

## Arguments

| Argument | Meaning |
|---|---|
| `<slug>...` | Slugs of Wine games registered in Lutris. Only the base name of each argument is used (`basename`). |
| `--all` | Only valid as the **sole** argument: packs every Wine game of the Lutris database (sorted by name), except shared-store games (see [`lpm list`](list.md) for how they are detected). |

With no slug at all (and no `--all`), the command prints `Error: nothing to do, no target given to 'lpm pack'. Run 'lpm --help' for the usage.` on stderr and exits 1.

## Options

All options must be written between `pack` and the first slug (they are parsed by `bin/lpm`). Written after a slug they are taken as slugs.

| Option | Meaning |
|---|---|
| `-0` ... `-22` | zstd compression level, as one token (`-9`, not `-l 9`). Default **3**. Levels 20 to 22 are run with zstd's `--ultra` (much slower, a lot more memory). A value outside 0-22 such as `-30` is not an option and is taken as a slug. |
| `--hash` | Also writes a sha256 sidecar file for each archive (see Files). |

`-y` is accepted but has no effect (there is nothing to confirm).

## Behavior

1. Needs a Lutris installation (Flatpak or native, same selection logic as [`lpm install`](install.md)), `zstd`, `python3` with `PyYAML`, and an existing games folder (`~/Games` or Lutris' `game_path`). Lutris is **not** killed by this command. `pv` (a package dependency) provides the progress percentage; `tar` and `sqlite3` are used throughout.
2. **Everything is validated before anything is changed**, for all slugs: the slug must not belong to a shared store prefix (error, exit 1); it must be a `wine` game of the Lutris database whose folder exists and really lies inside the games folder (`Error: Game slug '<slug>' not found in '<games folder>'.`, exit 1); and `$HOME/<Game name>.zgp` must not already exist (`Error: A package named '<name>.zgp' already exists in '<home>'.` plus `Delete it or move it before running the export again.`, exit 1). Existing archives are never overwritten. With `--all` the exception is a game whose folder is missing: the same `Error: Game slug '<slug>' not found in '<games folder>'.` is printed, that game is skipped, the other games are still packed, and the command exits 1 at the end (the final success line is then not printed).
3. For each game, the prefix is cleaned:
   - user names are anonymised: in `system.reg`, `user.reg`, `userdef.reg`, `lutris.json` and the game's `goglog.ini`, Windows `Users\<name>\` becomes `Users\anonuser\`, `/home/<name>/` becomes `/home/anonuser/`, and every occurrence of your `$USER` becomes `anonuser`;
   - `dosdevices/` is deleted; the `pfx` link, the `drive_c/users/steamuser` link and `drive_c/users/<you>` link are removed; a real `drive_c/users/<you>` folder is renamed to `steamuser`; the user-folder links (`Desktop`, `Documents`, `Downloads`, `Music`, `Pictures`, `Videos`, `My Documents`, `Application Data`) are unlinked;
   - `drive_c/users/steamuser/Local Settings` is deleted; `Temp` and `drive_c/ProgramData/Package Cache` contents are emptied;
   - Proton's `version` file (at the prefix root) is deleted. Proton uses it to decide that the prefix is up to date; the links to the runner that Proton created in the prefix (for example `drive_c/windows/system32/umu.exe`) are removed below, and with the file gone Proton rebuilds them at the next launch (slower, once) without touching the game data. This applies to the installed game too, not only to the archive;
   - broken symlinks under `drive_c` are deleted; symlinks pointing outside the game folder (or to their own folder) are deleted, never copied; the other symlinks are replaced by copies of their targets, after checking that the copy fits in the free disk space (otherwise the export stops with an error); `*.orig` files in `system32`/`syswow64` are deleted.
4. The Lutris config `<config dir>/<configpath>.yml` of the game is copied into the prefix as `zgp-game-config.yml` and sanitised: keys `script`, `version`, `slug` and `system.env.GAMEID` are dropped, lpm's own window-detection relay is removed from `system.prefix_command` (lpm rewrites it at every launch; a command you put there yourself is kept), the prefix path becomes `$GAMEDIR`, any `/home/<name>/` becomes `/home/anonuser/`, and `wine.version` is filled with Lutris' default runner if empty. Launch hooks (`prelaunch_command`, ...) are **kept** in the archive (they are handled at install time). If the game has no config file, no YAML is embedded and no error is shown.
5. The archive is produced by `tar -C <parent> -cf - <prefix folder name> | zstd -<level>` and written to `$HOME/<Game name>.zgp`. The name is the game's Lutris name, not the slug; it is not otherwise sanitised, except that each `/` is replaced by `-` (a game named `A/B` gives `A-B.zgp`, and the "already exists" check uses that name). The single top-level folder in the archive is the prefix folder name, which becomes the slug at install time.
6. On success: `chmod 600`, optional sidecar, log entry, then the temporary `zgp-game-config.yml` is removed from the prefix.
7. If tar or zstd fails (or the archive is empty) the partial archive is deleted, `Error: compression of '<name>' failed.` is printed and the command exits 1 immediately; archives of earlier games stay, and the temporary `zgp-game-config.yml` copied into the failing prefix is removed.

Interrupt (`SIGINT`/`SIGTERM`): the half-written archive (and its sidecar) and the temporary YAML are removed, "Export cancelled: the archive in progress has been removed." is printed, exit 130.

## Output

```
[1/1] Compressing 'Mario Vania' (Level 3)...
Done: /home/me/Mario Vania.zgp
CLI export completed successfully!
```

`Done:` and the last line are green on a terminal. Errors go to stderr. Lines such as `[PROGRESS] 100` and `[EXPORTED] <path>` are markers for the graphical front-end: ignore them in scripts.

## Exit status

| Code | Meaning |
|---|---|
| 0 | All requested archives written. |
| 1 | Missing `zstd`/`python3`/`PyYAML`, Lutris not found, games folder missing, unknown or shared-store slug, archive already exists, no slug given, `--all` with nothing to pack, compression failure, or `--all` in which at least one game's folder was missing (the other games were still packed). |
| 130 | Interrupted. |

## Scripting notes

- No interactive prompt exists, except the one-time Flatpak/native question when both Lutris flavours are installed (avoid it with `LPM_LUTRIS_VERSION=flatpak` or `native`). `-y` is not needed.
- The output location cannot be changed: always `$HOME`. Move the file afterwards.
- The file name is predictable from `lpm list` (the part after the slug, plus `.zgp`) unless the name contains characters special to the file system.
- Remember that a second `pack` of the same game fails until you move or delete the first archive.
- The sidecar `$HOME/hash/<Game name>.zgp.sha256` holds the bare 64-hex sha256, one line, no file name. If it cannot be computed the archive is still valid and no error is reported.
- Options after a slug are not recognised. `lpm pack mygame -9` fails with "Game slug '-9' not found".
- Set `LC_ALL=C` for English messages.

## Examples

```
# Default compression
lpm pack mariovania

# Strong compression, with an integrity sidecar
lpm pack -19 --hash mariovania

# Everything, fast
lpm pack -1 --all

# Pack, then verify the sidecar
lpm pack --hash mariovania && (cd ~ && sha256sum "Mario Vania.zgp"; cat "hash/Mario Vania.zgp.sha256")
```

## Files and data touched

- Writes: `$HOME/<Game name>.zgp` (mode 600); with `--hash`, `$HOME/hash/<Game name>.zgp.sha256` (the `hash/` folder is created).
- Modifies in place: the game's prefix (cleaning step above), temporarily adds `<prefix>/zgp-game-config.yml`.
- Reads: Lutris database and game config, `system.yml` for the games folder, `runners/wine.yml` for the default runner.
- Writes: `~/.local/share/lpm/lpm.log`.
- Does not touch the Lutris database.

## See also

[`lpm install`](install.md), [`lpm list`](list.md), [`lpm uninstall`](uninstall.md); `lpm pack-runner`.
