# Ludis Prefix Manager

Back up, transfer and reinstall your Wine/Lutris games in one click.

<p align="center">
  <img src="./assets/icons/lpm.svg" width="128" height="128" alt="Ludis Prefix Manager icon">
</p>

<p align="center">
  <a href="https://github.com/RogerBytes/lpm/releases/latest"><img alt="Latest release" src="https://img.shields.io/github/v/release/RogerBytes/lpm"></a>
  <a href="LICENSE"><img alt="MIT License" src="https://img.shields.io/badge/license-MIT-green"></a>
</p>

<p align="center">
  <a href="https://github.com/RogerBytes/lpm/releases/latest">Latest release</a> ·
  <a href="#installation">Installation</a> ·
  <a href="#commands">Commands</a> ·
  <a href="https://github.com/RogerBytes/lpm/issues">Issues</a> ·
  <a href="docs/Lisez-Moi.md">French ReadMe</a>
</p>

**Ludis Prefix Manager** lets you back up your Wine games for Lutris as `.zgp` archives and your runners as `.zgr` archives. It centralizes exporting, managing and deleting your archives, while importing takes care of setting everything up so your game is ready to launch right away.

## Features

- Backup and restore of your Wine/Lutris games and runners as portable archives (`.zgp` / `.zgr`), installable on any machine.
- Unified, reliable launchers (desktop shortcuts), consistent whatever your desktop environment.
- Working icons for your games and runners, correctly shown in the menu and file manager.
- Usable from the command line, or in guided mode (graphical dialogs) if you'd rather not type anything.
- Interface available in English and French.
- Bash/zsh completion and a man page (`man lpm`) included.
- Native `.deb`, `.rpm` and Arch packages, or a universal manual install on any distribution.

## Quick start

```bash
lpm pack mariovania papers-please
lpm install -y Mariovania.zgp "Papers, Please.zgp"
```

Same idea for a runner: `lpm pack-runner <name>` then `lpm install-runner <file>.zgr`.

## Commands

Every command below works as explicit command-line usage (with its arguments), or in guided mode (menus and graphical dialogs) if you launch it with no argument.

<details><summary class="button">🔍 Spoiler</summary><div class="spoiler">

### Games

- `lpm install [-y] <files.zgp...>` — Installs one or more games from `.zgp` packages (local or path).
- `lpm uninstall [-y] <slugs...>` — Uninstalls one or more games (removes the prefix, the Lutris entry and the shortcuts).
- `lpm pack [-level] <slugs...>` — Packages one or more games (by slug) as `.zgp` (optional zstd compression level, 0 to 22).
- `lpm list` — Lists installed Wine games (slug then name).

### Runners

- `lpm install-runner [-y] <files.zgr|names...>` — Installs one or more runners, from a local `.zgr` file or by name from lpm's GitHub release.
- `lpm uninstall-runner [-y] <names...>` — Uninstalls one or more runners.
- `lpm pack-runner [-level] <names...>` — Packages one or more installed runners as `.zgr`.
- `lpm list-runner` — Lists currently installed runners.
- `lpm list-remote-runners` — Lists runners available on the remote GitHub repository (flags the ones already installed).

### Dependencies

- `lpm check` — Scans the YAML files of every installed game, compares them against the runners actually present, and for each missing runner tries to fetch it automatically from lpm's GitHub release (with SHA256 verification). Missing runners that can't be found on the repository are listed at the end of the run along with the games that depend on them; you then need to install them manually via a `.zgr` file (`lpm install-runner <file>.zgr`) or via ProtonUp-Qt.
- `lpm lutris-version [flatpak|native|reset]` — Shows the detected Lutris versions (Flatpak and/or native package), with their number and an up-to-date/outdated status. If both are installed at the same time, lpm asks once which one to use (otherwise Flatpak takes priority by default) and remembers that choice; `flatpak`/`native` forces that choice, `reset` clears it.

For the complete, always up-to-date list of every command (shortcuts, icons, prefix isolation, tools, lsfg, logs, etc.), see `lpm --help` or `man lpm`.

</div></details>

## Installation

