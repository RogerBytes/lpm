# ludis uninstall

Removes one or more installed Wine games: their prefix folder, their Lutris entry and their shortcuts.

## Synopsis

```
ludis uninstall [-y] [--save|--no-save] [--desktop-dir=<dir>] <slug>...
```

## Description

For each slug, `ludis uninstall` deletes the game's Wine prefix from disk, deletes its Lutris configuration file and its row in the Lutris database, and removes the menu and desktop shortcuts. The deletion of the prefix is **permanent** (no trash). Get the slugs from [`ludis list`](list.md).

Only games with the `wine` runner are considered. Games living in a prefix shared with a store launcher (Epic Games Store, EA App, Ubisoft Connect, Battle.net, ...) are refused: removing them would break the other games of that shared prefix (see [`ludis isolate`](isolate.md)).

Lutris is **killed** (`SIGKILL`) first so that its database is not locked.

## Arguments

| Argument | Meaning |
|---|---|
| `<slug>...` | Slugs of installed games, as printed by `ludis list`. At least one is required: with none, ludis prints `Error: nothing to do, no target given to 'ludis uninstall'` and exits 1. |

## Options

`-y` is read by `bin/ludis` and must come directly after `uninstall` (before the first slug). `--desktop-dir=`, `--save` and `--no-save` are read by the script and may appear anywhere.

| Option | Meaning |
|---|---|
| `-y` | Does not ask for confirmation. |
| `--save` | Answers **yes** in advance to the saves question (see below): the saves of every game of the batch are copied before it is deleted. |
| `--no-save` | Answers **no** in advance: no saves are copied, and no question is asked. |
| `--desktop-dir=<dir>` | Also removes the game's desktop shortcut (and its "Bonus" link) from this folder, in addition to the default desktop folder. Meant for shortcuts created with `ludis install --desktop-dir`. |

## Behavior

1. `sqlite3` is required (otherwise exit 1). Lutris is closed (Flatpak `kill`, then `pkill -9 lutris`).
2. The Lutris flavour (Flatpak or native) is resolved as for [`ludis install`](install.md) (environment variable `LUDIS_LUTRIS_VERSION`, saved choice in `~/.config/ludis/lutris-version`, else a one-time question if both are installed). The database must exist (`Error: Lutris database not found: <path>`, exit 1).
3. The games folder is `~/Games` or the `game_path:` of Lutris' `system.yml`.
4. All `runner='wine'` rows are loaded, minus the shared-store ones (a prefix folder shared by several rows, or a game whose name contains one of the store names as a whole word, see [`ludis list`](list.md)). If there are none: `No Wine game found in the Lutris database.` (on stderr) and **exit 0**, whatever the slugs given.
5. **Every slug is validated first.** The first unknown slug aborts the command with exit 1 (`Error: Game not found in Lutris with slug: <slug>`, or the shared-prefix error) and nothing is deleted.
6. Unless `-y`, the list of ` - <name> (<folder>)` is shown and `Are you sure you want to delete these games? [Y/n]` is asked. Pressing Enter (or any answer other than `n`/`N`) confirms. `n`/`N`, or end of input (no terminal, empty stdin), cancels (`Uninstallation cancelled.`, exit 0). Games are tracked by slug throughout, so two games with the same name are never confused.
6bis. **Saves question**, once for the whole batch, asked even with `-y` (`-y` only skips the confirmation above), unless `--save` or `--no-save` is given:

   ```
   Saves are copied to: /home/you/Documents/Ludis-saves
   Back up the saves of these 3 game(s) first? [y/N]
   ```

   The default answer is **no** (Enter). Without a terminal the answer is no. `y`/`o` copies the saves of every game of the batch, `n` copies none of them. For a single game, run [`ludis saves <slug> backup`](saves.md) yourself and answer no.

   The copy goes to the saves sync folder (see [`ludis saves`](saves.md)). If none is set yet, it is set to `Documents/Ludis-saves` (created on first use) and ludis says so. A game with no saves is not an error. If the backup of a game **fails**, that game is **not** uninstalled (`Error: the saves of '<name>' could not be backed up: the game was NOT uninstalled.`); the others go on.
