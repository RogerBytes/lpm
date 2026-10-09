# lpm splash

Downloads a wide banner ("Hero" image) from SteamGridDB and stores it as the loading-screen background of one or more installed games.

## Synopsis

```
lpm splash <slug>... [--url <url>]
lpm splash --all
```

## Description

The banner is saved as `<game dir>/splash/splash.png`, the image displayed full screen by lpm's loading screen while the game starts. Without a `splash.png` the loading screen is plain black. The command is independent of `lpm launcher`: it creates `splash/` if needed whether or not the launcher is enabled for the game.

It needs a personal SteamGridDB API key (see Scripting notes). Only Wine games not living in a shared store prefix are eligible. Requires `sqlite3`, `curl`, `python3`, `realpath` and ImageMagick (`magick` or `convert`).

## Arguments

- `<slug>...` : Lutris slugs of installed games.
- `--all` : every eligible game (recognised only as the first target).

## Options

| Option | Effect |
| --- | --- |
| `--url <url>` | Use this image URL instead of searching SteamGridDB. Exactly one target game is required. Separate-word form only. |

## Behavior

1. Checks dependencies, resolves Lutris (Flatpak or native), loads Wine games from `pga.db`.
2. Resolves targets; an unknown or shared-store slug aborts with status 1 before any work. `--url` with a number of targets other than 1 is an error.
3. Ensures a valid SteamGridDB key (same logic as `lpm icon`, done even with no target). No valid key: "No valid API key was provided. Splash banner fetch cancelled.", exit 1.
4. For each game:
   - Without `--url`: SteamGridDB autocomplete search with the Lutris name; no result = skipped; several results = numbered list and `Pick a number: ` prompt (invalid/empty answer = skipped).
   - Requests `heroes/game/<id>?types=static&mimes=image/png,image/jpeg,image/webp`; the first returned image is used. None: skipped.
   - Creates `<game dir>/splash/`, downloads the image to a temporary file, converts it with ImageMagick to `splash.png` (overwriting any existing one), removes the temporary file.
5. A failure on one game does not stop the others.

## Output

stdout: `Splash banner set for <name>.`

stderr:

```
Skipped '<name>': not found on SteamGridDB.
Skipped '<name>': no splash banner available on SteamGridDB.
Skipped '<name>': cancelled by user.
Skipped '<name>': banner download failed.
Skipped '<name>': image conversion failed.
Error: no installed game with slug '<slug>'.
Error: '<slug>' lives in a shared store prefix and is not eligible for this command.
Error: --url can only target a single game at a time.
Invalid or unreachable API key. Please try again.
No valid API key was provided. Splash banner fetch cancelled.
Error: '<cmd>' is not installed on this system.
Error: ImageMagick ('convert'/'identify' or 'magick') is not installed on this system.
Error: Lutris is not installed on this system.
Error: Lutris database not found at: <path>
No installed games found.
```

## Exit status

- `0` : all targets done; also "No installed games found" and no target at all (after the key check).
- `1` : missing dependency, Lutris/database missing, bad slug, `--url` with several targets, no valid key, or at least one game skipped/failed.

## Scripting notes

- **API key**: same file and validation as `lpm icon`: `${XDG_CONFIG_HOME:-$HOME/.config}/lpm/steamgriddb.key` (mode 600), tested against the SteamGridDB API on each run. Obtain a key at https://www.steamgriddb.com/profile/preferences/api and save it with `lpm sgdb-key set <key>`.
- **Prompts**: `Paste your SteamGridDB API key: ` (only when no valid key is saved) and `Pick a number: ` (several SteamGridDB matches). Avoid the key prompt by saving a key first; avoid the picker with `--url` (single game). Without a TTY/with EOF both get an empty answer: the key prompt aborts with exit 1, the picker skips the game.
- Dual-Lutris prompt: avoid with `LPM_LUTRIS_VERSION=flatpak|native`.
- `--url` as the last argument without a value is treated as not given (normal SteamGridDB search).
- Stable output: `Splash banner set for <name>.`; use `LC_ALL=C` for English messages.

## Examples

```
lpm splash my-game
lpm splash --all
lpm splash my-game --url https://example.com/hero.png
```

## Files and data touched

- `${XDG_CONFIG_HOME:-~/.config}/lpm/steamgriddb.key` (read / written).
- `<game dir>/splash/splash.png` (created or overwritten), `<game dir>/splash/.lpm-download.<ext>` (temporary).
- `~/.local/share/lpm/lpm.log`.

## See also

`lpm logo`, `lpm icon`, `lpm launcher`, `lpm shortcut`, `lpm sgdb-key`, `lpm sgdb-images`
