# ludis game-version

Shows, sets or removes the version number of a game.

## Synopsis

```
ludis game-version <slug> [<value>|--clear]
ludis tools <slug> game-version [<value>|--clear]
```

## Description

A version number is a free text (`1.2.3`, `2024-03`, `GOTY`...) that you attach to a game. It is **never asked at export**; you set it here (or in the graphical interface, page "Game version").

Once set:

- [`ludis pack`](pack.md) writes it into the package: the YAML at the very beginning of the `.zgp` gets a `game_version` key, readable without unpacking the archive, and the archive is named `<Game name> (v<version>).zgp`;
- [`ludis install`](install.md) shows it, with the version of the game already installed, when a package is about to replace an installed game, and lists it next to the file name: `Mario.zgp (v1.2.3)`;
- [`ludis list`](list.md) prints it after the name: `mariovania  Mario Vania (v1.2.3)`.

Ludis only displays the numbers. It never compares them: it does not say that a version is newer or older, whatever the format.

## Arguments

| Argument | Meaning |
|---|---|
| `<slug>` | Slug of an installed game (see [`ludis list`](list.md)). Without a slug the command prints the usage of `ludis tools` and exits 1. |
| (nothing) | Prints the current version (an empty line if none). `status` and `get` do the same. |
| `<value>` | Sets it. From 1 to 32 characters among letters, digits, space, `.`, `_`, `+` and `-`. Anything else: `Error: invalid version (...)`, exit 1. |
| `--clear` (or `clear`) | Removes the version number. |

## Behavior

The number is stored in the prefix, in `ludis/settings/game-version` (one line), so it follows the game wherever the prefix goes: exported in the `.zgp`, restored when the package is installed (the installer rewrites that file from the package's `game_version` key). It is **not** put in the Lutris YAML of the game.

Lutris is not stopped and no other file is touched.

## Output

```
$ ludis game-version mario 1.2.3
Version of 'Mario' set to: 1.2.3
$ ludis game-version mario
1.2.3
$ ludis game-version mario --clear
Version number of 'Mario' removed.
```

## Exit status

| Code | Meaning |
|---|---|
| 0 | Success (including reading an empty version). |
| 1 | Missing slug, unknown game, invalid value, or the file could not be written. |

## Scripting notes

- Reading prints only the value: `v=$(ludis game-version mario)`.
- The value is not translated; the confirmation messages are (use `LC_ALL=C` for English).
- It can also be given through `ludis tools <slug> game-version`.

## Examples

```
ludis game-version mariovania 1.2.3
ludis pack mariovania            # produces "Mario Vania (v1.2.3).zgp"
ludis game-version mariovania --clear
```

## Files and data touched

- Reads and writes: `<prefix>/ludis/settings/game-version`.
- Reads: the Lutris database.

## See also

[`ludis pack`](pack.md), [`ludis install`](install.md), [`ludis list`](list.md), [`ludis rename`](rename.md), [Archives](archives.md).