7. For each game, in order:
   1. The slug must not contain `/`, `..` or control characters (otherwise the game is skipped with a warning).
   2. The prefix folder (the `directory` of the database row) is removed with `rm -rf`, **only if** its real path is inside the games folder. Otherwise the warning "the folder for '<name>' (<path>) is outside your games folder, skipping physical deletion for safety. The Lutris entry was still removed." is printed and the rest of the cleanup still happens.
   3. The Lutris config file is removed: exactly `<Lutris games config dir>/<configpath>.yml`, where `configpath` is the value stored in the database row. If the row has no usable `configpath` (empty, or containing `/`, or `.`/`..`), only files named `<slug>-<digits>.yml` are removed. Config files of other games (e.g. `mario-kart-*.yml` when uninstalling `mario`) are never touched.
   4. `DELETE FROM games WHERE slug='<slug>'`.
   5. Shortcuts removed: `<default desktop dir>/<slug>.desktop`, `<default desktop dir>/<Game name> Bonus`, the same two in `--desktop-dir` if given, and `~/.local/share/applications/net.lutris.<slug>.desktop`.
   6. The success is logged.
8. `update-desktop-database ~/.local/share/applications` is run at the end.

On `SIGINT`/`SIGTERM` the game being deleted is finished, the following ones are left untouched, and the command exits 130.

## Output

```
Games to uninstall:
 - Mario Vania (/home/me/Games/mariovania)
[1/1] Deleting 'Mario Vania'...
CLI uninstallation completed successfully!
```

The first two lines are printed only without `-y`. The final line is green on a terminal. Errors and warnings go to stderr. The text of the prompt is not displayed when stdin is not a terminal. A line `[REMOVED] <slug>` (a marker for the graphical front-end) is also printed on stdout after each game; do not rely on it.

## Exit status

| Code | Meaning |
|---|---|
| 0 | Done (including: cancelled at the prompt, a prefix skipped as unsafe, or no Wine game in the database). |
| 1 | No slug given, `sqlite3` missing, Lutris or its database not found, unknown or shared-store slug. |
| 130 | Interrupted. |

## Scripting notes

- The prompts are the `[Y/n]` confirmation and the `[y/N]` saves question (avoid it with `--save` or `--no-save`; plus the one-time Flatpak/native question if both Lutris flavours are installed; avoid it with `LUDIS_LUTRIS_VERSION=flatpak|native`).
- With stdin empty or not a terminal and no `-y`, the confirmation is **cancelled** (nothing is deleted, exit 0): `ludis uninstall slug </dev/null` deletes nothing. Use `-y` explicitly in scripts.
- `ludis uninstall slug -y` does not work: `-y` would be read as a slug and fail with "Game not found ... slug: -y".
- Validation is all-or-nothing for slugs (one bad slug, nothing deleted), but per-game failures during deletion do not change the exit status.
- Set `LC_ALL=C` to get the English messages.

## Examples

```
# Interactive
ludis uninstall mariovania

# No confirmation, several games
ludis uninstall -y mariovania papers-please

# Also clean a shortcut created in a custom folder
ludis uninstall -y --desktop-dir=/home/me/Shortcuts mariovania

# Remove every game whose name contains "demo"
ludis list | awk 'tolower($0) ~ /demo/ {print $1}' | xargs -r ludis uninstall -y
```

## Files and data touched

- With `--save` or a yes: copies the saves to the sync folder before deleting (and sets the default folder `Documents/Ludis-saves` if none was set).
- Deletes: `<games folder>/<slug>/` (recursively), `<Lutris games config dir>/<configpath>.yml` (or `<slug>-<digits>.yml` files, see Behavior), the shortcuts listed above.
- Modifies: table `games` of `pga.db` (Flatpak: `~/.var/app/net.lutris.Lutris/data/lutris/pga.db`; native: `~/.local/share/lutris/pga.db`).
- Writes: `~/.local/share/ludis/ludis.log`.
- Kills: running Lutris processes.
- Does not touch: the original `.zgp`, Lutris' downloaded cover/banner/icon files.

## See also

[`ludis install`](install.md), [`ludis saves`](saves.md), [`ludis list`](list.md), [`ludis info`](info.md), [`ludis isolate`](isolate.md); `ludis log`.
