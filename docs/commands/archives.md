# Archive formats: .zgp and .zgr

lpm exchanges data in two archive types that share the same container: a **tar archive compressed with zstd**. A `.zgp` holds a game (a Wine prefix plus its Lutris configuration); a `.zgr` holds a runner (a Wine/Proton build). Both can be accompanied by an optional **sha256 sidecar file** for integrity checking.

| | `.zgp` (game) | `.zgr` (runner) |
|---|---|---|
| Created by | [`lpm pack`](pack.md) | [`lpm pack-runner`](pack-runner.md) |
| Installed by | [`lpm install`](install.md) | [`lpm install-runner`](install-runner.md) |
| Content | One folder: the game's Wine prefix, with an embedded Lutris config | One folder: the runner |
| Written to | `$HOME/<game name>.zgp` | `$HOME/<runner name>.zgr` |
| Sidecar | `--hash` at pack time | `--hash` at pack time |

## Container

- The file is a tar stream compressed as a single zstd frame: `tar -C <parent folder> -cf - <folder name> | zstd -<level>`.
- The tar stream has **exactly one top-level folder**, named after the folder being archived (the prefix folder of the game, or the runner folder), with no leading path.
- The compression level is chosen with `-0` to `-22` on the command line (default 3). Levels 20 to 22 use zstd's `--ultra` mode (much more memory and time). The level is not stored in any lpm header: it is the usual zstd frame, and decompression needs no option.
- The archive file is created with mode `600` (readable only by its owner), because a prefix can contain licence keys, saved paths and similar data.
- Reading uses `bsdtar`, which detects the compression by itself; lpm does not require the file to be zstd specifically (a gzip tar named `.zgr` also extracts), but archives created by lpm are always zstd.

You can inspect an archive without installing it:

```
bsdtar -tf Game.zgp | head
zstd -dc runner.zgr | tar -tf - | head
zstd -l runner.zgr
```

## .zgp: game archive

Built by [`lpm pack`](pack.md) from the prefix folder registered in Lutris for the game's slug (it must be inside the games folder, `~/Games` or the `game_path` set in Lutris). The archive is named after the **game's name in Lutris** (`$HOME/<name>.zgp`, falling back to the slug).

Layout:

```
<prefix-folder>/               <- single top-level folder; its name becomes the slug on install
    drive_c/                   <- the Windows C: drive (game files, users, windows, ...)
    system.reg, user.reg, userdef.reg
    lutris.json, ...           <- if present in the prefix
    zgp-game-config.yml        <- the game's Lutris configuration (added by pack)
```

Before archiving, `pack` prepares the prefix (these changes are made on the installed game itself, not on a copy): broken and device symbolic links, `dosdevices`, `Local Settings`, temporary and package-cache files and `*.orig` files in `system32`/`syswow64` are removed, links inside `drive_c` are replaced by real copies, the user folder is renamed to `steamuser`, and user names in the registry files, `lutris.json` and `goglog.ini` are replaced by the placeholder `anonuser`.

The embedded `zgp-game-config.yml` is the game's Lutris YAML, cleaned: the keys `script`, `version` and `slug` are removed, `system.env.GAMEID` is removed, the absolute prefix path is replaced by `$GAMEDIR`, any other `/home/<user>/` by `/home/anonuser/`, and `wine.version` is set to Lutris' default runner when the game had none. It carries the display name (`name:`), which the installer uses. If the game has no Lutris config file, the archive has no `zgp-game-config.yml` (the installer then reports an error but still registers the game).

On install ([`lpm install`](install.md)), the archive is extracted into a temporary folder inside the games folder; the first top-level entry becomes the slug (it must be a real directory whose name has no `/`, control characters, and is not a symbolic link); the folder is refused if `<games folder>/<slug>` already exists; `anonuser` is replaced by your user name; the embedded config is turned into a local Lutris config (`$GAMEDIR` and `/home/<user>` resolved to this machine) and the game is registered. If the config contains launch/exit scripts, they are commented out unless allowed (see [Global options](options.md), `--allow-scripts`). An archive should contain a single top-level folder: if there were several, only the first found is used.

A `.zgp` never contains games that live in a shared store prefix (Epic Games Store, EA App, Ubisoft Connect, Battle.net); `lpm pack` refuses those.

## .zgr: runner archive

Built by [`lpm pack-runner`](pack-runner.md) from a folder of Lutris' Wine runners directory:

