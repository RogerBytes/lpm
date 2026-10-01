# Contributing to Ludis Prefix Manager

Thanks for your interest in this project. Before opening an issue or a pull request, please read the following.

## What lpm is

**lpm is an archiving and backup tool** for Wine/Lutris prefixes you already own on your machine. It packages, anonymizes and restores local folders — it does not download, host, or distribute any game content.

## Project layout

- `bin/lpm` — entry point script.
- `lib/*.sh` — modules loaded by `bin/lpm` (one file per feature area: installer, packer, desktop integration, language loader, etc.).
- `lang/*.lang` — translation strings, loaded by `lib/zgl-lang-loader.sh`.
- `assets/icons/` — application and file-type icons. Three files are GPLv3-derived (see `LICENSE`); everything else is MIT.
- `man/`, `completions/` — manual page and shell completions (bash/zsh).
- `packaging/` — build pipeline for `.deb`, `.rpm`, and Arch packages, each built in its own Docker container. See `packaging/build.sh`.

The software version lives in a single place, `LPM_VERSION` in `bin/lpm`; it is injected everywhere else (changelog, spec file, PKGBUILD) at build time. Never hardcode a version number anywhere else.

## Building and testing locally

There is currently no automated test suite — changes are verified by running the affected commands manually against a real Lutris install.

While working on a fix, the fastest loop is to run `sudo ./install.sh` directly from your modified checkout and test with the real `lpm` command — no need to rebuild a package for every iteration.

To verify that the final packaging still works before a release (requires Docker):

```bash
cd packaging
./build.sh all      # or: deb | rpm | arch
```

Built packages land in `packaging/dist/`.

## What's welcome

- Bug reports (ideally with reproduction steps and the output of `lpm check` if relevant)
- Feature requests related to packaging, installation, or runner management
- Documentation fixes
- Pull requests following the project's existing style

## What will be closed without discussion

- Any issue asking for help obtaining, installing, or identifying game files you do not legally own
- Any link to game files, third-party `.zgp`/`.zgr` packages, or download sites, posted as a comment
- Any feature request aimed at facilitating the sharing or distribution of games (rather than personal backup)

These issues will be closed and the author blocked, without prior warning.

## Reporting a bug

Please include:

- The exact command used (`lpm ...`)
- The full error output
- Your distribution, and whether Lutris is installed via Flatpak or as a native package
