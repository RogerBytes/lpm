# lpm check

Checks that every runner needed by your installed Wine games is present, downloads the missing ones from lpm's GitHub release, and reports missing optional helpers (lsfg-vk, AntimicroX).

## Synopsis

```
lpm check [-y]
```

## Description

`check` reads the Lutris database and the Lutris configuration file of every installed game whose runner is `wine`, extracts the Wine/Proton version each game asks for (the `wine.version` entry of its YAML), and compares the list with the runner folders actually installed.

- Each **missing runner** is looked up by name in lpm's GitHub release of runners (`https://github.com/RogerBytes/lpm/releases/tag/zgr-pkg`). If an asset `<runner>.zgr` exists, it is downloaded, its SHA-256 is verified against the digest published by GitHub, and it is extracted into the runners folder. **No confirmation is asked** for these downloads, with or without `-y`.
- Runners that are not on the release are listed at the end with the games that need them; install them yourself with [`lpm install-runner`](install-runner.md) from a `.zgr` file, or with ProtonUp-Qt.
- If a game has lsfg-vk enabled (`LSFGVK_ENV: 1` in its Lutris `system.env`) and lsfg-vk is not installed, or a game references AntimicroX (`system.antimicro_config`) and AntimicroX is not installed, `check` reports it. Each of these helpers is checked only if at least one game uses it.

## Arguments

None.

## Options

`-y` is read by `bin/lpm` and must be written right after `check`. See [Global options](options.md).

| Option | Meaning |
|---|---|
| `-y` | Answers *yes* to the only question `check` can ask: installing the Flatpak lsfg-vk Vulkan layer. It has no effect on runner downloads (which never ask). |

The other global options are accepted but ignored.

## Behavior

The command goes through five steps.

1. **Tools**: `sqlite3`, `python3`, `bsdtar` and `sha256sum` must exist, one after the other; the first missing one stops the command ("Error: '<tool>' is not installed on this system.", exit 1). Then `curl` or `wget` ("Error: 'curl' or 'wget' is required to reach the remote repository.") and the Python module PyYAML ("Error: the PyYAML Python module is not installed ..."). `pv` is optional (progress display). On a session that is not Wayland (no `XDG_SESSION_TYPE=wayland`, no `WAYLAND_DISPLAY`), a missing `xdotool` only prints a recommendation, without failing.
2. **Lutris**: Flatpak or native detection (see [`lpm lutris-version`](lutris-version.md) when both are installed). Not found: "Error: Lutris is not installed on this system.", exit 1. The Lutris database must exist (`~/.var/app/net.lutris.Lutris/data/lutris/pga.db` for Flatpak, `~/.local/share/lutris/pga.db` for native), otherwise "Error: Lutris database not found: <path>", exit 1. The runners folder (`.../runners/wine` next to it) is created if missing.
3. **Games**: for each game with `runner='wine'`, the file `<config dir>/<configpath>.yml` (Flatpak: `~/.var/app/net.lutris.Lutris/data/lutris/games/`, native: `~/.config/lutris/games/`) is read. A game without YAML, without `wine.version`, or whose version contains a `/` or is `.`/`..`, is ignored for the runner check.
4. **lsfg-vk and AntimicroX** (only if some game uses them):
   - lsfg-vk missing, native Lutris: prints "lsfg-vk is not installed, but is enabled for: <games>" and the hint "Run 'lpm lsfg' to get installation instructions for your distribution."
   - lsfg-vk missing, Flatpak Lutris: prints the same first line, finds the Freedesktop runtime version to use, then asks "Install the Flatpak Vulkan layer (runtime <version>) now? No password will be required." / `Continue? [y/N]`, unless `-y`. On yes it adds the `flathub` user remote if absent and runs `flatpak install --user -y flathub org.freedesktop.Platform.VulkanLayer.lsfgvk//<version>`. If the runtime version cannot be determined: "Error: could not determine the Flatpak runtime version used by Lutris." (the command continues).
   - AntimicroX missing (no `antimicrox`/`antimicro` command, no Flatpak `io.github.antimicrox.antimicrox`): prints "AntimicroX is not installed, but is referenced by: <games>. Install it via ...".
