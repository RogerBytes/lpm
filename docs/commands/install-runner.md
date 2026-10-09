# lpm install-runner

Installs one or more Wine/Proton runners into Lutris, either from local `.zgr` archives or by name from lpm's GitHub release of ready-made runners.

## Synopsis

```
lpm install-runner [-y] [--ignore-hash] <file.zgr | name>...
```

## Description

A runner is a folder (for example `GE-Proton9-1` or `wine-ge-8-26`) inside Lutris' Wine runners directory. `install-runner` extracts a `.zgr` archive (a zstd-compressed tar, see [Archive formats](archives.md)) into that directory.

Each argument is resolved as follows:

- If it is an existing regular file, it is a **local archive**. The runner name used in messages and for the "already installed" check is the file name without a trailing `.zgr` (`/tmp/GE-Proton9-1.zgr` gives `GE-Proton9-1`). The extension is not required.
- Otherwise it is a **remote runner name**: any directory part and a trailing `.zgr` are removed, and the runner is looked up as the release asset `<name>.zgr` (exact, case-sensitive match) in the GitHub release `https://github.com/RogerBytes/lpm/releases/tag/zgr-pkg`. Use [`lpm list-remote-runners`](list-remote-runners.md) to see the available names.

A path to a local file that does not exist (for example a typo in `./Foo.zgr`) is therefore not an error at parse time: it is looked up on GitHub as `Foo` and fails with "Could not find runner".

Local and remote targets can be mixed in one command.

Lutris must be installed (Flatpak or native package). If both are installed, lpm uses `LPM_LUTRIS_VERSION=flatpak|native` if set, else the choice saved by [`lpm lutris-version`](lutris-version.md), else it asks (see Scripting notes).

## Arguments

| Argument | Meaning |
|---|---|
| `<file.zgr>` | Path to a local runner archive. |
| `<name>` | Name of a runner published on the GitHub release (with or without `.zgr`). |

With no argument at all, the command prints `Error: nothing to do, no target given to 'lpm install-runner'. Run 'lpm --help' for the usage.` on stderr and exits 1, having installed nothing.

## Options

`-y` and `--ignore-hash` are read by `bin/lpm` and must be written **before the first target** (right after `install-runner`). Written after a target, they are taken as a remote runner name. See [Global options](options.md).

| Option | Meaning |
|---|---|
| `-y` | Skips the "Are you sure you want to install these runners? [Y/n]" confirmation. It does **not** skip the hash-mismatch prompt. |
| `--ignore-hash` | Skips the check of the local sha256 sidecar file (see below). It has **no effect on remote runners**, whose download is always checked against the digest given by GitHub (when GitHub provides one). |

The options `--allow-scripts`, `--hash` and `-0`..`-22` are accepted by the router but ignored by this command.

## Behavior

1. **Dependencies**: `bsdtar` (Debian/Ubuntu package `libarchive-tools`), `pv` and `sha256sum` must be present, otherwise exit 1. Remote targets additionally need `curl` or `wget`, and `python3` to read the GitHub answer; if one of them is missing the remote runner is reported as "Could not find runner" (there is no dedicated message).
2. **Lutris detection**: Flatpak or native. The runners folder is created if missing:
   - Flatpak: `~/.var/app/net.lutris.Lutris/data/lutris/runners/wine`
   - Native: `~/.local/share/lutris/runners/wine`
   If Lutris is not found: "Error: Lutris does not seem to be installed.", exit 1.
3. **Targets** are classified (local file or remote name) and the runner name is derived.
4. **Conflict check (all or nothing)**: if a folder `<runners folder>/<name>` already exists for any target, nothing is installed and the command exits 1.
5. **Integrity check of local archives** (skipped with `--ignore-hash`). For an archive `dir/name.zgr`, lpm looks for a sha256 sidecar at `dir/hash/name.zgr.sha256`, then `dir/name.zgr.sha256`. No sidecar means no check. A sidecar that is empty, malformed (not exactly 64 hex digits) or different from the archive's sha256 is a mismatch. For mismatches lpm prints "Invalid signature for the following runners:" with the list, then asks `Do you want to install them anyway? [y/N]`. `y` or `Y` keeps them; any other answer (including no answer) silently removes them from the batch. If nothing is left, the command exits 0.
6. **Confirmation** (unless `-y`): lists each runner as "(local package: <file>)" or "(remote GitHub release)" and asks `[Y/n]`. `n` or `N`, or end of input (no terminal, empty stdin), cancels ("Installation cancelled.", exit 0). Any other answer, including just pressing Enter, means yes.
7. **Release lookup**: if at least one target is remote, the release description is fetched once through the GitHub API (`https://api.github.com/repos/RogerBytes/lpm/releases/tags/zgr-pkg`, anonymous).
8. **Per runner**, in order:
   - **Local**: prints "Installing '<name>' from the local package..." then "[n/total] Extracting '<name>'...".
   - **Remote**: prints "[n/total] Downloading and installing '<name>'...", "Searching for '<name>.zgr' on the GitHub release...", then finds the asset. If it is missing (or the release could not be fetched): "Error: Could not find runner '<name>.zgr' on GitHub." and the runner is counted as failed. Otherwise the file is downloaded (`curl -Lfs`, or `wget` if curl is absent) into a private temporary directory ("Downloading '<name>':"). An empty or failed download gives "Error: Download of '<name>' failed.".
   - **Remote integrity**: if GitHub gave a `sha256:<hex>` digest for the asset, the downloaded file must match it, otherwise "Error: Invalid SHA256 checksum for '<name>'. The downloaded file is corrupted or was altered." and the runner is failed. If GitHub gave no digest, a non-blocking warning is printed ("Warning: GitHub did not provide a SHA256 checksum for '<name>' — integrity of the download was not verified.") and the install continues.
   - **Extraction**: `pv <archive> | bsdtar -xf - -C <runners folder>` with `umask 022`. `bsdtar` refuses members that escape the folder (`../`, hostile symlinks). On failure: "Error: The archive for '<name>' is corrupted or invalid (extraction failed, code N)." and the folder `<runners folder>/<name>` is removed.
   - On success: "Installation of '<name>' completed successfully!".
   - A failure on one runner does not stop the batch; the remaining runners are still processed.