- Flatpak Lutris: `~/.var/app/net.lutris.Lutris/data/lutris/runners/wine/`
- Native Lutris: `~/.local/share/lutris/runners/wine/`

Layout:

```
<runner-name>/                 <- single top-level folder
    bin/wine, ...              <- Wine build (lutris-ge, wine-ge, ...)
    files/bin/wine, ...        <- or a Proton build (GE-Proton, proton-cachyos, ...)
```

The runner folder is stored unchanged: no cleaning or anonymising, symbolic links kept.

On install ([`lpm install-runner`](install-runner.md)), the archive is extracted directly into the runners directory with `bsdtar` and `umask 022`. All of the archive's top-level entries are created there. **The folder name stored inside the archive is what is installed**; the file name of the `.zgr` is only used for messages and for the "already installed" check, so keep the two identical. A folder with the same name is merged into and overwritten, not refused, when the file name differs from the stored folder name.

Remote runners (published on `https://github.com/RogerBytes/lpm/releases/tag/zgr-pkg`) are the same archives: the asset `<name>.zgr` holds the folder `<name>`.

## Safety of extraction

Both installers extract with `bsdtar`, which by default rejects members whose path contains `..` or that would be written through a symbolic link pointing outside the destination. `umask 022` is set during extraction so that a crafted archive cannot create world-writable or unreadable files. These protections matter because an archive may come from someone else. Still, a `.zgp` can ship launch scripts, so only install archives from sources you trust.

## The sha256 sidecar file

A sidecar lets the installer detect a corrupted or incomplete copy of an archive. It is a separate small text file, never stored inside the archive (adding a hash to the archive would change the archive and invalidate the hash).

**Content**: the lowercase hexadecimal sha256 of the archive file, 64 characters, on one line, and nothing else (no file name, unlike the output of `sha256sum`). A file name is deliberately not stored so that renaming the archive after downloading (`Game (1).zgp`) does not invalidate it.

**Name and location**: for an archive `<dir>/<archive>`, the installer looks, in this order, for:

1. `<dir>/hash/<archive>.sha256` (several archives shared together, hashes grouped in one `hash` folder);
2. `<dir>/<archive>.sha256` (a single file shared with its sidecar next to it).

The first one found is used; if both exist, the one in `hash/` wins and the other is ignored. The lookup is by the archive's current file name: if you rename the archive, rename the sidecar the same way, otherwise it is not found and the archive is installed **without any check and without warning**.

**Generation**: `lpm pack --hash ...` and `lpm pack-runner --hash ...` compute the sha256 of the finished archive and write `$HOME/hash/<archive>.sha256` (the archive is in `$HOME`; `hash/` is created if needed). The sidecar has normal (not restricted) permissions. If it cannot be written, the failure is silent and the archive is kept. An existing sidecar with the same name is overwritten.

**Verification**: `lpm install` and `lpm install-runner` check **local** archives before extracting anything, unless `--ignore-hash` is given:

- No sidecar found: no check, no message.
- Sidecar found and matching (comparison is case-insensitive, whitespace around the hash is ignored): silent.
- Sidecar found but empty, unreadable, not exactly 64 hex digits, or different from the actual sha256: this is a mismatch. The installer lists the archives concerned ("Invalid signature for the following ...") and asks "Do you want to install them anyway? [y/N]". Only `y`/`Y` installs them; any other answer (including closed input) drops them from the batch. `-y` does not answer this question.

Manual verification (works on any system with `sha256sum`):

```
echo "$(cat hash/Game.zgp.sha256)  Game.zgp" | sha256sum -c
```

Manual generation of a compatible sidecar:

```
mkdir -p hash
sha256sum Game.zgp | cut -d' ' -f1 > hash/Game.zgp.sha256
```

**Remote runners** use a different mechanism: GitHub's API publishes a `sha256:<hex>` digest for each release asset, and `lpm install-runner` and `lpm check` compare the downloaded file with it. If GitHub provides no digest, they warn and continue (`lpm self-update` refuses to continue in that case). `--ignore-hash` does not disable this check.

**What a sidecar does not give you**: it detects accidental corruption and wrong files, but it is not a signature. Someone who can replace the archive can also replace the sidecar next to it. Obtain the hash through a channel you trust if authenticity matters.

## See also

[`lpm pack`](pack.md), [`lpm pack-runner`](pack-runner.md), [`lpm install`](install.md), [`lpm install-runner`](install-runner.md), [Global options](options.md)