5. **Runners**: if no game references a runner: "No installed game references a Wine runner to check." and exit 0. If all are installed: "All necessary runners are already installed." and exit 0. Otherwise "Missing runners detected:" followed by " - <runner> (required by: <games>)", then for each missing runner, "[n/total] Installing '<runner>'...":
   - the release description is fetched once (anonymous GitHub API);
   - if the asset exists, it is downloaded to a temporary file `/tmp/<runner>-XXXXXX.zgr` and checked: if GitHub supplies no digest a warning is printed ("Warning: GitHub did not provide a SHA256 checksum for '<runner>' — integrity of the download was not verified.") and the install continues; if the digest does not match: "Error: Invalid SHA256 checksum for '<runner>'. The downloaded file is corrupted or was altered." and the runner stays unresolved;
   - the archive is extracted with `bsdtar` into the runners folder (`umask 022`), and the runner counts as installed only if the folder `<runners folder>/<runner>` then exists. The temporary file is removed. Success: "Runner '<runner>' installed successfully.";
   - at the end, either "Check complete: all missing runners (<list>) were installed automatically.", or a block "=== Missing runners not available on the lpm repository ===" with the raw names (one per line), a "Details:" list (` - <runner>: required by <games>`) and "For each: install it via a .zgr file (lpm install-runner <file>.zgr), or via ProtonUp-Qt.".

## Output

```
Missing runners detected:
 - RemoteA (required by: Game One, Game Two)
 - Missing-Runner-1 (required by: Game Three)

[1/2] Installing 'RemoteA'...
Downloading 'RemoteA' from the lpm repository:
Extracting 'RemoteA':
Runner 'RemoteA' installed successfully.
[2/2] Installing 'Missing-Runner-1'...

=== Missing runners not available on the lpm repository ===
Missing-Runner-1

Details:
 - Missing-Runner-1: required by Game Three

For each: install it via a .zgr file (lpm install-runner <file>.zgr), or via ProtonUp-Qt.
```

Standard output also carries bracketed `[STEP]`, `[REPORT]` and progress lines meant for the graphical interface; they are not a stable interface.

The line "Downloading '<runner>' from the lpm repository:" is a normal progress message written to standard output; it is not logged.

## Exit status

| Code | Meaning |
|---|---|
| 0 | The check ran to the end. **This includes the case where some runners could not be found or installed, and a failed lsfg-vk installation**: read the output, not the exit status, to know whether everything is resolved. |
| 1 | A required tool is missing (including PyYAML, or both `curl` and `wget`); Lutris not found; Lutris database not found. |

## Scripting notes

- **Prompts**: (1) the Flatpak lsfg-vk installation question `Continue? [y/N]`, avoided with `-y`; with closed or empty input the answer is *no*. (2) the dual-Lutris choice (both Flatpak and native installed, nothing saved): `Use [1] Flatpak (default) or [2] the native package?` on standard input; an empty answer or end of input picks Flatpak **and saves it**. Avoid with `LPM_LUTRIS_VERSION=flatpak|native` or `lpm lutris-version flatpak|native`. Runner downloads never prompt.
- Because the exit status stays 0 when runners are unresolved, a script that needs a yes/no answer can test the output text, for example `lpm check -y | grep -q 'Missing runners not available'` (the text follows the system language: set `LC_ALL=C` for stable English output).
- `check` changes the system: it downloads and extracts runners and can install a Flatpak extension (network access to GitHub and, for lsfg-vk, Flathub). It is therefore not a read-only command.
- Interrupting the command (Ctrl+C) is not handled specially: a runner being extracted can be left half extracted in the runners folder.
- Errors are appended to the lpm log ([`lpm log`](log.md)).

## Examples

```
lpm check
lpm check -y
LC_ALL=C lpm check -y | tail -n 12
```

## Files and data touched

- Reads: Lutris `pga.db`, the per-game YAML files, `~/.config/lpm/lutris-version`.
- Writes: `<runners folder>/<runner>/` (new runners), `/tmp/<runner>-XXXXXX.zgr` (temporary, removed), `~/.local/share/lpm/lpm.log`, `~/.config/lpm/lutris-version` (only for the dual-Lutris choice), and, for the Flatpak lsfg-vk installation, the user Flatpak installation (`flathub` remote and the `org.freedesktop.Platform.VulkanLayer.lsfgvk` extension).
- Network: `api.github.com`, the asset download URL, and Flathub (lsfg-vk only).

## See also

[`lpm install-runner`](install-runner.md), [`lpm list-remote-runners`](list-remote-runners.md), [`lpm list-runner`](list-runner.md), [`lpm lutris-version`](lutris-version.md), [Global options](options.md)