9. At the end the exit status is 1 if at least one runner failed, otherwise 0.

**Important:** the folder that ends up in the runners directory is the **top-level folder stored inside the archive**, not the name of the `.zgr` file. If you rename an archive, messages and the "already installed" check use the new file name, but the installed folder keeps the original name. If a folder with that original name already exists, the extraction **merges into it and overwrites files with the same path** without any warning. Keep the file name equal to the runner folder name.

If the file is not a valid archive, `bsdtar` may fail while still creating stray entries in the runners folder (observed with a plain text file, which `bsdtar` read as a manifest). Only `<runners folder>/<name>` is cleaned up.

## Output

Typical successful local install (progress lines intended for the graphical interface are also printed on standard output and are omitted here):

```
Installing 'GE-Proton9-1' from the local package...
[1/1] Extracting 'GE-Proton9-1'...
Installation of 'GE-Proton9-1' completed successfully!
```

Errors go to standard error (in red on a terminal) and are also recorded in the log (see [`lpm log`](log.md)). The final success message is green on a terminal; colours are disabled when the stream is not a terminal.

Messages follow the system language (`LC_ALL`, `LC_MESSAGES`, `LANG`); English is used when no translation exists.

## Exit status

| Code | Meaning |
|---|---|
| 0 | All requested runners installed; or the user answered `n` at the confirmation; or the confirmation hit end of input; or every local archive was excluded after a hash mismatch. |
| 1 | A required tool is missing; Lutris not found; no target given; at least one runner already installed (nothing installed); at least one runner failed (not found remotely, download failed, bad checksum, corrupt archive). |
| 130 | Interrupted (SIGINT/SIGTERM): the temporary download and the runner being extracted are deleted, already finished runners are kept. |

Note that exit status 0 does **not** guarantee that something was installed (cancellation and hash exclusion both return 0).

## Scripting notes

- **Confirmation `[Y/n]`**: avoid with `-y`. Without `-y`, a script with empty or closed standard input (`< /dev/null`) **cancels** (exit 0, nothing installed). Pressing Enter at a terminal confirms. The prompt text itself is only displayed when standard input is a terminal.
- **Hash-mismatch prompt `[y/N]`**: **not** skipped by `-y`. With closed or empty input the answer is *no* and the mismatched runners are dropped, with exit status 0. To install archives whose sidecar does not match, use `--ignore-hash`. To make a script fail on a bad sidecar, verify it yourself first (see [Archive formats](archives.md)).
- **Dual Lutris prompt**: if both Flatpak and native Lutris are installed and no choice is saved, lpm asks `Use [1] Flatpak (default) or [2] the native package?` on standard input; an empty answer or end of input picks Flatpak **and saves it**. Avoid by exporting `LPM_LUTRIS_VERSION=flatpak` or `native`, or by running `lpm lutris-version flatpak|native` once.
- Standard output also carries bracketed machine lines for the graphical interface (progress percentages and "installed" markers). They are not a stable interface; rely on the exit status and on the human messages above, which are written to standard error for errors.
- The message "Error: Lutris does not seem to be installed." is written to standard output and is not recorded in the log; the other errors go to standard error and to the log.
- Remote lookups use the anonymous GitHub API and can fail because of rate limiting or network problems; the resulting message is the same "Could not find runner" as for a name that does not exist.
- Do not pipe a downloaded archive to `install-runner`: it needs a real file path.

## Examples

```
lpm install-runner GE-Proton9-1.zgr
lpm install-runner -y ~/Downloads/wine-ge-8-26.zgr
lpm install-runner -y GE-Proton9-1 wine-ge-8-26
lpm install-runner -y --ignore-hash ./runners/custom-build.zgr
```

Verify a sidecar by hand before an unattended install:

```
echo "$(cat hash/custom-build.zgr.sha256)  custom-build.zgr" | sha256sum -c
```

## Files and data touched

- Reads: the `.zgr` archive and its optional sidecar (`hash/<archive>.sha256` or `<archive>.sha256`, next to the archive); `~/.config/lpm/lutris-version` (saved Lutris choice).
- Writes: `<runners folder>/<runner>/...` (see Behavior step 2); `~/.config/lpm/lutris-version` (only if the dual-Lutris prompt is answered); a temporary directory under `$TMPDIR` (or `/tmp`) for remote downloads, removed afterwards; `~/.local/share/lpm/lpm.log` (errors).
- Network (remote runners only): `api.github.com` (release description) and the asset download URL given by GitHub.

## See also

[`lpm uninstall-runner`](uninstall-runner.md), [`lpm pack-runner`](pack-runner.md), [`lpm list-runner`](list-runner.md), [`lpm list-remote-runners`](list-remote-runners.md), [`lpm check`](check.md), [Archive formats](archives.md), [Global options](options.md)
