# Global options

Options understood by the `lpm` command itself (the router in `bin/lpm`), as opposed to options that belong to one sub-command only (for example `lpm log -n`, or `lpm install --shortcut`, which are described on those commands' pages).

## Synopsis

```
lpm --version | -v
lpm --help | -h
lpm <command> [-y] [--allow-scripts] [--ignore-hash] [--hash] [-0..-22] [arguments...]
```

## Summary

| Option | Applies to | Effect |
|---|---|---|
| `-y` | `install`, `uninstall`, `isolate`, `install-runner`, `uninstall-runner`, `create-prefix`, `exe-install`, `killwine`, `check` | Answer *yes* to the command's general confirmation question. |
| `--allow-scripts` | `install` | Keep and allow launch/exit scripts embedded in a `.zgp` without asking. |
| `--ignore-hash` | `install`, `install-runner` | Do not check the sha256 sidecar file of local archives. |
| `--hash` | `pack`, `pack-runner` | Write a sha256 sidecar file for each archive created. |
| `-0` ... `-22` | `pack`, `pack-runner` | zstd compression level (default 3). |
| `--version`, `-v` | `lpm` alone | Print the version and exit. |
| `--help`, `-h` | `lpm` alone | Show the manual (or built-in help) and exit. |

Every global option is accepted in front of any command, but only the commands listed above read it; on every other command it is silently ignored.

## Where options may appear

- `--version`, `-v`, `--help` and `-h` are recognised only as the **very first argument**: `lpm --version` works, `lpm -y --version` is an error ("Unknown command: -y").
- For commands, the router reads options **immediately after the command name**, one after the other, and stops at the first word that is not one of them. Everything from that word on, including later words that look like options, is passed to the command as ordinary arguments.

  | Command line | Result |
  |---|---|
  | `lpm uninstall-runner -y Foo` | `-y` is the global option. |
  | `lpm uninstall-runner Foo -y` | `-y` is taken as a runner name; the command fails ("could not be found"). |
  | `lpm pack-runner -9 --hash Foo` | Level 9 and sidecar. |
  | `lpm pack-runner --all -9` | `-9` is taken as a runner name; the command fails. |
  | `lpm pack-runner -9 --hash --all` | Works. |

- Options are separate words: `-y -9` and not `-y9`. There is no `--` separator, no `--option=value` form and no abbreviation.
- Given several times, the same option has no extra effect, except the compression level, where the last one wins.
- Some commands accept their own options (anywhere in their arguments or in a fixed place, see each page). A name collision is possible: `-n` means "N lines" for `lpm log` but "no loading screen" for `lpm install`, and it is never a global option.
- Commands that forward all their arguments to their script (`log`, `lutris-version`, `self-update`, `info`, `shortcut`, `icon`, `splash`, `logo`, `sync-media`, `tools`, `lsfg`, `lsfg-dll`, `sgdb-key`, `sgdb-images`, `launcher`, `launcher-entries`) still lose any global option written first: `lpm log -5` and `lpm log -y` are the same as `lpm log`. `list`, `list-isolable` and `list-runner`, `list-remote-runners` ignore every argument.

## -y

Skips the confirmation of the form "Are you sure ...? [Y/n]". Per command:

| Command | What `-y` skips |
|---|---|
| `install`, `uninstall`, `install-runner`, `uninstall-runner` | The confirmation listing the games or runners about to be installed or deleted. |
| `isolate` | The final confirmation (number of games to isolate). |
| `create-prefix` | The confirmation before creating the prefixes. |
| `exe-install` | The confirmation before launching the Windows installer. |
| `killwine` | The confirmation before killing the Wine processes. |
| `check` | The question about installing the Flatpak lsfg-vk layer (runner downloads never ask). |

`-y` does **not** skip: the hash-mismatch question ("install anyway? [y/N]") of `install` and `install-runner`; the question about scripts embedded in a `.zgp` (that is what `--allow-scripts` is for); the choice between Flatpak and native Lutris when both are installed; the confirmation of `lpm log --clear`.

Default answers of the confirmations: for the `[Y/n]` questions of `install`, `uninstall`, `isolate`, `install-runner` and `uninstall-runner`, pressing Enter or typing anything other than `n`/`N` confirms, while end of input (no terminal, empty or closed standard input) **cancels**. For the `[Y/n]` questions of `create-prefix` and `exe-install`, Enter, `y`, `Y`, `o` and `O` confirm; any other text and end of input cancel.

## --allow-scripts

Applies to `lpm install` only. A game archive can embed Lutris launch/exit commands (keys such as `prelaunch_command`, `postexit_command`, `*_script`, `*_wait` or containing `exec`) that Lutris would run automatically every time the game starts or closes. Without this option, `install` lists them and asks; if you do not allow them they are commented out in the game's configuration, not deleted. With `--allow-scripts` they are kept active without a question and a note is printed. Use it only for archives you trust or made yourself. `-y` never implies it.

## --ignore-hash

Applies to `install` and `install-runner`. Skips the comparison of a **local** archive with its sha256 sidecar file (`hash/<archive>.sha256` or `<archive>.sha256`, next to the archive; see [Archive formats](archives.md)). It does not touch the check that `install-runner` and `check` make on remote runners against the digest published by GitHub.

## --hash

Applies to `pack` and `pack-runner`. After an archive is written, also writes its sha256 sidecar to `$HOME/hash/<archive>.sha256`. Without it, no sidecar is produced (the commands never ask).

## -0 ... -22 (compression level)

Applies to `pack` and `pack-runner`. A single glued token made of a dash and a number from 0 to 22: `-0`, `-9`, `-19`, `-22`. The default is 3 when none is given. Levels 20 to 22 are zstd's "ultra" levels (high memory use, slow). Higher levels give smaller archives but take longer, and do not change how the archive is installed. Numbers above 22, leading zeros (`-05`) and forms like `-l 9` are not recognised as levels and fall through as normal arguments.

## --version, -v

Prints `lpm v0.9.3` (the installed version) on standard output and exits 0. Only valid as the first argument. To use the version in a script: `lpm --version | cut -d' ' -f2`.

## --help, -h

Only valid as the first argument. If the `man` command exists and the lpm manual page is installed (a `man -w lpm` check succeeds), `lpm --help` opens it with `man lpm` (a pager on a terminal). Otherwise (running from a source checkout, or a minimal system) it prints the built-in summary of all commands and options and exits 0. Running `lpm` with **no argument** always prints the built-in summary and exits 0; it does not open any window or interactive menu. A word such as `lpm help` is an unknown command (message "Unknown command: help", exit 1).

For a pipe-friendly text of the manual: `man lpm | col -b`.

## Environment

| Variable | Effect |
|---|---|
| `LC_ALL`, `LC_MESSAGES`, `LANG` (first one set) | Language of all messages. English is the base; a translation (French is provided) overrides it key by key. `LC_ALL=C` gives English. |
| `LPM_LUTRIS_VERSION` | `flatpak` or `native`: which Lutris to use when both are installed, for this run only and without saving (see [`lpm lutris-version`](lutris-version.md)). Ignored if that version is not installed. |
| `HOME` | Base of every path lpm uses (archives are written to `$HOME`, the log is `~/.local/share/lpm/lpm.log`, the saved Lutris choice is `~/.config/lpm/lutris-version`). |
| `TMPDIR` | Location of temporary download folders (default `/tmp`). |

## Exit status

Router level: `--version` and `--help` exit 0; an unknown command prints "Unknown command: <word>" and "Use 'lpm --help' to list the available commands, or 'lpm-gui' to open the graphical interface." and exits 1. Everything else is the exit status of the command run.

## Scripting notes

- Put global options right after the command name, before any file, slug or runner name.
- For unattended runs: `-y` for confirmations, `--allow-scripts` only for trusted archives, `--ignore-hash` to skip sidecar prompts, and `LPM_LUTRIS_VERSION` to avoid the dual-Lutris question. The remaining hash-mismatch question cannot be answered by `-y`; with closed standard input it means *no*.
- A command run with its standard input closed or empty never hangs on a prompt: `read` returns at once, with the defaults described above (cancel for the confirmations, no for `[y/N]`).

## Examples

```
lpm install -y --allow-scripts Game.zgp
lpm install-runner -y --ignore-hash ./GE-Proton9-1.zgr
lpm pack -19 --hash my-game
lpm pack-runner -3 --hash --all
lpm --version
```

## See also

[`lpm install-runner`](install-runner.md), [`lpm uninstall-runner`](uninstall-runner.md), [`lpm pack-runner`](pack-runner.md), [`lpm check`](check.md), [`lpm install`](install.md), [`lpm pack`](pack.md), [Archive formats](archives.md)
