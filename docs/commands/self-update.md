# lpm self-update

Looks up the newest lpm release on GitHub and, for an lpm installed from a system package, downloads it, verifies its SHA-256 and installs it with administrator rights.

## Synopsis

```
lpm self-update [check]
lpm self-update install
```

## Description

`self-update` has two modes:

- **`check`** (the default when no argument is given) only queries GitHub and prints the latest published version, the URL of its release page and the way lpm is installed on this machine. It never modifies anything and does not need any privilege. It **does not compare** the latest version with the installed one; the caller does that.
- **`install`** installs the latest release **only if lpm was installed from a package** (`.deb`, `.rpm` or Arch `.pkg.tar.zst`) and is older than the latest release. It downloads the matching package from the release, **refuses to continue unless GitHub published a SHA-256 digest for it and the downloaded file matches**, then runs the system package manager through `pkexec` (the polkit password prompt).

lpm installed manually (`install.sh`, which puts it under `/usr/local`) or run from a source checkout is never updated automatically: lpm does not know how it was installed, so `install` prints the release page URL instead.

## Arguments

| Argument | Meaning |
|---|---|
| `check` | Print the latest release information. Default. |
| `install` | Download, verify and install the latest release (package installs only). |

Any other value is rejected with "Invalid argument: <value> (expected: check or install).", exit 1. The validation happens first, before the dependency check and any GitHub lookup, so the error is the same offline. Extra arguments are ignored.

## Options

None of its own. Global options are consumed by the router and have no effect on this command (see [Global options](options.md)); in particular `-y` does not exist here, because the only confirmation is the system's authentication prompt.

## Behavior

Common to both modes (an invalid argument has already been rejected before any of these steps):

1. **Dependency**: `python3` ("Error: 'python3' is not installed on this system.", exit 1). Downloads use `curl` or `wget`.
2. **Installation method** is detected from the location of lpm's own library folder:
   - `/usr/lib/lpm` and owned by a package whose name is `lpm` in `dpkg`: `deb`;
   - `/usr/lib/lpm` and owned by an `rpm` package: `rpm`;
   - `/usr/lib/lpm` and owned by a `pacman` package: `pkg`;
   - anything else (`/usr/local/lib/lpm` from `install.sh`, a source checkout, a folder not owned by a package): `manual`.
3. **Release lookup**: one anonymous request to `https://api.github.com/repos/RogerBytes/lpm/releases?per_page=20` (the 20 most recent releases). Drafts, pre-releases and tags that are not plain version numbers (`v0.9.4`, `0.9.4`, `1.2`; for example the runners release `zgr-pkg` or `v1.0.0-rc1`) are ignored. The highest version number wins. No answer or an HTTP error: "Unable to reach GitHub to check for updates." (exit 1); no qualifying release: "No lpm release found on GitHub." (exit 1).

`check`:

4. Prints one line and exits 0:

   ```
   [UPDATE-INFO] <latest version>|<release page URL>|<method>
   ```

   The version has no leading `v`; `<method>` is `deb`, `rpm`, `pkg` or `manual`. This is the only output of `check`. The line is also what the graphical interface reads, so treat the field order as fixed but do not expect anything else on the line.

`install`, in this order (the first failing step stops the command with exit 1):

4. Method `manual`: "This installation was not made by a package: automatic update unavailable. Download the new version here: <release URL>".
5. Latest version not newer than the installed one (compared with `sort -V`): "lpm is already up to date (<installed version>)." and **exit 0** (also when the installed version is newer than the latest release).
6. No asset in the release whose name ends in `.deb` (method `deb`), `.rpm` (`rpm`) or `.pkg.tar.zst` (`pkg`): "No '<method>' package found in release <version>." (the first matching asset is used).
7. GitHub gave no SHA-256 digest for that asset: "GitHub provides no SHA-256 digest for this package: installation refused for safety. Install the update manually from the releases page." There is no override.
8. `pkexec` not installed: "'pkexec' (polkit) is required to install the update."
9. **Download** into a private temporary directory (removed at exit), with `curl -Lfs` or `wget -q`. Failure or empty file: "Downloading the update failed."
10. **Verification**: the SHA-256 of the file is compared with the digest from the GitHub API (`sha256:<hex>`). Mismatch: "Invalid SHA-256 digest: package corrupted or tampered with, installation cancelled." Nothing is installed.
11. **Installation** with elevated rights via `pkexec`:
    - `deb`: `pkexec env DEBIAN_FRONTEND=noninteractive apt-get install -y <file>`
    - `rpm`: `pkexec dnf install -y <file>`; else `pkexec zypper --non-interactive install --allow-unsigned-rpm <file>`; else `pkexec rpm -U <file>`
    - `pkg`: `pkexec pacman -U --noconfirm <file>`

    If the command fails or the authentication is cancelled: "Installation failed or authentication was cancelled (code N)." (N is the exit code of `pkexec` or of the package manager), exit 1.
12. On success a line `[UPDATED] <new version>` is printed (this is the only success marker; there is no separate sentence), an `OK` entry is added to the log with the old and new versions and the method, and the command exits 0. The new version is used from the next `lpm` invocation.

While running, `install` also prints three phase lines (labels "Downloading the update", "Verifying integrity", "Installing (password required)") and download progress; these are intended for the graphical interface.

## Output

`lpm self-update check` on a source checkout:

```
[UPDATE-INFO] 0.9.10|https://github.com/RogerBytes/lpm/releases/tag/v0.9.10|manual
```

`lpm self-update install` on a `manual` installation:

```
This installation was not made by a package: automatic update unavailable. Download the new version here: https://github.com/RogerBytes/lpm/releases/tag/v0.9.10
```

Errors go to standard error and are logged ([`lpm log`](log.md)). The informational message "lpm is already up to date" goes to standard output.

## Exit status

| Code | Meaning |
|---|---|
| 0 | `check` succeeded; or `install` found nothing to do (already up to date); or the update was installed. |
| 1 | `python3` missing; GitHub unreachable or no release; invalid argument; `install` refused (manual install, no package, no digest, no `pkexec`); download, verification or installation failed. |

## Scripting notes

- **`check` and the "is there an update?" question**: compare the first field of the `[UPDATE-INFO]` line with the installed version printed by `lpm --version` (`lpm v0.9.3`), for example with `sort -V`. Remember that the lookup only considers the 20 most recent releases.
- **No lpm prompt** in either mode, even without a terminal. But `install` needs a polkit authentication agent: from a plain SSH session, a cron job or a session without agent, `pkexec` fails (or prompts on the terminal if a text agent is available) and you get the "Installation failed or authentication was cancelled" error. A fully unattended installation is therefore not supported; run the package manager yourself on the downloaded package instead.
- The update runs as root through the package manager; it may also pull dependencies from your distribution's repositories.
- All requests are anonymous and subject to GitHub's rate limits (a failure then looks like being offline).
- For stable messages in scripts use `LC_ALL=C`; the `[UPDATE-INFO]` line is not translated.

## Examples

```
lpm self-update
lpm self-update check
lpm self-update install
lpm self-update check | sed -n 's/^\[UPDATE-INFO\] \([^|]*\)|.*/\1/p'
```

## Files and data touched

- Network: `api.github.com` (release list) and the package download URL given by GitHub (`install` only).
- Writes: a temporary directory under `$TMPDIR` (or `/tmp`) holding the package, removed at exit; `~/.local/share/lpm/lpm.log` (errors, and one `OK` line after a successful update).
- System (`install`): the lpm package, through apt/dnf/zypper/rpm/pacman.

## See also

[`lpm check`](check.md), [`lpm log`](log.md), [Global options](options.md)
