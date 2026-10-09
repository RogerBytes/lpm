# lpm logo

Downloads a transparent game logo (SteamGridDB, with a Steam fallback) and stores it as the permanent overlay of the loading screen of one or more installed games.

## Synopsis

```
lpm logo <slug>... [--url <url>]
lpm logo --all
```

## Description

The logo is saved as `<game dir>/splash/logo.png` and is displayed over everything else (black screen, picker, banner) by lpm's loading screen. Without a `logo.png`, no logo is drawn. Independent of `lpm launcher`; `splash/` is created if needed.

It needs a personal SteamGridDB API key. Only Wine games not living in a shared store prefix are eligible. Requires `sqlite3`, `curl`, `python3`, `realpath` and ImageMagick (`magick` or `convert`).

## Arguments

- `<slug>...` : Lutris slugs of installed games.
- `--all` : every eligible game (recognised only as the first target).

## Options

| Option | Effect |
| --- | --- |
| `--url <url>` | Use this image URL directly (skips the SteamGridDB search and the Steam fallback). Exactly one target game is required. Separate-word form only. |

## Behavior

1. Checks dependencies, resolves Lutris, loads Wine games, resolves targets (unknown or shared-store slug = exit 1 before any work; `--url` needs exactly 1 target).
2. Ensures a valid SteamGridDB key (even with no target). No valid key: "No valid API key was provided. Logo fetch cancelled.", exit 1.
3. For each game, without `--url`:
   - SteamGridDB autocomplete search with the Lutris name. If there are several results: numbered list and `Pick a number:` prompt (invalid/empty = skipped). If there is **no** result, the command does not stop: it goes on to the Steam fallback.
   - With a SteamGridDB game: requests `logos/game/<id>?types=static&mimes=image/png,image/webp`; the first logo is used.
   - Fallback when no SteamGridDB logo was found: searches the Steam store for the Lutris name and, if the file answers (HTTP success), uses `https://cdn.cloudflare.steamstatic.com/steam/apps/<appid>/logo.png`.
   - Nothing found: skipped.
4. Creates `<game dir>/splash/`, downloads the image to a temporary file, converts it with ImageMagick (`-background none`, to keep transparency) to `logo.png`, overwriting any existing one.
5. A failure on one game does not stop the others.

## Output

stdout: `Logo set for <name>.`

stderr:

```
Skipped '<name>': no logo available on SteamGridDB or Steam.
Skipped '<name>': cancelled by user.
Skipped '<name>': logo download or conversion failed.
Error: no installed game with slug '<slug>'.
Error: '<slug>' lives in a shared store prefix and is not eligible for this command.
Error: --url can only target a single game at a time.
Invalid or unreachable API key. Please try again.
No valid API key was provided. Logo fetch cancelled.
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

- **API key**: `${XDG_CONFIG_HOME:-$HOME/.config}/lpm/steamgriddb.key` (mode 600), shared with `icon` and `splash`, validated with a live request to the SteamGridDB API on every run. Get a key at https://www.steamgriddb.com/profile/preferences/api; save it with `lpm sgdb-key set <key>`.
- **Prompts**: `Paste your SteamGridDB API key:` (no valid key saved) and `Pick a number:` (several matches). Avoid the first by saving a key; avoid the second with `--url`. With EOF/no TTY both receive an empty answer (key prompt: exit 1; picker: game skipped).
- Dual-Lutris prompt: avoid with `LPM_LUTRIS_VERSION=flatpak|native`.
- `--url` as the last argument with no value is treated as not given (normal SteamGridDB search).
- Stable output: `Logo set for <name>.`; `LC_ALL=C` for English.

## Examples

```
lpm logo my-game
lpm logo --all
lpm logo my-game --url https://example.com/logo.png
```

## Files and data touched

- `${XDG_CONFIG_HOME:-~/.config}/lpm/steamgriddb.key` (read / written).
- `<game dir>/splash/logo.png` (created or overwritten), temporary `<game dir>/splash/.lpm-download.<ext>`.
- `~/.local/share/lpm/lpm.log`.

## See also

`lpm splash`, `lpm icon`, `lpm launcher`, `lpm sgdb-key`, `lpm sgdb-images`
