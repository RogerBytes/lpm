# lpm info

Shows the known metadata of one installed Wine game: name, prefix, executable, runner, install date and isolation status.

## Synopsis

```
lpm info <slug>
```

## Description

`lpm info` cross-reads the Lutris database and the game's Lutris configuration file and prints seven labelled lines about a single game. It is read-only. Unlike `list`, `pack` or `uninstall`, it also works for games that live in a shared store prefix, and tells you so.

## Arguments

| Argument | Meaning |
|---|---|
| `<slug>` | Slug of a game whose runner is `wine` in the Lutris database, as printed by [`lpm list`](list.md). Mandatory; only the first argument is used. |

## Options

None.

## Behavior

1. No slug: `Error: provide a slug (usage: lpm info <slug>).`, exit 1.
2. Requires `sqlite3`; detects the Lutris flavour (same rules as [`lpm list`](list.md)) and opens `pga.db`; errors give exit 1.
3. Looks up the `wine` row with that slug. None: `Error: no installed game with slug '<slug>'.`, exit 1.
4. Prefix: the `directory` of the row, resolved to a real path if the folder exists, else shown as stored.
5. Runner: `wine.version` read (with `python3`/PyYAML) from `<Lutris games config dir>/<configpath>.yml`; `unknown` if the file, key, or Python module is missing, or if `configpath` contains `/`.
6. Install date: the `installed_at` timestamp formatted `YYYY-MM-DD`; `unknown` if empty. A value that is not a plain number is shown as stored.
7. Isolation: if more than one `wine` row shares the same prefix folder, the game is "shared": the store is shown if recognised (and the exact `lpm isolate` command). Otherwise "dedicated".
8. Prints the seven lines. Nothing is modified, Lutris is not stopped.

## Output

```
Name             : Mario Vania
Slug             : mariovania
Wineprefix       : /home/me/Games/mariovania
Executable       : /home/me/Games/mariovania/drive_c/Games/Mario/mario.exe
Wine runner      : GE-Proton9
Installed on     : 2023-11-14
Isolation        : dedicated prefix (one-game-one-prefix)
```

The `Isolation` line is one of:

- `dedicated prefix (one-game-one-prefix)`
- `shared prefix (Epic Games Store) -- isolable via 'lpm isolate fortnite'` (store name as in [`list-isolable`](list-isolable.md))
- `shared prefix, unrecognized store`

When the executable (or other value) is empty the word `unknown` is printed. Errors go to stderr.

## Exit status

| Code | Meaning |
|---|---|
| 0 | Game found and printed. |
| 1 | No slug, `sqlite3` missing, Lutris or database not found, slug not found. |

## Scripting notes

- No prompt, except the one-time Flatpak/native question when Lutris is installed both ways and nothing is saved (stderr; empty stdin selects Flatpak; avoid with `LPM_LUTRIS_VERSION=flatpak|native`).
- The format is fixed-width `Label<spaces>: value`, one field per line, always in the order above. Parse by splitting each line on the first `" : "`; the value is the remainder (it can contain spaces or `:`). For example: `lpm info mygame | sed -n 's/^Wineprefix *: //p'`.
- **The labels and the words `unknown` / the isolation text are translated** according to the locale (`LC_ALL`, then `LC_MESSAGES`, then `LANG`). In scripts, force English with `LC_ALL=C lpm info <slug>`.
- Use the exit status to test existence: `lpm info "$slug" >/dev/null 2>&1`. Note that a failure also writes an `ERROR` line to the lpm log.

## Examples

```
lpm info mariovania

# Prefix folder of a game
LC_ALL=C lpm info mariovania | sed -n 's/^Wineprefix *: //p'

# Does this game exist?
if LC_ALL=C lpm info "$slug" >/dev/null 2>&1; then echo "installed"; fi
```

## Files and data touched

- Reads: Lutris `pga.db`, `<Lutris games config dir>/<configpath>.yml` (`~/.config/lutris/games/` for the native package, `~/.var/app/net.lutris.Lutris/data/lutris/games/` for Flatpak), `~/.config/lpm/lutris-version`.
- Writes nothing (except an error entry in `~/.local/share/lpm/lpm.log` on failure).

## See also

[`lpm list`](list.md), [`lpm list-isolable`](list-isolable.md), [`lpm isolate`](isolate.md), [`lpm uninstall`](uninstall.md), [`lpm pack`](pack.md).
