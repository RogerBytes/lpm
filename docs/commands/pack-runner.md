# lpm pack-runner

Packs one or more installed Wine/Proton runners into portable `.zgr` archives (zstd-compressed tar), optionally with a sha256 sidecar file.

## Synopsis

```
lpm pack-runner [-0..-22] [--hash] <name>...
lpm pack-runner [-0..-22] [--hash] --all
```

## Description

For every runner name given, `pack-runner` archives the runner's folder from Lutris' runners directory into `$HOME/<name>.zgr`. The archive can be installed on another machine (or later on this one) with [`lpm install-runner`](install-runner.md). The format is described in [Archive formats](archives.md).

The archive is always written to your **home directory** (`$HOME`), not to the current directory, and there is no option to choose another location. Move it afterwards if needed.

The runner folder itself is not modified.

## Arguments

| Argument | Meaning |
|---|---|
| `<name>...` | Names of installed runner folders, as printed by [`lpm list-runner`](list-runner.md). A name is reduced to its last path component (`/a/b/x` and `x/` mean `x`). |
| `--all` | Only when it is the **single** argument: packs every folder found in the runners directory (sorted). If the runners directory has no sub-folder: "No Wine/Proton runner found in <folder>.", exit 1. `--all` is not listed in `lpm --help` nor in the man page. |

With no argument at all, the command prints `Error: nothing to do, no target given to 'lpm pack-runner'. Run 'lpm --help' for the usage.` on stderr and exits 1.

## Options

`--hash` and the compression level are read by `bin/lpm` and must be written **before the first name** (right after `pack-runner`). Written after a name, they are taken as runner names (`-5` then fails with "could not be found"). `--all` must come after them and alone: `lpm pack-runner -9 --all` works, `lpm pack-runner --all -9` does not. See [Global options](options.md).

| Option | Meaning |
|---|---|
| `-0` ... `-22` | zstd compression level (a single glued token such as `-9`; the last one given wins). Default: 3. Levels 20 to 22 use zstd's `--ultra` mode and need a lot of memory and time. |
| `--hash` | Also write a sha256 sidecar file `$HOME/hash/<name>.zgr.sha256`. |

`-y`, `--ignore-hash` and `--allow-scripts` are accepted by the router but ignored.

## Behavior

1. **Dependency**: `zstd` must be installed, otherwise "Error: 'zstd' is not installed on this system.", exit 1. `pv` is optional (used for the progress display); `tar` is always used.
2. **Lutris detection**: Flatpak or native (see [`lpm lutris-version`](lutris-version.md) when both are installed). Not found: "Error: Lutris is not installed on this system.", exit 1.
3. **Runners folder**: `~/.var/app/net.lutris.Lutris/data/lutris/runners/wine` (Flatpak) or `~/.local/share/lutris/runners/wine` (native). Missing: "Error: Runner folder not found: <path>", exit 1.
4. **Checks for all names before any packing (all or nothing)**:
   - a name that is not a folder in the runners folder: "Error: the following runner(s) could not be found in '<folder>':" + list;
   - a file `$HOME/<name>.zgr` that already exists (it is never overwritten): "Error: a package already exists for the following runner(s) in '<$HOME>':" + list + "Delete them or move them before running the export again.".
   Any problem ends with "No runner was exported." and exit 1.
5. **Packing**, one runner after another: prints "[n/total] Compressing '<name>' (Level L):" then runs `tar -C <runners folder> -cf - <name> | zstd -L > $HOME/<name>.zgr` (with `pv` in between when available, for progress). If tar or zstd fails, or the file is empty: "Error: compression of '<name>' failed.", the partial file is deleted and the command exits 1 immediately (earlier archives of the batch are kept).
6. The archive is set to mode `600` (owner only).
7. With `--hash`, the sha256 of the finished archive is written, as 64 hex digits and a newline, to `$HOME/hash/<name>.zgr.sha256` (folder created if needed). If the sidecar cannot be written, this is silently ignored: the archive is kept and the exit status is unaffected.
8. Prints "Done: <archive path>" per runner, then "CLI export completed successfully!".

If the command receives SIGINT/SIGTERM, the archive being written (and its sidecar path) is deleted, finished archives are kept, and the command exits 130 with "Export cancelled: the archive in progress was deleted.".

The runner is archived as is: contents, permissions and symbolic links are stored without cleaning or anonymising (unlike [`lpm pack`](pack.md) for games). Existing `hash/<name>.zgr.sha256` files are overwritten when `--hash` is used.

## Output

```
[1/1] Compressing 'GE-Proton9-1' (Level 3):
Done: /home/you/GE-Proton9-1.zgr
CLI export completed successfully!
```

Standard output also contains bracketed progress and "exported" lines intended for the graphical interface; they are not part of the documented interface. The "Done:" lines are green on a terminal. Errors go to standard error and to the log ([`lpm log`](log.md)).

## Exit status

| Code | Meaning |
|---|---|
| 0 | All runners packed. |
| 1 | `zstd` or Lutris missing; runners folder missing; no name given; unknown runner name; target archive already exists; compression failed. |
| 130 | Interrupted. |

## Scripting notes

- No interactive prompt in this command (the dual-Lutris prompt excepted: if both Flatpak and native Lutris are installed and no choice is saved, it asks on standard input and an empty answer picks Flatpak **and saves it**; avoid it with `LPM_LUTRIS_VERSION=flatpak|native`).
- The result path is predictable: `$HOME/<name>.zgr` and, with `--hash`, `$HOME/hash/<name>.zgr.sha256`. Parse the exit status, not the output.
- To re-pack a runner that was already packed, delete or move the old `$HOME/<name>.zgr` first.
- Keep an archive and its sidecar together: the installer looks for `hash/<archive>.sha256` or `<archive>.sha256` next to the archive, by the archive's file name.

## Examples

```
lpm pack-runner GE-Proton9-1
lpm pack-runner -9 --hash wine-ge-8-26 GE-Proton9-1
lpm pack-runner -1 --all
mv ~/GE-Proton9-1.zgr ~/hash ~/Share/
```

## Files and data touched

- Reads: the runner folder(s) under the runners folder.
- Writes: `$HOME/<name>.zgr` (mode 600), `$HOME/hash/<name>.zgr.sha256` (with `--hash`), `~/.local/share/lpm/lpm.log` (errors), `~/.config/lpm/lutris-version` (only for the dual-Lutris choice).

## See also

[`lpm install-runner`](install-runner.md), [`lpm uninstall-runner`](uninstall-runner.md), [`lpm list-runner`](list-runner.md), [`lpm pack`](pack.md), [Archive formats](archives.md), [Global options](options.md)
