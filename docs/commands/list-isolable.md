# lpm list-isolable

Lists the games that live in a shared store prefix and could be split into their own prefix with `lpm isolate`.

## Synopsis

```
lpm list-isolable
```

## Description

Some store launchers (Epic Games Store, EA App / EA Desktop, Ubisoft Connect, Battle.net) put all their games in one shared Wine prefix. lpm hides these games from [`lpm list`](list.md). `lpm list-isolable` shows them, together with the store they belong to, which tells you what [`lpm isolate`](isolate.md) would act on. It is the non-interactive way to inspect that list.

Only games whose store is recognised are shown. A game in a shared prefix of an unrecognised kind (for example one hidden only because its prefix folder is shared by several Lutris entries) is not listed, and neither are the launcher entries themselves.

## Arguments

None. Extra arguments are ignored.

## Options

None (global options such as `-y` are accepted by the router and ignored).

## Behavior

1. Requires `sqlite3`; detects the Lutris flavour and opens its `pga.db`, exactly as [`lpm list`](list.md) does (same errors, exit 1: sqlite3 missing, Lutris not installed, `Error: Lutris database not found at: <path>`).
2. Takes the set of shared-prefix `wine` games. For each one it resolves the real path of its prefix, detects the store from the names of the games that share that folder, and skips the store's own launcher entry (`Epic Games Store`, `EA App`, `EA Desktop`, `Ubisoft Connect`, `Battle.net`).
3. Prints one line per remaining game. If there is none: `No isolable games found (no shared store prefix detected).` on stderr, exit 0.

Nothing is modified and Lutris is not stopped. The listing says nothing about whether `isolate` will succeed on a given game: it may still fail later if the game's own files cannot be located in the shared prefix.

## Output

stdout, one line per game:

```
<slug><space><space><name><space><space><store label>
```

```
fortnite  Fortnite  Epic Games Store
celeste  Celeste  Epic Games Store
```

Store labels are exactly one of: `Epic Games Store`, `EA App / EA Desktop`, `Ubisoft Connect`, `Battle.net`. The lines are **not sorted** (database order). The label is a display name: it is not the value to give to `lpm isolate` (use `egs`, `ea`, `ubisoft`, `battlenet`, an alias, or the slug of a listed game; see [`lpm isolate`](isolate.md)).

## Exit status

| Code | Meaning |
|---|---|
| 0 | Success, including an empty list. |
| 1 | `sqlite3` missing, Lutris not installed, or database not found. |

## Scripting notes

- No prompt, except the one-time Flatpak/native question when Lutris is installed both ways and nothing is saved (warning on stderr, answer defaults to Flatpak on empty stdin; avoid with `LPM_LUTRIS_VERSION=flatpak|native`).
- Parsing: the slug is the first field. The store label is one of the four fixed strings above, so it can be cut from the **end** of the line; what remains between the first double space and the label is the game name (which can itself contain spaces). Example: `awk '{print $1}'` for slugs.
- Empty list: empty stdout, exit 0, message on stderr.
- stdout is not translated (the store labels are fixed English strings); only the messages on stderr follow the locale. Use `LC_ALL=C` for English messages.

## Examples

```
lpm list-isolable

# Slugs of the isolable games
lpm list-isolable | awk '{print $1}'

# Is anything isolable on Epic?
lpm list-isolable | grep -q 'Epic Games Store$' && lpm isolate epic
```

## Files and data touched

- Reads: Lutris `pga.db` and the prefix folders' real paths (`realpath`); `~/.config/lpm/lutris-version`.
- Writes nothing (except a log entry in `~/.local/share/lpm/lpm.log` if an error occurs).

## See also

[`lpm isolate`](isolate.md), [`lpm list`](list.md), [`lpm info`](info.md).
