# lpm list

Prints the Wine games registered in Lutris, one per line, as `<slug>  <name>`.

## Synopsis

```
lpm list
```

## Description

Reads the Lutris database and prints every game whose runner is `wine`, sorted by name (case-insensitive). This includes games added to Lutris by other means than lpm. Games living in a prefix shared with a store launcher (Epic Games Store, EA App, Ubisoft Connect, Battle.net, Steam) are hidden because lpm does not manage them; see [`lpm list-isolable`](list-isolable.md).

The slug printed here is the identifier expected by [`lpm uninstall`](uninstall.md), [`lpm pack`](pack.md), [`lpm info`](info.md) and the other per-game commands.

## Arguments

None. Extra arguments are ignored.

## Options

None. (`-y` and the other global options are accepted by the router and ignored.)

## Behavior

1. `sqlite3` must be installed (`Error: 'sqlite3' is not installed on this system.`, exit 1).
2. The Lutris flavour is detected (Flatpak or native package). If both exist: `LPM_LUTRIS_VERSION`, else the saved choice in `~/.config/lpm/lutris-version`, else a one-time question (see Scripting notes). Neither installed: `Error: Lutris is not installed on this system.`, exit 1.
3. The database (`~/.local/share/lutris/pga.db` or `~/.var/app/net.lutris.Lutris/data/lutris/pga.db`) must exist (`Error: Lutris database not found: <path>`, exit 1).
4. `SELECT slug, name FROM games WHERE runner='wine' ORDER BY name COLLATE NOCASE`, minus the shared-store entries.
5. If nothing is left, `No games installed.` is printed on **stderr** and the exit status is 0.

Nothing is modified. Lutris is not stopped.

## Output

stdout: one line per game, exactly

```
<slug><space><space><name>
```

```
mariovania  Mario Vania
papers-please  Papers, Please
```

The slug comes first and contains no space in practice; the name is the rest of the line (it may contain spaces, even double spaces). No header, no colours, no count. The empty-list message and all errors go to stderr.

## Exit status

| Code | Meaning |
|---|---|
| 0 | Success, including an empty list. |
| 1 | `sqlite3` missing, Lutris not installed, or database not found. |

## Scripting notes

- No prompt, except the one-time "Use [1] Flatpak (default) or [2] the native package?" question when Lutris is installed both ways and nothing is saved. The question and its warning go to stderr, stdout stays clean; with empty stdin Flatpak is chosen (and saved). Avoid it with `LPM_LUTRIS_VERSION=flatpak` or `native`.
- Parse stdout only. To split: `while read -r slug name; do ...; done < <(lpm list)` (the name ends up in `name`, leading spaces stripped). To get the slugs only: `lpm list | awk '{print $1}'`.
- An empty list gives empty stdout and exit 0; test the line count, not the exit status.
- The output format does not depend on the locale; only stderr messages do (`LC_ALL=C` for English).
- Games added to Lutris with the `wine` runner outside lpm are listed too, and so may entries whose prefix no longer exists on disk.
- The hiding of shared-store games is partly name-based: any game whose name contains `Steam`, `Epic Games Store`, `EA App`, `EA Desktop`, `Ubisoft Connect` or `Battle.net` **as a whole word** (case-sensitive; delimited by non-alphanumeric characters or the ends of the name) is hidden: "Steam" or "Steam Client" are hidden, but "SteamWorld Dig" is listed. Also hidden is any game whose prefix folder is shared with another Lutris entry. Such games cannot be targeted by `uninstall` or `pack` either; `info` still works on them.
- Errors are also appended to the lpm log.

## Examples

```
lpm list

# Is a game installed?
lpm list | grep -q '^mariovania  ' && echo yes

# Number of games
lpm list | wc -l

# Slug of the game named "Mario Vania"
lpm list | awk -F'  ' '$2 == "Mario Vania" {print $1}'
```

## Files and data touched

- Reads: Lutris `pga.db` only (and `~/.config/lpm/lutris-version`).
- Writes: nothing, except an entry in `~/.local/share/lpm/lpm.log` when an error occurs.

## See also

[`lpm info`](info.md), [`lpm list-isolable`](list-isolable.md), [`lpm install`](install.md), [`lpm uninstall`](uninstall.md), [`lpm pack`](pack.md).
