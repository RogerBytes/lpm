# lpm uninstall-runner

Permanently deletes one or more installed Wine/Proton runners from Lutris' runners folder.

## Synopsis

```
lpm uninstall-runner [-y] <name>...
```

## Description

Each `<name>` is the name of a folder inside Lutris' Wine runners directory, as printed by [`lpm list-runner`](list-runner.md). The folder is removed recursively (`rm -rf`). There is no trash and no undo; to keep a copy, run [`lpm pack-runner`](pack-runner.md) first.

The command does not check whether an installed game still uses the runner. Use [`lpm check`](check.md) afterwards to find games whose runner is missing.

Names are reduced to their last path component before use (`../x`, `/some/dir/x` and `x/` all mean `x`), so the command can only delete folders located directly inside the runners folder.

## Arguments

| Argument | Meaning |
|---|---|
| `<name>...` | One or more runner folder names. Every name must exist, otherwise nothing is deleted. A name given twice is processed twice (the second pass finds nothing to delete and still reports it). |

With no name, the command prints `Error: nothing to do, no target given to 'lpm uninstall-runner'. Run 'lpm --help' for the usage.` on stderr and exits 1, having deleted nothing.

## Options

`-y` is read by `bin/lpm` and must be written **before the first name** (right after `uninstall-runner`). Written after a name, it is taken as a runner name and the command fails with "could not be found". See [Global options](options.md).

| Option | Meaning |
|---|---|
| `-y` | Skips the "Are you sure you want to delete these runners? [Y/n]" confirmation. |

## Behavior

1. **Lutris detection**: Flatpak or native (see [`lpm lutris-version`](lutris-version.md) if both are installed). If Lutris is not found: "Error: Lutris is not installed on this system.", exit 1.
2. **Runners folder**: `~/.var/app/net.lutris.Lutris/data/lutris/runners/wine` (Flatpak) or `~/.local/share/lutris/runners/wine` (native). If it does not exist: "Error: Runner folder not found: <path>", exit 1.
3. **Existence check (all or nothing)**: if any name does not match a directory in that folder, lpm prints "Error: the following runner(s) could not be found in '<folder>':", the list, and "No runner was deleted.", and exits 1.
4. **Confirmation** (unless `-y`): prints "Runners to permanently delete:" followed by one line per runner with its full path, then asks `[Y/n]`. `n` or `N`, or end of input (no terminal, empty stdin), cancels ("Deletion cancelled.", exit 0). Any other answer, including just pressing Enter, means yes.
5. **Deletion**: for each runner prints "[n/total] Deleting '<name>'..." and removes the folder.
6. Prints "CLI uninstallation completed successfully!" and exits 0.

If the command receives SIGINT/SIGTERM during the deletion, the runner currently being deleted is finished (no half-deleted folder), the following ones are not touched, and the command exits 130 with "Uninstallation cancelled: the remaining runners were not touched.". If the signal arrives during the last runner, the command simply completes.

## Output

```
Runners to permanently delete:
 - Zeta (/home/you/.local/share/lutris/runners/wine/Zeta)
Are you sure you want to delete these runners? [Y/n]
[1/1] Deleting 'Zeta'...
CLI uninstallation completed successfully!
```

(The prompt text is only displayed when standard input is a terminal.) Standard output also contains a bracketed line per deleted runner, intended for the graphical interface. Errors go to standard error and to the log ([`lpm log`](log.md)).

## Exit status

| Code | Meaning |
|---|---|
| 0 | Runners deleted; or the confirmation was answered `n` or hit end of input. |
| 1 | Lutris not found; runners folder missing; no name given; at least one name not found (nothing deleted). |
| 130 | Interrupted before all runners were processed. |

## Scripting notes

- Pass `-y` in scripts. Without `-y`, empty or closed standard input (`< /dev/null`, a cron job, a pipe that ended) cancels: nothing is deleted and the exit status is 0.
- The "dual Lutris" prompt (both Flatpak and native installed, no saved choice) reads standard input too; an empty answer picks Flatpak and saves it. Avoid it with `LPM_LUTRIS_VERSION=flatpak|native` or by running `lpm lutris-version flatpak|native` once.
- A missing name aborts the whole batch before any deletion, so the command is safe to run with a list that may contain typos; the exit status is 1.
- There is no `--force`/`--ignore-missing`: to delete only what exists, filter the names with [`lpm list-runner`](list-runner.md) first.

## Examples

```
lpm uninstall-runner wine-ge-8-26
lpm uninstall-runner -y GE-Proton9-1 GE-Proton9-2
lpm list-runner 2>/dev/null | grep '^GE-Proton' | xargs lpm uninstall-runner -y
```

## Files and data touched

- Deletes: `<runners folder>/<name>` (recursively).
- Reads/writes `~/.config/lpm/lutris-version` (only for the dual-Lutris choice).
- Writes `~/.local/share/lpm/lpm.log` (errors only).

## See also

[`lpm install-runner`](install-runner.md), [`lpm pack-runner`](pack-runner.md), [`lpm list-runner`](list-runner.md), [`lpm check`](check.md), [Global options](options.md)
