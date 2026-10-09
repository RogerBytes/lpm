# lpm isolate

Splits a store that lives in one big shared Wine prefix (Epic Games Store, EA App, Ubisoft Connect, Battle.net) into one independent prefix per game (beta).

## Synopsis

```
lpm isolate [-y] <store|slug>
```

## Description

Store launchers install several games inside a single shared prefix. lpm works on the "one game, one prefix" principle and hides such games from [`lpm list`](list.md), [`lpm pack`](pack.md) and [`lpm uninstall`](uninstall.md). `lpm isolate` converts a whole store at once: **every** game of that store currently in the shared prefix gets its own new prefix, containing a copy of the launcher plus that game's own files. The games' files are then removed from the shared prefix, and the Lutris entry of each game is repointed to its new prefix. The launcher's own Lutris entry and the shared prefix itself stay as they are.

The command always acts on a whole store, never on a single game. The argument is mandatory in practice (see Arguments).

Lutris is **killed** (`SIGKILL`) first. Use [`lpm list-isolable`](list-isolable.md) to see what would be isolated.

## Arguments

`<store|slug>` identifies the store. It is matched case-insensitively against:

| Store | Accepted values |
|---|---|
| Epic Games Store | `egs`, `epic`, `epicgames`, `epic-games`, `epic games`, `epic games store` |
| EA App / EA Desktop | `ea`, `eaapp`, `ea-app`, `eadesktop`, `ea-desktop`, `ea app`, `ea desktop` |
| Ubisoft Connect | `ubisoft`, `uplay`, `ubisoftconnect`, `ubisoft-connect`, `ubisoft connect` |
| Battle.net | `battlenet`, `battle.net`, `battle net`, `blizzard` |

Otherwise the argument is taken as a **slug** of a game (or launcher entry) currently living in a shared prefix: it only serves to find the store, and all the games of that store are isolated, not just the named one. Anything else: `Error: '<arg>' matches neither a known store (egs/ea/ubisoft/battlenet) nor a game currently sharing a store prefix (nothing to isolate).` (exit 1).

Without an argument the command prints `No games currently share a store prefix. Nothing to isolate.` on stderr and exits 0, **even when isolable games exist**. There is no interactive store selection.

## Options

| Option | Meaning |
|---|---|
| `-y` | Skips the confirmation. Must come right after `isolate`, before the store argument. |

## Behavior

