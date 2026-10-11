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

> [!WARNING]
> **Only install `.zgp` and `.zgr` archives that you made yourself or that come from someone you trust.** lpm is meant to back up and move your own games and runners between your machines; it is not made to download or distribute games. An archive can contain any file: scripts embedded in it are disabled unless you allow them (`--allow-scripts`), but you still install it entirely at your own risk. Never install an archive from an unknown source.

## Features

- Backup and restore of your Wine/Lutris games and runners as portable archives (`.zgp` / `.zgr`), installable on any machine.
- Unified, reliable launchers (desktop shortcuts), consistent whatever your desktop environment.
- Working icons for your games and runners, correctly shown in the menu and file manager.
- Usable from the command line, or with the graphical interface (`lpm-gui`) if you'd rather not type anything.
- Per-game tuning: Wine tools (winetricks, registry editor, winecfg, console, environment variables, change the runner), forcing VSync off, lsfg-vk frame generation, and a launcher with a loading screen that lets you pick among several executables.
- Gamepad shortcuts during play when the launcher is enabled (Alt+Tab, F4, Alt+Enter, F11), on X11 and Wayland.
- Interface available in English and French.
- Bash/zsh completion and a man page (`man lpm`) included.
- Native `.deb`, `.rpm` and Arch packages, or a universal manual install on any distribution.

## Installation

