# ludis rename

Changes the display name of a game in Lutris.

## Synopsis

```
ludis rename <slug> <name>
```

## Description

Changes the name Lutris shows for an installed Wine game (in its list, in its window titles). Only the **display name** changes: the slug, the game folder and the prefix stay as they are, so nothing else breaks (shortcuts, saves, packages already made).

The next export ([`ludis pack`](pack.md)) uses the name Lutris shows, so exporting the game again keeps the new name in the `.zgp` (and in the file name of the archive). Archives made before the change keep the old name.

## Arguments

| Argument | Meaning |
|---|---|
| `<slug>` | Slug of an installed Wine game (see [`ludis list`](list.md)). |
| `<name>` | The new name, **in one argument** (quote it if it contains spaces). Leading and trailing spaces are removed. From 1 to 100 characters, without control characters (tab, new line...). |

Without both arguments: `Error: nothing to do, no target given to 'ludis rename <slug> <name>'. ...`, exit 1.

## Options

None.

## Behavior

1. `sqlite3` and Lutris must be installed. If both Lutris installations exist, the choice of [`ludis lutris-version`](lutris-version.md) is used (the question may be asked once).
2. The game must exist in the Lutris database with the `wine` runner: `Error: game '<slug>' not found.`
3. The `name` column of the game is updated. Nothing else is modified, and the action is written to the ludis log (`rename`).
4. Lutris is **not** stopped: if it is open, restart it to see the new name.

Shortcuts (menu or desktop) already created keep their old name; regenerate them with [`ludis shortcut`](shortcut.md) if you want the new one there.

## Output

```
$ ludis rename mario "Mario World"
Renamed: 'Mario' -> 'Mario World'. Restart Lutris if it is open. Export the game again to keep the new name in the package.
```

Errors go to stderr: `Error: invalid name (1 to 100 characters, no control characters).`, `Error: game '<slug>' not found.`

## Exit status

| Code | Meaning |
|---|---|
| 0 | The name was changed. |
| 1 | Missing argument, invalid name, `sqlite3` or Lutris missing, game not found, or the database could not be written. |

## Scripting notes

- No prompt, except the one-time Flatpak/native question when both Lutris are installed and nothing is saved (avoid it with `LUDIS_LUTRIS_VERSION=flatpak` or `native`).
- The name may contain an apostrophe or any other printable character; it is stored as is.
- Messages follow the locale; use `LC_ALL=C` for English.

## Examples

```
ludis rename mariovania "Mario Vania (Remastered)"

# Then export it again with the new name
ludis pack mariovania
```

## Files and data touched

- Modifies: the `name` of the game in the Lutris database (`pga.db`).
- Writes: `~/.local/share/ludis/ludis.log`.

## See also

[`ludis list`](list.md), [`ludis pack`](pack.md), [`ludis shortcut`](shortcut.md), [`ludis game-version`](game-version.md).