1. Requires `sqlite3`, `realpath`, `python3`, `PyYAML`. Lutris is closed. The Lutris flavour is resolved as for [`lpm install`](install.md). The database and the games folder (`~/Games` or Lutris' `game_path`) must exist.
2. The shared-prefix games are found (database rows with the `wine` runner whose `directory` is shared by several rows, or whose name contains a store keyword as a whole word, see [`lpm list`](list.md)), their store is detected from the names of the games in the same folder, and the launcher entries themselves (`Epic Games Store`, `EA App`, `EA Desktop`, `Ubisoft Connect`, `Battle.net`) are left out. Games are grouped by store.
3. Unless `-y`, the store, the number of games and a ` - <name> (<slug>)` list are shown and `Proceed with isolation? This duplicates the shared launcher and frees the game's files from the shared prefix. [Y/n]` is asked. Pressing Enter (or any answer other than `n`/`N`) confirms; `n`/`N`, or end of input (no terminal, empty stdin), cancels (`Isolation cancelled.`, exit 0).
4. Each game is then processed independently, one after another. For one game:
   1. Checks: the shared prefix is inside the games folder; the store is recognised; the database row is found; the row id is numeric; `configpath` has no `/`.
   2. The game's own files inside the shared prefix are located (list below). If none is found, the game fails and nothing is changed for it.
   3. The new slug is the old slug, except for EA games, which become `<slug>-<game-name-slugified>` (with `-2`, `-3`, ... on conflict). The new prefix is `<games folder>/<new slug>`; if it already exists the game fails.
   4. The **base** (launcher) paths of the store, then the game's own paths, are copied with `cp -a` into the new prefix. A copy error removes the new prefix and fails that game. Then `dosdevices/c:` and `pfx` links are created. Nothing else of the Wine prefix is copied (no registry files, no `drive_c/windows`).
   5. A new Lutris config `<config dir>/<new slug>-<timestamp>.yml` is created from the old one: keys `script` and `version` dropped, shared-prefix paths replaced by the new prefix, `game.prefix` set, and launch hooks (`prelaunch_command`, `prelaunch_wait`, `postexit_command`... detected as in `lpm install`) are **commented out** with the `# lpm:hook-disabled` marker instead of being deleted, so they can be restored later (no prompt, no `--allow-scripts`). `game.args` and `wine.version` are kept.
   6. The old database row is deleted by id and a new row is inserted (new id, `installed_at` = now).
   7. If the new prefix is not empty, the game's own paths are deleted from the shared prefix (the base/launcher stays for the other games).
   8. The old config file is deleted. Success is logged.
5. A failing game does not stop the others.

Paths, relative to the prefix:

| Store | Base copied into every new prefix | Game's own paths |
|---|---|---|
| Epic | `drive_c/Program Files/Epic Games/Launcher`, `.../DirectXRedist`, `.../GameInputRedist`, `drive_c/users/$USER/AppData/Local/EpicGamesLauncher`, `drive_c/ProgramData/Epic/EpicGamesLauncher` | `drive_c/Program Files/Epic Games/<MandatoryAppFolderName>`, read from the `.item` manifest whose `DisplayName` equals the game name |
| EA | `drive_c/Program Files/Electronic Arts/EA Desktop`, `drive_c/users/steamuser/AppData/Roaming/Electronic Arts`, `.../Local/Electronic Arts/EA Desktop/CEF` | folders and shortcuts named after the game under `Program Files/EA Games`, `ProgramData/EA Desktop/InstallData`, `Program Files/Common Files/EAInstaller`, `users/steamuser/Documents/Electronic Arts`, `proton_shortcuts`, `users/Public/Desktop` |
| Ubisoft | everything in `drive_c/Program Files (x86)/Ubisoft/Ubisoft Game Launcher` except `games/` and `data/` | `.../games/<game name>`, `.../data/<id>` (id read from `uplay://launch/<id>` in `game.args`), desktop shortcuts |
| Battle.net | `drive_c/Program Files (x86)/Battle.net`, `drive_c/ProgramData/Battle.net/Agent`, `.../Battle.net/Setup`, `.../Battle.net_components/battlenet_helpersvc`, `.../Blizzard Entertainment/Battle.net/Cache`, `drive_c/users/$USER/AppData/Roaming/Battle.net/Battle.net.config` | `drive_c/Program Files (x86)/<game name>` |

Shortcuts are neither created nor modified by this command.

## Output

```
Store: Epic Games Store -- 2 game(s) to isolate, each into its own independent prefix:
 - Fortnite (fortnite)
 - Celeste (celeste)
Copying the shared launcher for Fortnite...
Copying Fortnite's own files...
Registering the new, independent prefix in Lutris...
Freeing up disk space in the shared prefix...
Isolation complete: Fortnite now has its own independent prefix.
Error: could not locate 'Celeste''s own files inside the shared prefix. Nothing was changed.
```

(The first three lines only without `-y`; the "Copying the shared launcher" line is repeated once per base path; the final success line is green on a terminal.) Per-game errors go to stderr, for example: `Error: could not determine which store owns the shared prefix for '<name>'. Skipping.`, `Error: an isolated prefix already exists for '<name>' (<path>). Aborting.`, `Error: failed to copy files while isolating '<name>'. Nothing was changed.`, `Error: invalid Lutris configuration for '<name>' (suspicious configpath in database). Nothing was changed.`

## Exit status

| Code | Meaning |
|---|---|
| 0 | Every selected game isolated; or nothing to isolate (including no argument); or cancelled at the prompt. |
| 1 | Missing dependency, Lutris/database not found, unrecognised store argument, or **at least one game failed** (the others may have succeeded). |

## Scripting notes

- Only one confirmation prompt exists: `[Y/n]`, avoided with `-y` (placed before the store). Without `-y`, when stdin is empty or not a terminal the prompt text is hidden and the answer is **cancel**: nothing is isolated, exit 0. Use `-y` explicitly in scripts.
- The one-time Flatpak/native question can occur when both Lutris flavours are installed; avoid it with `LPM_LUTRIS_VERSION=flatpak|native`.
- The command is not atomic across games: after a partial failure, re-run it; already isolated games no longer share the prefix and are not processed again. A game that cannot be isolated (no files found) is reported on every run.
- `list-isolable` can list a game that `isolate` then fails on (its own files not found).
- Messages follow the locale; use `LC_ALL=C` for English.

## Examples

```
# See what is isolable
lpm list-isolable

# Isolate the whole Epic Games Store, asking first
lpm isolate epic

# Same, unattended, naming the store through one of its games
lpm isolate -y fortnite

# Battle.net via alias
lpm isolate -y blizzard
```

## Files and data touched

- Creates: `<games folder>/<new slug>/` per game (copies of launcher and game files), `<Lutris games config dir>/<new slug>-<timestamp>.yml`.
- Deletes: the game's own folders inside the shared prefix, the old `<Lutris games config dir>/<old configpath>.yml`.
- Modifies: table `games` of `pga.db` (old row deleted, new row inserted).
- Writes: `~/.local/share/lpm/lpm.log`.
- Kills: running Lutris processes.
- Reads: the Epic `.item` manifests (Epic), the old config YAML.
- Takes extra disk space: the launcher is copied once per isolated game.

## See also

[`lpm list-isolable`](list-isolable.md), [`lpm info`](info.md), [`lpm list`](list.md), [`lpm pack`](pack.md), [`lpm uninstall`](uninstall.md).
