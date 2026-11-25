# ludis lutris-version

Shows which Lutris installations ludis detects (Flatpak and/or native package) and lets you force, or reset, the one ludis uses when both are installed.

## Synopsis

```
ludis lutris-version
ludis lutris-version flatpak
ludis lutris-version native
ludis lutris-version reset
```

## Description

Most ludis commands need to know whether to work with the Flatpak Lutris (data under `~/.var/app/net.lutris.Lutris/`) or the native one (data under `~/.local/share/lutris/` and `~/.config/lutris/`). When only one is installed, ludis uses it silently. When **both** are installed, ludis resolves the choice in this order:

1. the environment variable `LUDIS_LUTRIS_VERSION` (`flatpak` or `native`), for the current run only and never saved;
2. the saved choice in `~/.config/ludis/lutris-version` (a one-word file), if it names a version that is still installed; a saved choice pointing to a version no longer installed is silently deleted;
3. otherwise ludis asks once, and saves the answer.

`ludis lutris-version` (this command) displays the detected versions and manages the saved choice. It does not itself apply `LUDIS_LUTRIS_VERSION`: the listing always shows both installations.

Detection: Flatpak Lutris is detected with `flatpak list` (any installed application whose line contains "lutris"). Native Lutris is detected by an executable `lutris` in `PATH`, or at `/usr/bin/lutris`, `/usr/local/bin/lutris`, `/usr/games/lutris` or `/opt/lutris/bin/lutris`. Leftover data folders alone do not count as an installation.

## Arguments

| Argument | Meaning |
|---|---|
| *(none)* | List the detected versions. |
| `flatpak` | Save "Flatpak" as the version to use. Fails if Flatpak Lutris is not installed. |
| `native` | Save "native package" as the version to use. Fails if native Lutris is not installed. |
| `reset` | Delete the saved choice. |

Only the first argument is read; extra arguments are ignored. Any other value: "Invalid argument: <value> (expected: flatpak, native, or reset).", exit 1.

## Options

None. Global options are consumed by the router and have no effect (see [Global options](options.md)).

## Behavior

1. Detects both installations. If neither is present: "Error: Lutris is not installed on this system (neither Flatpak nor native package).", exit 1 (this applies to `reset` too).
2. Reads the installed version of each:
   - Flatpak: the `Version:` line of `flatpak info net.lutris.Lutris`;
   - native: the package version from `dpkg-query` (epoch and Debian revision removed), else `rpm`, else `pacman`, whichever answers first. If none answers, the version is shown as "unknown version".
3. Looks up the newest upstream version (best effort, never fatal): `https://api.github.com/repos/lutris/lutris/releases/latest`, using `curl` or `wget` and `python3`. If that fails, the listing simply has no status.
4. **No argument**: prints the list, then either the hint line (both installed) or "Only <Flatpak|Native package> is installed on this machine. Nothing to configure."
5. **`flatpak` / `native`**: writes the word to `~/.config/ludis/lutris-version` (creating `~/.config/ludis/`) and prints "Choice saved: ludis will now use <Flatpak|Native package>."
6. **`reset`**: removes the file and prints "Forced choice cleared. ludis will automatically determine which version to use again.", or "No forced choice was saved." if there was none.

## Output

```
Detected Lutris versions:
  - Flatpak       : 0.5.18 (outdated)
  - Native package: 0.5.19 (up to date)

To force a choice: 'ludis lutris-version flatpak' or 'ludis lutris-version native'. To clear it: 'ludis lutris-version reset'.
```

The status in parentheses is one of: `up to date`; `outdated` (Flatpak); `outdated -- consider Flatpak` (native); `could not check if up to date` (upstream version unavailable). It is omitted when the installed version is unknown or newer than the latest upstream tag. The comparison uses version ordering (`sort -V`).

## Exit status

| Code | Meaning |
|---|---|
| 0 | Listing shown, choice saved, or choice cleared (including "No forced choice was saved."). |
| 1 | No Lutris installed; `flatpak`/`native` requested but not installed; invalid argument. |

## Scripting notes

- This command never asks a question.
- The listing is human-oriented (translated, padded); do not parse it. To know which Lutris ludis will use in a script, set `LUDIS_LUTRIS_VERSION` yourself, or save the choice once with `ludis lutris-version native|flatpak`.
- Other ludis commands (`install`, `check`, `list-runner`, ...) **do** prompt when both Lutris installs exist and nothing is saved: `Use [1] Flatpak (default) or [2] the native package?`. An empty answer or closed input selects Flatpak and saves it; any other answer than `1` or `2` selects Flatpak for this run only without saving; `2` selects and saves native. Running `ludis lutris-version flatpak|native` first removes the prompt.
- The latest-version lookup makes one anonymous request to `api.github.com` each time the listing is shown; it fails silently when offline.
- Errors are appended to the ludis log ([`ludis log`](log.md)).

## Examples

```
ludis lutris-version
ludis lutris-version flatpak
ludis lutris-version reset
LUDIS_LUTRIS_VERSION=native ludis list-runner
```

## Files and data touched

- Reads: `~/.config/ludis/lutris-version`; package databases through `dpkg-query`/`rpm`/`pacman`; `flatpak info`.
- Writes: `~/.config/ludis/lutris-version` (`flatpak`, `native`, `reset`); `~/.local/share/ludis/ludis.log` (errors).
- Network: `api.github.com` (listing only, optional).

## See also

[`ludis check`](check.md), [`ludis list-runner`](list-runner.md), [`ludis install-runner`](install-runner.md), [Global options](options.md)