lpm manages games installed in **Lutris**, so Lutris must be installed on your machine (Flatpak or native package, both are supported). The `.deb`, `.rpm` and Arch packages only recommend it and do not install it for you.

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
sudo apt install -y tar zstd curl wget python3 python3-yaml python3-gi python3-evdev gir1.2-gtk-4.0 gir1.2-adw-1 libsdl2-2.0-0 sqlite3 pv libarchive-tools desktop-file-utils shared-mime-info hicolor-icon-theme
flatpak install -y flathub net.lutris.Lutris
```

#### Arch Linux

```bash
sudo pacman -S --needed tar zstd curl wget python python-yaml python-gobject python-evdev gtk4 libadwaita sdl2 sqlite pv bsdtar desktop-file-utils shared-mime-info hicolor-icon-theme
flatpak install -y flathub net.lutris.Lutris
```

#### Fedora

```bash
sudo dnf install -y tar zstd curl wget python3 python3-pyyaml python3-gobject python3-evdev gtk4 libadwaita SDL2 sqlite pv bsdtar desktop-file-utils shared-mime-info hicolor-icon-theme
flatpak install -y flathub net.lutris.Lutris
```

#### openSUSE

```bash
sudo zypper install -y tar zstd curl wget python3 python3-PyYAML python3-gobject python3-evdev typelib-1_0-Gtk-4_0 typelib-1_0-Adw-1 libSDL2-2_0-0 sqlite3 pv bsdtar desktop-file-utils shared-mime-info hicolor-icon-theme
flatpak install -y flathub net.lutris.Lutris
```

> [!WARNING]
> The `bsdtar` package is not officially available on some versions of openSUSE Leap (e.g. 15.6) at the time of writing. If `zypper` can't find it, check [software.opensuse.org/package/bsdtar](https://software.opensuse.org/package/bsdtar) for availability on your version, or use the community repository listed on that page.

Then download the project and run the install script from its folder:

```bash
git clone https://github.com/RogerBytes/lpm.git
cd lpm
chmod +x ./install.sh
sudo ./install.sh
```

This also installs lpm's own icons (`hicolor` theme): one for the application in the menu, and one for each of the `.zgp`/`.zgr` file types in your file manager.

If another program named `lpm` already exists in `/usr/local/bin` (for example the Lite XL plugin manager), `install.sh` stops before copying anything and tells you so, and `uninstall.sh` never removes a `/usr/local/bin/lpm` that is not Ludis Prefix Manager. The `.deb`, `.rpm` and Arch packages are protected by your package manager, which refuses to overwrite a file owned by another package.

**Uninstall:** with a package, use your package manager (`sudo apt remove lpm`, `sudo dnf remove lpm` or `sudo pacman -R lpm`); after a manual install, run `sudo ./uninstall.sh` from the project folder. Uninstalling lpm only removes lpm's own files: your games, prefixes and Lutris configuration are not touched.

</div></details>

## Quick start

```bash
lpm pack mariovania papers-please
lpm install -y Mariovania.zgp "Papers, Please.zgp"
```

Same idea for a runner: `lpm pack-runner <name>` then `lpm install-runner <file>.zgr`.

## Commands

`lpm` is a terminal command that can be used in scripts: it never opens a window, and with no argument it shows the help. The graphical interface is started with `lpm-gui`. Every command has its own detailed reference page: arguments, options, behavior, exit status, scripting notes and examples. See also the [global options](docs/commands/options.md) (`-y`, `--hash`...) and the [archive formats](docs/commands/archives.md) (`.zgp` / `.zgr`).

<details><summary class="button">🔍 Spoiler</summary><div class="spoiler">

### Games

- [`lpm install`](docs/commands/install.md) — Installs one or more games from `.zgp` archives.
- [`lpm uninstall`](docs/commands/uninstall.md) — Uninstalls one or more games (prefix, Lutris entry, shortcuts).
- [`lpm pack`](docs/commands/pack.md) — Packages one or more games as `.zgp`.
- [`lpm isolate`](docs/commands/isolate.md) — Splits a shared store prefix (Epic, EA, Ubisoft, Battle.net) into one prefix per game (beta).
- [`lpm list`](docs/commands/list.md) — Lists installed games.
- [`lpm list-isolable`](docs/commands/list-isolable.md) — Lists games that share a store prefix.
- [`lpm info`](docs/commands/info.md) — Shows an installed game's metadata.
- [`lpm create-prefix`](docs/commands/create-prefix.md) — Creates empty Wine prefixes registered in Lutris.
- [`lpm exe-install`](docs/commands/exe-install.md) — Creates a prefix and runs a Windows installer in it.
- [`lpm shortcut`](docs/commands/shortcut.md) — (Re)creates menu/desktop shortcuts.
- [`lpm icon`](docs/commands/icon.md) — Fetches a game icon from SteamGridDB.
- [`lpm splash`](docs/commands/splash.md) — Fetches a loading-screen banner from SteamGridDB.
- [`lpm logo`](docs/commands/logo.md) — Fetches a transparent game logo.
- [`lpm sync-media`](docs/commands/sync-media.md) — Downloads Lutris's own media for games that lack them.
- [`lpm tools`](docs/commands/tools.md) — Runs a Wine tool on a game (winetricks, regedit, winecfg, console, exe, folder, favorite, env, runner, mangohud, gamepad).
- [`lpm vsync`](docs/commands/vsync.md) — Forces VSync off for a game with environment variables (Direct3D 9/11/12, OpenGL).
- [`lpm lsfg`](docs/commands/lsfg.md) — Enables/disables lsfg-vk frame generation.
- [`lpm launcher`](docs/commands/launcher.md) — Enables/disables the LPM Launcher (loading screen and executable picker).
- [`lpm killwine`](docs/commands/killwine.md) — Kills every running Wine/Proton process.

### Runners

- [`lpm install-runner`](docs/commands/install-runner.md) — Installs runners from local `.zgr` files or the GitHub release.
- [`lpm uninstall-runner`](docs/commands/uninstall-runner.md) — Uninstalls runners.
- [`lpm pack-runner`](docs/commands/pack-runner.md) — Packages runners as `.zgr`.
- [`lpm list-runner`](docs/commands/list-runner.md) — Lists installed runners.
- [`lpm list-remote-runners`](docs/commands/list-remote-runners.md) — Lists runners available on the GitHub release.

### System

- [`lpm check`](docs/commands/check.md) — Checks that the runners needed by installed games are present and fetches missing ones.
- [`lpm lutris-version`](docs/commands/lutris-version.md) — Shows or forces the Lutris installation used when both Flatpak and native exist.
- [`lpm self-update`](docs/commands/self-update.md) — Checks for a newer lpm release and installs it (package installs only).
- [`lpm log`](docs/commands/log.md) — Shows, filters or clears the action log.

### Advanced

- [`lpm launcher-entries`](docs/commands/launcher-entries.md) — Reads/replaces the launcher picker entries (JSON).
- [`lpm lsfg-dll`](docs/commands/lsfg-dll.md) — Reads or stores the reference `lsfg-vk.dll`.
- [`lpm sgdb-key`](docs/commands/sgdb-key.md) — Reads, saves or clears the SteamGridDB API key.
- [`lpm sgdb-images`](docs/commands/sgdb-images.md) — Lists candidate SteamGridDB images as JSON (used by the graphical interface).

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

This project was developed with the help of an AI (Claude, by Anthropic). The author decides what it does, tests it and maintains it.

<span hidden>
<details><summary></summary>
<style>.spoiler{border-left:4px solid #1abc9c;border-bottom-left-radius:3px;padding-left:10px;padding-top:15px;margin-top:-10px;margin-bottom:15px}.button{cursor:pointer;padding:5px 10px;background-color:#3498db;color:white;border-radius:3px;margin-bottom:5px;display:inline-block;transition:background-color 0.2s}.button:hover{background-color:#217dbb}details[open] .button{background-color:#1abc9c}</style>
</details></span>

<p align="right"><a href="#ludis-prefix-manager">🔝 Back to top</a></p>
