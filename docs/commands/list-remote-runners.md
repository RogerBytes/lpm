# lpm list-remote-runners

Lists the runners published on lpm's GitHub release, marking those already installed.

## Synopsis

```
lpm list-remote-runners
```

## Description

lpm publishes ready-made runner archives (`.zgr`) as assets of one GitHub release: `https://github.com/RogerBytes/lpm/releases/tag/zgr-pkg`. This command queries that release and prints one runner name per asset. Any name printed here (without the "already installed" suffix) can be given to [`lpm install-runner`](install-runner.md).

Lutris does not have to be installed to list the runners; it is only used to detect which ones are already present.

## Arguments

None. Any argument is ignored.

## Options

None. The global options are accepted by the router but have no effect (see [Global options](options.md)).

## Behavior

1. **Dependencies**: `python3`, and `curl` or `wget`. Otherwise "Error: 'python3' is not installed on this system." or "Error: 'curl' or 'wget' is required to reach the remote repository.", exit 1.
2. **Local runners folder**: lpm detects Flatpak or native Lutris (using the saved choice, `LPM_LUTRIS_VERSION`, or the dual-Lutris prompt, see Scripting notes) to know where installed runners live (`~/.var/app/net.lutris.Lutris/data/lutris/runners/wine` or `~/.local/share/lutris/runners/wine`). If Lutris is not found, the native path is used and no error is raised.
3. **Query**: anonymous request to `https://api.github.com/repos/RogerBytes/lpm/releases/tags/zgr-pkg` (`curl -sf`, or `wget -qO-`). An empty answer or any HTTP error (network down, rate limit, 404): "Error: Unable to reach the remote GitHub release.", exit 1.
4. Only assets whose name ends in `.zgr` are kept; the `.zgr` suffix is removed; the names are sorted case-insensitively.
5. If no asset qualifies (or the answer is not valid JSON): "No runner available on the remote repository (or invalid GitHub response)." is printed on **standard error**, exit 0, empty standard output.
6. Each name is printed; if a folder with that name already exists in the local runners folder, the suffix `  (already installed)` (two spaces then the parenthesised text, translated according to the system language) is appended.

## Output

```
Alpha-first
RemoteA  (already installed)
RemoteBad
zz-Last
```

(Names here are examples.) The marker is a purely visual suffix; strip it before reusing a line as an argument.

## Exit status

| Code | Meaning |
|---|---|
| 0 | Success (including "No runner available ..."). |
| 1 | Missing `python3` or `curl`/`wget`; GitHub unreachable or answered with an error. |

## Scripting notes

- No confirmation prompt. The only possible prompt is the dual-Lutris choice (both Flatpak and native Lutris installed, nothing saved): asked on standard error, read from standard input; an empty answer or end of input selects Flatpak **and saves it**. Avoid with `LPM_LUTRIS_VERSION=flatpak|native`.
- Standard output contains only names (plus the optional suffix). To get plain names: `lpm list-remote-runners | sed 's/  (already installed)$//'`. In a non-English language the suffix text is translated, so for locale-independent scripts run with `LC_ALL=C` (or `LANG=en`).
- The query is anonymous and subject to GitHub's API rate limits; a failure looks the same as being offline.
- Errors are also appended to the lpm log ([`lpm log`](log.md)).

## Examples

```
lpm list-remote-runners
LC_ALL=C lpm list-remote-runners | sed 's/  (already installed)$//' | grep -i proton
LC_ALL=C lpm list-remote-runners | grep -v '(already installed)'
```

## Files and data touched

- Network: `api.github.com` (one request).
- Reads: the local runners folder (directory existence only) and `~/.config/lpm/lutris-version`.
- Writes: `~/.local/share/lpm/lpm.log` (errors); `~/.config/lpm/lutris-version` (only for the dual-Lutris choice).

## See also

[`lpm install-runner`](install-runner.md), [`lpm list-runner`](list-runner.md), [`lpm check`](check.md)
