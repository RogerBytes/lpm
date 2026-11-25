# Getting started with ludis

One page, three things you will probably do with ludis. Every command has its own reference page in [`commands/`](commands/); this page only shows the common paths. Prefer a window to a terminal? Start `ludis-gui`: every action below is also there, with the same names.

Before anything else, Lutris must be installed (Flatpak or native package), and your games must be registered in it. `ludis list` prints your installed games with their **slug** (the short name used by every command).

## 1. Move a game to another machine

On the machine that has the game:

```bash
ludis list                      # find the slug
ludis pack mariovania           # writes "<Game name>.zgp" in your home folder
```

Copy the `.zgp` file to the other machine (USB drive, network share...), then:

```bash
ludis install Mariovania.zgp
```

The game is registered in Lutris, its shortcuts are created, and it is ready to launch. Several games at once: `ludis pack slug1 slug2 ...` and `ludis install a.zgp b.zgp`. Add `-y` right after `install` to skip confirmations.

- An existing game is **never overwritten**: uninstall it first with `ludis uninstall <slug>`.
- Archives can contain private data (registry, licence keys): keep them to yourself, and only install archives you made or that come from someone you trust.
- Runners work the same way: `ludis pack-runner <name>`, then `ludis install-runner <file>.zgr`. On the new machine, `ludis check` fetches the runners your installed games need.

See [`pack`](commands/pack.md), [`install`](commands/install.md) and the [archive format](commands/archives.md).

## 2. Add a game from a Windows installer

```bash
ludis exe-install "Setup.exe|My Game"
```

ludis creates a blank Wine prefix, runs the installer in it, then adds the game to Lutris. Choose the runner with `-r <runner>` (and `-a win32` for a 32-bit prefix). Just want an empty prefix to do things by hand? Use [`ludis create-prefix`](commands/create-prefix.md).

See [`exe-install`](commands/exe-install.md).

## 3. Tune a game

Everything is per game, by slug:

```bash
ludis tools mygame winetricks   # or: regedit, winecfg, console, env set KEY VALUE ...
ludis vsync mygame off          # force VSync off
ludis lsfg mygame on            # lsfg-vk frame generation
ludis launcher mygame on        # loading screen + executable picker, gamepad-friendly
```

Each of these has a `status` form to see the current state. Artwork for the menu and the loading screen comes from SteamGridDB (`ludis sgdb-key` to save your API key, then `ludis icon`, `ludis splash`, `ludis logo`), or from Lutris itself with `ludis sync-media`.

See [`tools`](commands/tools.md), [`vsync`](commands/vsync.md), [`lsfg`](commands/lsfg.md) and [`launcher`](commands/launcher.md).

## When something goes wrong

- `ludis log` shows what ludis did and where it failed.
- Both Flatpak and native Lutris installed? `ludis lutris-version` shows or forces the one ludis uses.
- Games stuck after a crash: `ludis killwine` kills every running Wine/Proton process.
- Bug or question: open an [issue](https://github.com/RogerBytes/ludis/issues).
