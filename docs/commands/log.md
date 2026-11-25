# ludis log

Shows, filters or clears ludis's action log, the first place to look when an install, pack or other command failed.

## Synopsis

```
ludis log [-n <N>]
ludis log --all
ludis log --grep <pattern> [-n <N> | --all]
ludis log --clear
```

## Description

ludis appends one line to a text log for each notable event: every error message printed by a command (in the terminal or in the graphical interface), and for some commands a success or information entry (for example after `install`, `uninstall`, `pack` or a successful `self-update install`). `ludis log` reads that file. It never modifies it, except with `--clear`.

The log is a single file, `~/.local/share/ludis/ludis.log`. The location is always under `$HOME`, whatever `XDG_DATA_HOME` is set to, so that commands run by Lutris (including a Flatpak Lutris, which redefines `XDG_DATA_HOME`) write to the same file you read here.

Each line has four columns separated by a **tab**:

| Column | Content |
|---|---|
| 1 | Timestamp, ISO 8601 with numeric time zone (`2026-10-09T04:36:00+0000`). |
| 2 | Origin: a command name (`install`, `pack`, `icon`, ...) or the name of the script that reported an error (`zgr-runner-installer`, `zgc-self-update`, ...). |
| 3 | Status: `OK`, `ERROR`, `WARN` or `INFO` (always in English, whatever the language of the interface). |
| 4 | Free-text detail, often `key=value` pairs. Tabs and newlines in values are replaced by spaces. |

When the file exceeds 10 000 lines, the next write renames it to `ludis.log.1` (replacing the previous backup) and starts a new empty `ludis.log`. `ludis log` only reads the current `ludis.log`, never `ludis.log.1`.

## Arguments

None other than the options below. Any unrecognised word is an error ("Error: unknown option: '<word>'", exit 1).

## Options

The options are read by the log script itself and can be given in any order.

| Option | Meaning |
|---|---|
| `-n <N>` | Show the last `N` lines (default 50). `N` must be a non-negative integer, as a separate word: `-n 20`. `-n 0` prints nothing. Missing or non-numeric value: "Error: -n expects a positive integer.", exit 1. |
| `--all` | Show every line of the current log; takes precedence over `-n`. |
| `--grep <pattern>` | Keep only the lines containing `<pattern>` (fixed string, case-sensitive, anywhere in the line: timestamp, origin, status or detail). The filter is applied first, then `-n` counts from the end of the filtered lines. Missing pattern: "Error: --grep expects a pattern.", exit 1. |
| `--clear` | Empty the log after confirmation (see Behavior). When present, it wins over the display options, which are then ignored. |

Warning about global options: the router in `bin/ludis` consumes `-y`, `--allow-scripts`, `--hash`, `--ignore-hash` and `-0`..`-22` when they appear **right after `log`**, and silently drops them (for example `ludis log -5` behaves like `ludis log`, and `ludis log -y --all` like `ludis log --all`). Once an option of `log` itself has been given (`-n`, `--all`...), a following `-y` is passed to the script and rejected as an unknown option. See [Global options](options.md).

## Behavior

**Display (default)**

1. If `ludis.log` does not exist or is empty: "Log empty or not found (<path>). No action recorded yet." and exit 0.
2. With `--grep`, the lines are filtered; if none match: "No log line matches the pattern '<pattern>'." and exit 0.
3. Without `--all`, only the last `N` lines are kept (50 by default). The lines are printed unchanged, oldest first, newest last.

**`--clear`**

1. If neither `ludis.log` nor `ludis.log.1` exists: "The log is already empty." and exit 0.
2. Prints "This will permanently clear the log (<path>)." and asks `Confirm? [y/N]`.
3. Answers `y`, `Y`, `o`, `O`, `yes`, `oui` (any case) empty the log (`ludis.log` is truncated and `ludis.log.1` deleted) and print "Log cleared.". Any other answer, an empty answer or end of input prints "Cancelled, the log was not modified." (exit 0).

## Output

```
2026-10-09T04:36:00+0000	zgr-runner-lister	ERROR	Error: Lutris is not installed on this system.
2026-10-09T04:36:01+0000	zgc-self-update	ERROR	Unable to reach GitHub to check for updates.
```

(Columns are tab-separated.) Output is plain text with no colour.

## Exit status

| Code | Meaning |
|---|---|
| 0 | Normal display, empty log, no match, log cleared or clearing cancelled. |
| 1 | Invalid option, or missing/invalid value for `-n` or `--grep`. |

## Scripting notes

- **Parsing**: split on tabs, for example `ludis log --all | awk -F'\t' '$3 == "ERROR" { print $1, $4 }'`. The status values are always the English words `OK`, `ERROR`, `WARN` and `INFO`. Messages in column 4 are written in the interface language that was active when the line was written.
- **No match, empty log and "not found" are all exit 0**, and their message goes to standard output. Test the output, or filter with a pattern you know exists.
- **`--clear` is always interactive** and cannot be forced with `-y` (the router drops a leading `-y`, and the script has no such option). In a script, answer through standard input: `echo y | ludis log --clear`. Closed or empty input means *no*.
- Errors raised by `ludis log` itself (bad option, bad `-n`) are also appended to the log.
- Because of rotation, `ludis log --all` shows at most about 10 000 events; older ones are only in `ludis.log.1` (read it directly with any text tool).
- The log can contain file names, game names and paths: review it before sharing.

## Examples

```
ludis log
ludis log -n 200
ludis log --all
ludis log --grep ERROR -n 20
ludis log --grep zgr-runner-installer
echo y | ludis log --clear
```

## Files and data touched

- Reads: `~/.local/share/ludis/ludis.log`.
- With `--clear`: truncates `~/.local/share/ludis/ludis.log` and deletes `~/.local/share/ludis/ludis.log.1`.
- Never reads `ludis.log.1` for display.

## See also

[`ludis self-update`](self-update.md), [`ludis check`](check.md), [Global options](options.md)
