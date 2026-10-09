# lpm icon

Downloads an icon for one or more installed games from SteamGridDB (with a Steam fallback) and refreshes the games' existing shortcuts so that they use it.

## Synopsis

```
lpm icon <slug>... [--url <url>]
lpm icon --all
```

## Description

For each target game, `lpm icon` looks the game up on SteamGridDB by its Lutris name, picks an icon, converts it to PNG, stores it in `<game dir>/icon/` and regenerates the game's menu/desktop shortcuts if they already exist. It depends on a third-party service and needs a personal SteamGridDB API key (see Scripting notes); it is never run automatically by other commands.

Only Wine games (`runner='wine'`) not living in a shared store prefix are eligible.

Requires `sqlite3`, `curl`, `python3`, `realpath` and ImageMagick (`magick`, or `convert` + `identify`).

## Arguments

- `<slug>...` : Lutris slugs of installed games.
- `--all` : every eligible game. Recognised only as the first target.

## Options

| Option | Effect |
| --- | --- |
| `--url <url>` | Skip the SteamGridDB search and use this image URL directly. Requires exactly one target game (error otherwise). Used by the GUI after its visual picker. The value is the next argument; the `--url=` form does not exist. |

The generic options of `bin/lpm` (`-y`, ...) have no effect here.

## Behavior

1. Checks required commands and ImageMagick, resolves Lutris (Flatpak or native) and loads the Wine games from `pga.db`.
2. Resolves the targets. An unknown or shared-store slug stops the command with status 1 before anything is done. With `--url`, the number of targets must be exactly 1.
3. Obtains a valid SteamGridDB key (even if there is no target): reads the saved key and tests it with a real API call; if missing or rejected, prompts for one (see Scripting notes). No valid key: prints "No valid API key was provided. Icon fetch cancelled." and exits 1.
4. For each game:
   - Without `--url`: searches SteamGridDB (autocomplete) with the game's Lutris name. No result: skipped. Several results: lists them numbered and asks `Pick a number: `; an invalid or empty answer skips the game. One result: used directly.
   - Gathers candidate icons: SteamGridDB icons for the game (default and `styles=official`) plus, via the Steam store search and `api.steamcmd.net`, the Steam "client icon" (`.ico`) or, failing that, the small Steam icon. Candidates are listed in that order and the first one is used: so the first SteamGridDB icon when the game has any, and the Steam client icon only when SteamGridDB has none.
   - Deletes the existing `*.png`, `*.ico`, `*.svg`, `*.xpm` in `<game dir>/icon/`, downloads the chosen image there, converts `.ico` to `icon.png` (largest frame via ImageMagick), or keeps other formats as `icon.<ext>`.
   - If the menu shortcut (`~/.local/share/applications/net.lutris.<slug>.desktop`) and/or the desktop shortcut (`<desktop dir>/<slug>.desktop`) already exist, rewrites them to use the new icon. No new shortcut is created.
   - Logs the result in `lpm.log` and prints `Icon set for <name>.`
5. Failures on one game do not stop the others; the final status is 1 if any game failed.

Note: the icon directory is emptied before the download, so a failed download leaves the game without a custom icon.

## Output

stdout: `Icon set for <name>.` per success.

stderr (skips and errors):

```
A SteamGridDB API key is required. Create a free account at https://www.steamgriddb.com/profile/preferences/api to get your personal key. This key is yours alone and stays on this machine.
Invalid or unreachable API key. Please try again.
No valid API key was provided. Icon fetch cancelled.
Skipped '<name>': not found on SteamGridDB.
Skipped '<name>': no icon available on SteamGridDB.
Skipped '<name>': cancelled by user.
Skipped '<name>': icon download failed.
Skipped '<name>': .ico to .png conversion failed.
Error: no installed game with slug '<slug>'.
Error: '<slug>' lives in a shared store prefix and is not eligible for this command.
Error: --url can only target a single game at a time.
Error: '<cmd>' is not installed on this system.
Error: ImageMagick ('convert'/'identify' or 'magick') is not installed on this system.
Error: Lutris is not installed on this system.
Error: Lutris database not found at: <path>
No installed games found.
```

## Exit status

- `0` : every target succeeded; also "No installed games found" and the case of no target at all (after the key check).
- `1` : missing dependency, Lutris/database missing, bad slug, `--url` with several targets, no valid API key, or at least one game skipped/failed.

## Scripting notes

- **API key**: personal, never shipped with lpm. Stored as the first line of `${XDG_CONFIG_HOME:-$HOME/.config}/lpm/steamgriddb.key`, mode 600. It is validated by a request to `https://www.steamgriddb.com/api/v2/search/autocomplete/a` (HTTP 200 = valid, timeout 10 s) every time the command runs. Get one at https://www.steamgriddb.com/profile/preferences/api. Save it non-interactively with `lpm sgdb-key set <key>` before scripting.
- **Interactive prompts**: (1) `Paste your SteamGridDB API key: ` when no valid key is saved (loops until a valid key or an empty answer); avoided by saving a valid key beforehand. (2) `Pick a number: ` when SteamGridDB returns several games for a name; avoided only with `--url <url>` (single game). In a script without that, an ambiguous game is skipped (empty/EOF answer).
- Without a TTY on stdin, `read` gets EOF: an empty answer. The key prompt then ends with exit 1; the picker skips the game. The prompt text itself is only displayed when stdin is a terminal.
- The dual-Lutris question (`Use [1] Flatpak (default) or [2] the native package? :`) can appear; avoid it with `LPM_LUTRIS_VERSION=flatpak|native` or `lpm lutris-version`.
- `--url` as the last argument without a value is treated as not given (normal SteamGridDB search).
- Needs network access (steamgriddb.com, store.steampowered.com, api.steamcmd.net, the image host).
- Stable output: the `Icon set for <name>.` lines; error texts follow the system language (`LC_ALL=C` for English).

## Examples

```
lpm sgdb-key set "$MY_KEY"
lpm icon my-game
lpm icon --all
lpm icon my-game --url https://example.com/icon.png
```

## Files and data touched

- `${XDG_CONFIG_HOME:-~/.config}/lpm/steamgriddb.key` (read; written when a new key is accepted).
- `<game dir>/icon/icon.png` (or `icon.<ext>`), temporary `.lpm-download.<ext>`.
- Existing shortcuts: `~/.local/share/applications/net.lutris.<slug>.desktop`, `<desktop dir>/<slug>.desktop`.
- Lutris `pga.db` (read), `~/.local/share/lpm/lpm.log`.

## See also

`lpm shortcut`, `lpm splash`, `lpm logo`, `lpm sgdb-key`, `lpm sgdb-images`, `lpm sync-media`