<details><summary class="button">🔍 Spoiler</summary><div class="spoiler">

### Debian, Ubuntu, Linux Mint (and derivatives)

Download the matching `.deb` file from the [releases page](https://github.com/RogerBytes/lpm/releases), then:

```bash
sudo apt install -y ./lpm_*.deb
```

Dependencies are resolved automatically.

### Fedora (and derivatives)

Download the matching `.rpm` file from the [releases page](https://github.com/RogerBytes/lpm/releases), then:

```bash
sudo dnf install -y ./lpm-*.rpm
```

### Arch Linux (and derivatives)

Download the matching `.pkg.tar.zst` file from the [releases page](https://github.com/RogerBytes/lpm/releases), then:

```bash
sudo pacman -U --noconfirm ./lpm-*.pkg.tar.zst
```

### Other distributions (manual install)

If your distribution isn't covered above (for example openSUSE), or if you'd rather do a manual install, first install the dependencies:

#### Ubuntu / Debian / Linux Mint

```bash
sudo apt install -y tar zstd curl wget python3 python3-yaml sqlite3 pv libarchive-tools zenity
flatpak install -y flathub net.lutris.Lutris
```

#### Arch Linux

```bash
sudo pacman -S --needed tar zstd curl wget python python-yaml sqlite pv bsdtar zenity
flatpak install -y flathub net.lutris.Lutris
```

#### Fedora

```bash
sudo dnf install -y tar zstd curl wget python3 python3-pyyaml sqlite pv bsdtar zenity
flatpak install -y flathub net.lutris.Lutris
```

#### openSUSE

```bash
sudo zypper install -y tar zstd curl wget python3 python3-PyYAML sqlite3 pv bsdtar zenity
flatpak install -y flathub net.lutris.Lutris
```

> [!WARNING]
> The `bsdtar` package is not officially available on some versions of openSUSE Leap (e.g. 15.6) at the time of writing. If `zypper` can't find it, check [software.opensuse.org/package/bsdtar](https://software.opensuse.org/package/bsdtar) for availability on your version, or use the community repository listed on that page.

Then run the install script:

```bash
chmod +x ./install.sh
sudo ./install.sh
```

This also installs lpm's own icons (`hicolor` theme): one for the application in the menu, and one for each of the `.zgp`/`.zgr` file types in your file manager.

</div></details>

## Information

<details><summary class="button">🔍 Spoiler</summary><div class="spoiler">

To get an icon in the launcher, just create an `icon` directory at the root of the prefix and move your image file there.

For any other extra file (Antimicro `.amgp` controller config, personal scripts...): it just needs to be present somewhere in the prefix **before packaging** (`lpm pack`) to be included in the `.zgp` archive and end up in the same place after reinstalling. For a controller config, you can then simply reference it normally in the game's Lutris configuration (YAML): since the prefix is rewritten to `$GAMEDIR` at install time, a path pointing inside it keeps working on the destination machine.

</div></details>

## License and contributing

This project is licensed under the MIT license (see [`LICENSE`](LICENSE)), except for three icon files under GPLv3. The name "Ludis Prefix Manager"/"lpm" and the project logo are not covered by this license.

To contribute, report a bug, or suggest a feature, see [`CONTRIBUTING.md`](./CONTRIBUTING.md).

## Author

[<img src="https://github.com/RogerBytes.png" width="40" height="40" style="border-radius:50%;" alt="RogerBytes' avatar">](https://github.com/RogerBytes)
[**RogerBytes (Harry Richmond)**](https://github.com/RogerBytes)

<span hidden>
<details><summary></summary>
<style>.spoiler{border-left:4px solid #1abc9c;border-bottom-left-radius:3px;padding-left:10px;padding-top:15px;margin-top:-10px;margin-bottom:15px}.button{cursor:pointer;padding:5px 10px;background-color:#3498db;color:white;border-radius:3px;margin-bottom:5px;display:inline-block;transition:background-color 0.2s}.button:hover{background-color:#217dbb}details[open] .button{background-color:#1abc9c}</style>
</details></span>

<p align="right"><a href="#">🔝 Back to top</a></p>
