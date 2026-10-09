# lpm sgdb-images

Advanced command: lists candidate images (icons, splash banners, logos) from SteamGridDB for a game, or resolves the game's SteamGridDB identity, and prints the result as JSON. Not listed in `lpm --help`; it is the "candidate list" step of the graphical image picker.

## Synopsis

```
lpm sgdb-images <icon|splash|logo|title> <slug> [<game_id> [<game_name>]]
```

## Description

`sgdb-images` never changes the game, never prompts, and never writes to Lutris. It is meant to be followed, once an image has been chosen, by `lpm icon|splash|logo <slug> --url <url>`, which does the download and installation.

It needs a valid personal SteamGridDB API key (see `lpm sgdb-key`). Requires `sqlite3`, `curl`, `python3`, a detectable Lutris and, except for `title`, ImageMagick (`magick`, or `convert` + `identify`).

## Arguments

- `<type>` : `icon`, `splash`, `logo` or `title`.
  - `icon`, `splash`, `logo`: return candidate images (SteamGridDB icons plus the Steam client icon; "hero" banners; logos with a Steam `logo.png` fallback), with local thumbnails.
  - `title`: only resolves the SteamGridDB game (id and name); no image is fetched and no ImageMagick is needed.
- `<slug>` : Lutris slug of a Wine game. Required.
- `<game_id>` : optional SteamGridDB game id already chosen (skips the name search).
- `<game_name>` : optional SteamGridDB name matching `<game_id>`. If omitted, the Lutris name is used and the slug is not looked up in the database.

## Options

None.

## Behavior

1. Validates the type and that a slug is given (usage errors, exit 1), then the commands `sqlite3`, `curl`, `python3`, and ImageMagick (not for `title`). Resolves Lutris (Flatpak or native) and the database (errors, exit 1).
2. Name: `<game_name>` if given, otherwise the Lutris name of `<slug>` (`runner='wine'`); unknown slug gives the JSON `{"error": "slug_not_found"}`. Shared-store games are **not** excluded here.
3. Key: reads `${XDG_CONFIG_HOME:-$HOME/.config}/lpm/steamgriddb.key` and tests it on the API; missing or invalid gives `{"error": "no_key"}`. No prompt.
4. Game identity: if `<game_id>` was not given, searches SteamGridDB by name. No result gives `{"error": "not_found"}`. Several results give `{"need_game_choice": true, "matches": [...]}` (the caller must pick one and call again with `<game_id>` and `<game_name>`). Exactly one: used.
5. `title`: prints `{"game_id": ..., "game_name": ...}` and stops.
6. `icon`/`splash`/`logo`: collects candidates (`logo` falls back to the Steam store `logo.png` if SteamGridDB has none); none gives `{"error": "no_candidates", "game_id": ..., "game_name": ...}`. Otherwise downloads every candidate thumbnail in parallel into a new temporary directory, normalises each with ImageMagick to a fixed box (`icon` 112x112 cropped, `splash` 186x60 cropped, `logo` 170x96 contained on a transparent canvas) as PNG, and prints the list.

## Output

All results are one JSON object on stdout (exit 0), except usage/environment errors.

Success for `icon`, `splash`, `logo`:

```json
{"game_id": "1234", "game_name": "Some Game",
 "thumb_dir": "/tmp/lpm-sgdb-thumbs.AbCdEf",
 "images": [{"url": "https://...", "thumb_path": "/tmp/lpm-sgdb-thumbs.AbCdEf/0.thumb.png"}]}
```

`title`:

```json
{"game_id": "1234", "game_name": "Some Game"}
```

Ambiguous name:

```json
{"need_game_choice": true, "matches": [{"id": "1234", "name": "Some Game"}, {"id": "5678", "name": "Some Game 2"}]}
```

Errors as JSON: `{"error": "no_key"}`, `{"error": "slug_not_found"}`, `{"error": "not_found"}`, `{"error": "no_candidates", "game_id": "...", "game_name": "..."}`.

Usage/environment errors (stderr, exit 1):

```
Error: invalid type "<type>" (expected: icon, splash, logo or title).
Usage: lpm sgdb-images <icon|splash|logo|title> <slug> [game_id] [game_name]
Error: the command "<cmd>" is required and was not found.
Error: ImageMagick ("convert"/"identify" or "magick") is required.
Error: Lutris not found on this machine.
Error: Lutris database not found at: <path>
```

## Exit status

- `0` : a JSON object was printed (including the `error` objects above).
- `1` : invalid or missing type, missing slug, missing command, Lutris or database not found.

Inspect the JSON, not the exit status, to know whether it worked.

## Scripting notes

- Never interactive for SteamGridDB, but the dual-Lutris question (`Use [1] Flatpak (default) or [2] the native package? :`) can still be asked on stderr when Lutris exists in both forms and nothing was saved; avoid it with `LPM_LUTRIS_VERSION=flatpak|native` or `lpm lutris-version`.
- The JSON on stdout is the stable interface; keys appear as shown. `id` values in `matches` and `game_id` are strings. Output is `json.dumps` (non-ASCII escaped).
- `thumb_dir` is created for `icon`/`splash`/`logo` and **never removed** by lpm: the caller must delete it. It is not created for `title` or on error objects.
- `url` values are the full-resolution image URLs to pass to `lpm icon|splash|logo <slug> --url <url>`.
- Network is required (steamgriddb.com, and for icons also store.steampowered.com and api.steamcmd.net).
- With no type, the message is the "invalid type" error with an empty type, not the usage line.

## Examples

```
lpm sgdb-images title my-game
lpm sgdb-images icon my-game 1234 "Some Game"
lpm sgdb-images splash my-game | python3 -c 'import json,sys; print(len(json.load(sys.stdin).get("images", [])))'
lpm icon my-game --url "https://example.com/icon.png"
```

## Files and data touched

- Read: `${XDG_CONFIG_HOME:-~/.config}/lpm/steamgriddb.key`, Lutris `pga.db`.
- Created: temporary directory `${TMPDIR:-/tmp}/lpm-sgdb-thumbs.XXXXXX` with `<n>.raw.<ext>` and `<n>.thumb.png` files (icon/splash/logo only).
- Error lines in `~/.local/share/lpm/lpm.log`.

## See also

`lpm sgdb-key`, `lpm icon`, `lpm splash`, `lpm logo`
