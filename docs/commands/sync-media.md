# lpm sync-media

Downloads Lutris' own library media (banner, cover art, icon) from lutris.net for installed games that lack them.

## Synopsis

```
lpm sync-media <slug>...
lpm sync-media --all
```

## Description

Reproduces what Lutris does when syncing media: for each target, if at least one of the three media is missing locally, the lutris.net API is queried and only the missing files are downloaded. These are the thumbnails shown inside Lutris' own library; the command has nothing to do with the SteamGridDB images of `icon`, `splash` and `logo`, which are used by lpm's shortcuts and loading screen. No API key is needed.

Only Wine games not living in a shared store prefix are eligible. Requires `sqlite3`, `curl` and `python3`.

## Arguments

- `<slug>...` : Lutris slugs of installed games.
- `--all` : every eligible game (recognised only as the first target).

## Options

None specific. (`bin/lpm` generic options such as `-y` have no effect.)

## Behavior

1. Checks dependencies, resolves Lutris (Flatpak or native), reads `pga.db`, and creates the media folders if needed.
2. Builds the list of eligible slugs (duplicates removed, shared-store prefixes excluded). If none: prints "No installed games found." on stderr and exits 0.
3. Validates all targets; an unknown or shared-store slug aborts with status 1 before any download.
4. For each game:
   - Considers the media present if the file is non-empty: banner `banners/<slug>.jpg` or `.png`; cover `coverart/<slug>.jpg` or `.png`; icon `~/.local/share/icons/hicolor/128x128/apps/lutris_<slug>.png`.
   - If all three exist: logs "already complete" and prints **nothing**.
   - Otherwise requests `https://lutris.net/api/games/<slug>` (timeout 15 s). Network failure: error message, game counted as failed. HTTP status other than 200: prints the "Nothing to download" message (game unknown to lutris.net), not a failure.
   - Downloads each missing media from the URLs in the answer (`banner_url`/`banner`, `coverart`, `icon_url`/`icon`) to the paths above (timeout 30 s each). After an icon download, runs `gtk-update-icon-cache` (errors ignored).
   - Prints `Lutris media updated for '<slug>'.` if at least one file was downloaded, otherwise the "Nothing to download" message.

## Output

stdout:

```
Lutris media updated for '<slug>'.
Nothing to download for '<slug>' (already complete, or not found on lutris.net).
```

stderr:

```
Error: the lutris.net API is unreachable for '<slug>' (network down?).
Error: no installed game with slug '<slug>'.
Error: '<slug>' lives in a shared store prefix and is not eligible for this command.
Error: '<cmd>' is not installed on this system.
Error: Lutris is not installed on this system.
Error: Lutris database not found: <path>
No installed games found.
```

(`No installed games found.` goes through the error printer, so it is red on a terminal and written to `lpm.log` as an error, but the exit status is 0.)

## Exit status

- `0` : all targets processed without network failure; also the "No installed games found" case, and a call with no target at all (silent).
- `1` : missing dependency, Lutris/database missing, unknown or excluded slug, or lutris.net unreachable for at least one game.

## Scripting notes

- No interactive prompt, except the dual-Lutris question (`Use [1] Flatpak (default) or [2] the native package? :`), avoided with `LPM_LUTRIS_VERSION=flatpak|native` or `lpm lutris-version`. With EOF it selects Flatpak and saves the choice.
- With no target and no `--all`, nothing is done and the status is 0, silently.
- A game that is already complete produces no output at all, so "no output" does not mean "failure".
- The target is always the slug as given; the printed text uses the slug, not the display name.
- Stable output: the two stdout lines above. `LC_ALL=C` forces English.

## Examples

```
lpm sync-media my-game
lpm sync-media --all
LPM_LUTRIS_VERSION=native lpm sync-media my-game other-game
```

## Files and data touched

- Written: `<lutris data dir>/banners/<slug>.jpg`, `<lutris data dir>/coverart/<slug>.jpg` (`~/.local/share/lutris` native, `~/.var/app/net.lutris.Lutris/data/lutris` Flatpak), `~/.local/share/icons/hicolor/128x128/apps/lutris_<slug>.png`, icon cache of `~/.local/share/icons/hicolor`, `~/.local/share/lpm/lpm.log`.
- Read: Lutris `pga.db`.
- Network: `https://lutris.net/api/games/<slug>` and the media URLs it returns.

## See also

`lpm icon`, `lpm splash`, `lpm logo`, `lpm lutris-version`
